import 'dart:async';

import '../background/background_capture_service.dart';
import '../capture/bluetooth_capture_source.dart';
import '../capture/capture_pipeline.dart';
import '../capture/capture_source.dart';
import '../capture/microphone_capture_source.dart';
import '../devices/audio_device_adapter.dart';
import '../devices/device_registry_bootstrap.dart';
import '../devices/device_session_controller.dart';
import 'audio_frame.dart';
import 'recorder.dart';

/// Mobile recorder for always-on capture.
///
/// Defaults:
/// 1. preferred Bluetooth/external device when connected
/// 2. phone microphone fallback
/// 3. Android foreground host while any background hold is held
///
/// The recorder owns the mobile runtime's background holds because it is the one
/// object that sees both sides: live capture sources and the wearable link. A
/// hold is taken per *reason* (see [BackgroundHold]), so phone-microphone
/// capture, wearable capture, and an idle wearable link share a single host and
/// a single notification instead of competing for one "capture mode".
class MobileRecallRecorder implements RecallRecorder {
  MobileRecallRecorder({
    AudioDeviceAdapterRegistry? registry,
    DeviceSessionController? devices,
    BackgroundCaptureService? background,
  }) : registry = registry ?? createDefaultDeviceRegistry(),
       background = background ?? createBackgroundCaptureService() {
    this.devices = devices ?? DeviceSessionController(registry: this.registry);
  }

  final AudioDeviceAdapterRegistry registry;
  late final DeviceSessionController devices;
  final BackgroundCaptureService background;

  CapturePipeline? _pipeline;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast(sync: true);
  final StreamController<RecordedAudioChunk> _partials =
      StreamController<RecordedAudioChunk>.broadcast(sync: true);
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<CapturePipelineInterruption> _interruptions =
      StreamController<CapturePipelineInterruption>.broadcast();
  final List<StreamSubscription<dynamic>> _pipelineSubs =
      <StreamSubscription<dynamic>>[];
  Set<BackgroundHold> _captureHolds = const <BackgroundHold>{};
  bool _backgroundPaused = false;
  bool _syncing = false;
  bool _initialized = false;

  @override
  Stream<RecordedAudioChunk> get chunks => _chunks.stream;
  @override
  Stream<RecordedAudioChunk> get partials => _partials.stream;
  @override
  Stream<String> get warnings => _warnings.stream;
  @override
  Stream<double> get levels => _levels.stream;
  Stream<CapturePipelineInterruption> get interruptions =>
      _interruptions.stream;
  @override
  bool get isRecording => _pipeline?.isRunning ?? false;

  /// True when the user released the background host from its notification.
  /// Nothing stays linked or captures until the app is opened again.
  bool get backgroundPaused => _backgroundPaused;

  Future<void> initialize({String? accountId}) async {
    if (_initialized) return;
    await registry.initializeAll();
    await devices.bindAccount(accountId);
    await background.initialize();
    _subs.add(devices.messages.listen(_warnings.add));
    _subs.add(devices.linkIntents.listen((_) => unawaited(applyBackgroundHolds())));
    _subs.add(
      background.events.listen((event) {
        final message = event.message;
        if (message != null) _warnings.add(message);
      }),
    );
    _initialized = true;
    await applyBackgroundHolds();
    if (devices.linkDesired) {
      await devices.connectPreferred();
    }
  }

  Future<void> bindAccount(String? accountId) async {
    if (!_initialized) {
      await initialize(accountId: accountId);
      return;
    }
    await devices.bindAccount(accountId);
    await applyBackgroundHolds();
  }

  /// Reconciles the native host with everything that currently needs the process
  /// alive. Safe to call at any time; the service ignores an unchanged request.
  /// Returns false when the host refused the request (missing permission, or a
  /// platform that will not host the requested holds).
  Future<bool> applyBackgroundHolds() async {
    if (!_initialized) return false;
    final holds = <BackgroundHold>{..._captureHolds};
    if (!_backgroundPaused) {
      if (devices.linkDesired) holds.add(BackgroundHold.wearableLink);
      // A transfer already in flight keeps the host regardless of the standing
      // preference: dropping it mid-drain would strand audio on the device.
      if (_syncing) holds.add(BackgroundHold.wearableSync);
    }
    return background.apply(
      BackgroundRuntimeRequest(
        holds: holds,
        deviceLabel: devices.preferredDevice?.displayName,
      ),
    );
  }

  /// Marks a device-storage transfer as running (or finished) so the host keeps
  /// the CPU awake for its duration. Idle polling must not set this — only an
  /// actual transfer does.
  Future<void> setDeviceSyncActive(bool active) async {
    if (_syncing == active) return;
    _syncing = active;
    await applyBackgroundHolds();
  }

  /// Releases every hold after the user tapped Stop on the notification: capture
  /// ends, the wearable is unlinked, and the host shuts down. Opening the app
  /// calls [resumeBackgroundRuntime] to arm it again.
  Future<void> pauseBackgroundRuntime() async {
    _backgroundPaused = true;
    devices.autoReconnect = false;
    await stop();
    _captureHolds = const <BackgroundHold>{};
    _syncing = false;
    await devices.disconnect();
    await background.stop();
  }

  Future<void> resumeBackgroundRuntime() async {
    if (!_backgroundPaused) return;
    _backgroundPaused = false;
    devices.autoReconnect = true;
    await applyBackgroundHolds();
    if (devices.linkDesired) {
      unawaited(devices.connectPreferred());
    }
  }

