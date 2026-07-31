import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_hold.dart';

export 'background_hold.dart';

/// Cross-platform façade for the always-on mobile runtime host.
///
/// Callers never say "start recording" here; they declare the set of
/// [BackgroundHold]s that must keep the process alive (see
/// [BackgroundRuntimeRequest]). One host therefore serves live microphone
/// capture, live wearable capture, and an idle wearable link without a separate
/// code path per feature.
abstract class BackgroundCaptureService {
  Future<void> initialize();

  /// Makes the native host match [request]. Returns true when the host is (or
  /// will be) active for every requested hold. Applying an empty request stops
  /// the host.
  ///
  /// Idempotent: re-applying the active request does not restart anything.
  Future<bool> apply(BackgroundRuntimeRequest request);

  /// Releases every hold and stops the host.
  Future<void> stop();

  Future<void> dispose();

  /// True while the native host is alive for at least one hold.
  bool get isRunning;

  /// The request currently applied to the host.
  BackgroundRuntimeRequest get active;

  /// Last state read from the platform, refreshed by [initialize] and [apply].
  BackgroundRuntimeState get state;

  /// Re-reads platform state. Callers that must know *right now* whether a UI is
  /// attached (before starting microphone capture, for instance) use this rather
  /// than the possibly stale [state].
  Future<BackgroundRuntimeState> refreshState();

  Stream<BackgroundCaptureEvent> get events;
}

enum BackgroundCaptureEventType {
  message,
  stopRequested,
  batteryOptimizationActive,

  /// The host could not take a microphone hold because no UI is attached (a
  /// process the system started after a reboot or a crash). Wearable holds are
  /// unaffected; only phone-microphone capture needs the user to open the app.
  microphoneUnavailable,
}

class BackgroundCaptureEvent {
  const BackgroundCaptureEvent(this.type, {this.message});

  final BackgroundCaptureEventType type;
  final String? message;
}

/// Shown when the platform refused a microphone hold to an unattended process.
/// Kept in one place because it is reported both as an event and by reading
/// [BackgroundRuntimeState.microphoneUnavailable] at startup.
const String backgroundMicrophoneUnavailableMessage =
    'Phone-microphone recording could not resume on its own. Bluetooth capture '
    'and sync continue; open NeoRecall to restart microphone capture.';

