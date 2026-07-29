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
/// 3. Android foreground service host while recording
class MobileRecallRecorder implements RecallRecorder {
  MobileRecallRecorder({
    AudioDeviceAdapterRegistry? registry,
    DeviceSessionController? devices,
    BackgroundCaptureService? background,
  })  : registry = registry ?? createDefaultDeviceRegistry(),
        background = background ?? createBackgroundCaptureService() {
    this.devices = devices ?? DeviceSessionController(registry: this.registry);
  }

  final AudioDeviceAdapterRegistry registry;
  late final DeviceSessionController devices;
  final BackgroundCaptureService background;

  CapturePipeline? _pipeline;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<RecordedAudioChunk> _partials =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  bool _initialized = false;

  @override
  Stream<RecordedAudioChunk> get chunks => _chunks.stream;
  @override
  Stream<RecordedAudioChunk> get partials => _partials.stream;
  @override
  Stream<String> get warnings => _warnings.stream;
  @override
  Stream<double> get levels => _levels.stream;
  @override
  bool get isRecording => _pipeline?.isRunning ?? false;

  Future<void> initialize() async {
    if (_initialized) return;
    await registry.initializeAll();
    await devices.restore();
    await background.initialize();
    _subs.add(devices.messages.listen(_warnings.add));
    _subs.add(background.events.listen(_warnings.add));
    if (devices.preferBluetooth && devices.hasPreferredDevice) {
      unawaited(devices.connectPreferred());
    }
    _initialized = true;
  }

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
  }) async {
    if (!_initialized) await initialize();
    if (isRecording) throw StateError('Recorder is already active.');

    final sources = <CaptureSource>[];
    final notes = <String>[];
    final preferBluetooth =
        devices.preferBluetooth && devices.hasPreferredDevice;
    final mode = preferBluetooth ? 'bluetooth' : 'microphone';

    final backgroundStarted = await background.start(mode: mode);
    if (!backgroundStarted) {
      notes.add(
        'Background capture host could not start. Recording continues while the app stays alive.',
      );
    }

    if (preferBluetooth) {
      final device = devices.preferredDevice!;
      final adapter = devices.activeAdapter ?? registry[device.adapterId];
      if (adapter != null) {
        try {
          await devices.connectPreferred();
          sources.add(BluetoothCaptureSource(adapter: adapter, device: device));
        } catch (error) {
          notes.add(
            'Bluetooth device unavailable ($error). Falling back to phone microphone.',
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
          if (sources.isEmpty) {
            throw StateError(
              'Microphone permission is required for phone capture.',
            );
          }
          notes.add('Microphone permission denied; using connected device only.');
        } else if (sources.isEmpty || microphone) {
          // If bluetooth source already exists and user explicitly wants mic too,
          // keep both. Otherwise use mic as fallback only.
          if (sources.isEmpty || !preferBluetooth) {
            sources.add(mic);
          } else if (microphone) {
            sources.add(mic);
          }
        }
      }
    }

    if (sources.isEmpty) {
      throw StateError('No mobile audio source is available.');
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
    ];
    _subs.addAll(localSubs);

    try {
      final capability = await pipeline.start();
      _pipeline = pipeline;
      final warning = [
        if (capability.warning != null) capability.warning!,
        ...notes,
      ].join(' ').trim();
      return RecorderCapability(
        microphone: capability.microphone,
        systemAudio: false,
        persistentStorage: true,
        sampleRate: capability.sampleRate,
        warning: warning.isEmpty ? null : warning,
      );
    } catch (error) {
      for (final sub in localSubs) {
        await sub.cancel();
        _subs.remove(sub);
      }
      await pipeline.dispose();
      await background.stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) {
      await pipeline.stop();
      await pipeline.dispose();
    }
    await background.stop();
  }

  @override
  Future<void> dispose() async {
    await stop();
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
  }
}