  /// Whether an Activity is attached right now. Phone-microphone capture cannot
  /// start without one — the platform denies microphone access to a process the
  /// system started on its own — so automatic recovery must check this instead of
  /// starting a capture that would record silence.
  Future<bool> hasAttachedUi() async =>
      (await background.refreshState()).foreground;

  static Set<BackgroundHold> holdsForSources(Iterable<CaptureSource> sources) {
    final holds = <BackgroundHold>{};
    for (final source in sources) {
      switch (source.kind) {
        case 'microphone':
          holds.add(BackgroundHold.microphoneCapture);
        case 'wearable':
          holds.add(BackgroundHold.wearableCapture);
      }
    }
    return holds;
  }

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) async {
    if (!_initialized) await initialize();
    if (isRecording) throw StateError('Recorder is already active.');
    // An explicit capture request supersedes a notification-initiated pause.
    _backgroundPaused = false;
    devices.autoReconnect = true;

    final sources = <CaptureSource>[];
    final notes = <String>[];
    final preferBluetooth =
        externalDevice != null ||
        (!microphone && devices.preferBluetooth && devices.hasPreferredDevice);

    if (preferBluetooth) {
      final device = externalDevice?.descriptor ?? devices.preferredDevice!;
      final adapter =
          externalDevice?.adapter ??
          devices.activeAdapter ??
          registry[device.adapterId];
      if (adapter != null) {
        final connected = externalDevice != null
            ? true
            : await devices.connectPreferred();
        if (connected) {
          sources.add(
            BluetoothCaptureSource(
              adapter: adapter,
              device: device,
              connectOnStart: false,
            ),
          );
        } else {
          notes.add(
            'Bluetooth device unavailable. Falling back to phone microphone.',
          );
        }
      } else {
        notes.add(
          'Preferred Bluetooth adapter is not registered yet. Falling back to phone microphone.',
        );
      }
    }

    final needsMicFallback = sources.isEmpty || microphone;
    if (needsMicFallback) {
      final mic = createPlatformMicrophoneSource();
      if (mic == null) {
        if (sources.isEmpty) {
          throw StateError('No mobile audio source is available.');
        }
      } else {
        final allowed = await mic.ensurePermission();
        if (!allowed) {
          await mic.dispose();
          if (sources.isEmpty) {
            throw StateError(
              'Microphone permission is required for phone capture.',
            );
          }
          notes.add(
            'Microphone permission denied; using connected device only.',
          );
        } else if (sources.isEmpty || microphone) {
          sources.add(mic);
        }
      }
    }

    if (sources.isEmpty) {
      throw StateError('No mobile audio source is available.');
    }

    // The host must own the matching foreground types before capture opens the
    // microphone or the BLE audio stream, not after.
    final previousCaptureHolds = _captureHolds;
    _captureHolds = holdsForSources(sources);
    if (!await applyBackgroundHolds()) {
      notes.add(
        'Background host could not start. Recording continues while the app stays open.',
      );
    }

    final pipeline = CapturePipeline(
      sources: sources,
      chunkMs: chunkMs,
      overlapMs: overlapMs,
    );
    final localSubs = <StreamSubscription<dynamic>>[
      pipeline.chunks.stream.listen(_chunks.add),
      pipeline.partials.stream.listen(_partials.add),
      pipeline.warnings.stream.listen(_warnings.add),
      pipeline.levels.stream.listen(_levels.add),
      pipeline.interruptions.stream.listen(_interruptions.add),
    ];
    _pipelineSubs.addAll(localSubs);

    try {
      final capability = await pipeline.start();
      _pipeline = pipeline;
      // Sources that failed permission or startup drop out of the pipeline;
      // hold only what is actually streaming.
      final activeHolds = holdsForSources(pipeline.activeSources);
      if (activeHolds.length != _captureHolds.length) {
        _captureHolds = activeHolds;
        await applyBackgroundHolds();
      }
      final warning = [
        if (capability.warning != null) capability.warning!,
        ...notes,
      ].join(' ').trim();
      return RecorderCapability(
        microphone: capability.microphone,
        systemAudio: false,
        persistentStorage: true,
        sampleRate: capability.sampleRate,
        sourceKind: capability.sourceKind,
        warning: warning.isEmpty ? null : warning,
      );
    } catch (error) {
      for (final sub in localSubs) {
        await sub.cancel();
        _pipelineSubs.remove(sub);
      }
      await pipeline.dispose();
      _captureHolds = previousCaptureHolds;
      await applyBackgroundHolds();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) {
      await pipeline.stop();
      for (final sub in _pipelineSubs) {
        await sub.cancel();
      }
      _pipelineSubs.clear();
      await pipeline.dispose();
    }
  }

  /// Releases the capture holds only after the controller has durably finalized
  /// the last chunk and session declaration. Any wearable link hold survives, so
  /// device-storage sync and upload keep running with the app closed.
  Future<void> finishBackgroundHost() async {
    _captureHolds = const <BackgroundHold>{};
    await applyBackgroundHolds();
  }

  @override
  Future<void> dispose() async {
    await stop();
    _captureHolds = const <BackgroundHold>{};
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await devices.dispose();
    await registry.disposeAll();
    await background.dispose();
    await _chunks.close();
    await _partials.close();
    await _warnings.close();
    await _levels.close();
    await _interruptions.close();
  }
}