/// Host for platforms that keep the process alive through declared OS
/// background modes (iOS) or that have no background lifetime at all (web,
/// desktop): there is no service to start, so holds are only tracked.
class PlatformManagedBackgroundCaptureService
    implements BackgroundCaptureService {
  final StreamController<BackgroundCaptureEvent> _events =
      StreamController<BackgroundCaptureEvent>.broadcast();
  BackgroundRuntimeRequest _active = BackgroundRuntimeRequest.idle;

  @override
  bool get isRunning => _active.isNotEmpty;
  @override
  BackgroundRuntimeRequest get active => _active;
  @override
  BackgroundRuntimeState get state =>
      BackgroundRuntimeState(running: isRunning, holds: _active.holds, foreground: true);
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<BackgroundRuntimeState> refreshState() async => state;

  @override
  Future<bool> apply(BackgroundRuntimeRequest request) async {
    _active = request;
    return true;
  }

  @override
  Future<void> stop() async {
    _active = BackgroundRuntimeRequest.idle;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

class AndroidBackgroundCaptureService implements BackgroundCaptureService {
  static const MethodChannel _channel = MethodChannel(
    'systems.neolabs.neorecall/background_capture',
  );
  final StreamController<BackgroundCaptureEvent> _events =
      StreamController<BackgroundCaptureEvent>.broadcast();
  BackgroundRuntimeRequest _active = BackgroundRuntimeRequest.idle;
  BackgroundRuntimeState _state = const BackgroundRuntimeState();
  bool _initialized = false;
  bool _microphoneNoticeSent = false;
  bool _batteryNoticeSent = false;
  String? _lastMessage;

  @override
  bool get isRunning => _state.running;
  @override
  BackgroundRuntimeRequest get active => _active;
  @override
  BackgroundRuntimeState get state => _state;
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'backgroundStopRequested':
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.stopRequested,
            ),
          );
        case 'backgroundHostMessage':
          final arguments = call.arguments;
          if (arguments is Map && arguments['message'] is String) {
            _message(arguments['message'] as String);
          }
      }
      return null;
    });
    await _readState();
    // A host that outlived the UI already describes what it is doing; adopt it
    // so the first apply() is a no-op instead of a needless restart.
    if (_state.running) {
      _active = BackgroundRuntimeRequest(holds: _state.holds);
    }
    _reportMicrophoneAvailability();
    _initialized = true;
  }

  @override
  Future<BackgroundRuntimeState> refreshState() async {
    await _readState();
    return _state;
  }

  @override
  Future<bool> apply(BackgroundRuntimeRequest request) async {
    if (!_initialized) await initialize();
    if (request.isEmpty) {
      await stop();
      return true;
    }
    if (request == _active) {
      // Re-check rather than trusting the cached flag: a host the platform
      // reclaimed must be started again even though nothing about the request
      // changed.
      await _readState();
      if (_state.running) return true;
    }

    if (!await _ensureHostPermissions(request)) return false;
    try {
      await _channel.invokeMethod<bool>('applyBackgroundHolds', <String, Object?>{
        'holds': request.wireHolds,
        'title': request.notificationTitle,
        'text': request.notificationText,
      });
      _active = request;
      // The platform starts the host asynchronously, so this read describes the
      // host as it was, not as it will be. Accepting the request is what the
      // caller needs to know; liveness is reported by later reads.
      await _readState();
      _reportMicrophoneAvailability();
      return true;
    } catch (error) {
      _message('Background runtime could not start: $error');
      return false;
    }
  }

  /// Notification permission gates the foreground service itself; microphone
  /// permission gates only the microphone hold. Both are requested interactively
  /// only when a UI is attached — a process the system started on its own cannot
  /// show a dialog, and asking there would fail instead of prompting.
  Future<bool> _ensureHostPermissions(BackgroundRuntimeRequest request) async {
    final notification = await _resolvePermission(Permission.notification);
    if (!notification) {
      _message(
        'Cannot run reliably in the background without notification permission.',
      );
      return false;
    }
    if (request.needsMicrophone) {
      final microphone = await _resolvePermission(Permission.microphone);
      if (!microphone) {
        _message('Cannot capture in the background without microphone permission.');
        return false;
      }
    }
    await _promptBatteryOptimizationOnce();
    return true;
  }

  Future<bool> _resolvePermission(Permission permission) async {
    try {
      if (await permission.isGranted) return true;
      if (!_state.foreground) return false;
      return (await permission.request()).isGranted;
    } catch (_) {
      // No activity is attached to request against; fall back to the last known
      // grant state rather than failing the whole apply.
      try {
        return await permission.isGranted;
      } catch (_) {
        return false;
      }
    }
  }

  Future<void> _promptBatteryOptimizationOnce() async {
    try {
      var status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        _batteryNoticeSent = false;
        return;
      }
      final preferences = await SharedPreferences.getInstance();
      if (_state.foreground &&
          !(preferences.getBool('batteryOptimizationPrompted') ?? false)) {
        await preferences.setBool('batteryOptimizationPrompted', true);
        status = await Permission.ignoreBatteryOptimizations.request();
      }
      // Holds change often (a sync starts, a capture ends); the warning is about
      // the device, not the hold, so report it once per run rather than each time.
      if (!status.isGranted && !_batteryNoticeSent) {
        _batteryNoticeSent = true;
        _message(
          'Battery optimization is still active; Android or the device vendor may suspend long-running background work.',
        );
        _events.add(
          const BackgroundCaptureEvent(
            BackgroundCaptureEventType.batteryOptimizationActive,
          ),
        );
      }
    } catch (_) {
      // Battery-optimization state is advisory; never block the host on it.
    }
  }

  void _reportMicrophoneAvailability() {
    if (!_state.microphoneUnavailable) {
      _microphoneNoticeSent = false;
      return;
    }
    if (_microphoneNoticeSent) return;
    _microphoneNoticeSent = true;
    _events.add(
      const BackgroundCaptureEvent(
        BackgroundCaptureEventType.microphoneUnavailable,
        message: backgroundMicrophoneUnavailableMessage,
      ),
    );
  }

  Future<void> _readState() async {
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'backgroundRuntimeState',
      );
      _state = payload == null
          ? const BackgroundRuntimeState()
          : BackgroundRuntimeState.fromMap(payload);
    } catch (error) {
      // Includes MissingPluginException on a host without the native side.
      _state = const BackgroundRuntimeState();
      _message('Android background host is temporarily unavailable: $error');
    }
  }

  @override
  Future<void> stop() async {
    _active = BackgroundRuntimeRequest.idle;
    try {
      await _channel.invokeMethod<bool>('stopBackgroundCapture');
    } catch (_) {
      // Best-effort stop; Dart-side state still clears.
    }
    await _readState();
  }

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    await _events.close();
  }

  void _message(String value) {
    if (_events.isClosed) return;
    // Holds are reconciled on every device and capture transition, so an
    // unchanged condition would otherwise be reported over and over.
    if (_lastMessage == value) return;
    _lastMessage = value;
    _events.add(
      BackgroundCaptureEvent(
        BackgroundCaptureEventType.message,
        message: value,
      ),
    );
  }
}

BackgroundCaptureService createBackgroundCaptureService() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidBackgroundCaptureService();
  }
  return PlatformManagedBackgroundCaptureService();
}
