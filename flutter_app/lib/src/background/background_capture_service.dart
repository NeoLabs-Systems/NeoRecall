import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_hold.dart';
import 'background_live_status.dart';
import 'home_widget_snapshot.dart';

export 'background_hold.dart';
export 'background_live_status.dart';
export 'home_widget_snapshot.dart';

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

  /// Updates the single native ongoing surface. Replacing one structured status
  /// avoids separate recording, upload, watch-sync, and error notifications.
  Future<void> updateLiveStatus(BackgroundLiveStatus status) async {}

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

  /// Atomically claims a user tap from the Android home-screen widget.
  ///
  /// The native side persists the tap before launching the Activity, so this
  /// remains true across cold-engine and Activity attachment races.
  Future<bool> takePendingWidgetPhoneRecordingRequest();

  /// Hands the home-screen widgets everything they are allowed to show.
  ///
  /// Widgets render in the launcher's process with no access to the network or
  /// the app database, so one published snapshot is their entire world. Sending
  /// an unchanged snapshot is a no-op, which keeps a chatty notifyListeners()
  /// from redrawing every widget on every frame.
  Future<void> publishWidgetSnapshot(HomeWidgetSnapshot snapshot) async {}

  /// Atomically claims every widget tap that could not be served at the time.
  ///
  /// Same guarantee as [takePendingWidgetPhoneRecordingRequest], generalised:
  /// a tap is recorded natively before anything is launched, so completing a
  /// task or stopping capture from the home screen survives a cold start.
  Future<List<HomeWidgetAction>> takePendingWidgetActions() async =>
      const <HomeWidgetAction>[];

  /// Claims watch recordings from the native handoff inbox. The watch retains
  /// its originals until [acknowledgeWatchRecording] persists a terminal proof.
  Future<List<Map<String, dynamic>>> takePendingWatchRecordings();
  Future<void> markWatchRecordingImported(String recordingId);
  Future<bool> acknowledgeWatchRecording(
    String recordingId,
    Map<String, dynamic> receipt,
  );

  Stream<BackgroundCaptureEvent> get events;
}

enum BackgroundCaptureEventType {
  message,
  stopRequested,
  batteryOptimizationActive,
  phoneRecordingRequested,

  /// A home-screen widget was tapped while the process was alive; the payload
  /// is claimed through [BackgroundCaptureService.takePendingWidgetActions].
  widgetActionRequested,
  watchTransferStarted,
  watchTransferFinished,
  watchRecordingAvailable,

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
  BackgroundLiveStatus? _liveStatus;
  bool _initialized = false;
  bool _notificationPermissionResolved = false;
  static const MethodChannel _channel = MethodChannel(
    'systems.neolabs.neorecall/background_capture',
  );

  @override
  bool get isRunning => _active.isNotEmpty;
  @override
  BackgroundRuntimeRequest get active => _active;
  @override
  BackgroundRuntimeState get state => BackgroundRuntimeState(
    running: isRunning,
    holds: _active.holds,
    foreground: true,
  );
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'backgroundStopRequested') {
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.stopRequested,
            ),
          );
          try {
            await _channel.invokeMethod<void>('acknowledgeLiveStopRequest');
          } on MissingPluginException {
            // The persisted request remains available for the next cold start.
          }
        }
        return null;
      });
      try {
        final pending =
            await _channel.invokeMethod<bool>('takePendingLiveStopRequest') ??
            false;
        if (pending) {
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.stopRequested,
            ),
          );
        }
      } on MissingPluginException {
        // Hosts built before interactive Live Activities still record normally.
      }
    }
    _initialized = true;
  }

  @override
  Future<BackgroundRuntimeState> refreshState() async => state;

  @override
  Future<bool> takePendingWidgetPhoneRecordingRequest() async => false;

  @override
  Future<void> publishWidgetSnapshot(HomeWidgetSnapshot snapshot) async {}

  @override
  Future<List<HomeWidgetAction>> takePendingWidgetActions() async =>
      const <HomeWidgetAction>[];

  @override
  Future<List<Map<String, dynamic>>> takePendingWatchRecordings() async =>
      const <Map<String, dynamic>>[];

  @override
  Future<void> markWatchRecordingImported(String recordingId) async {}

  @override
  Future<bool> acknowledgeWatchRecording(
    String recordingId,
    Map<String, dynamic> receipt,
  ) async => true;

  @override
  Future<bool> apply(BackgroundRuntimeRequest request) async {
    _active = request;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        request.isCapturing &&
        !_notificationPermissionResolved) {
      _notificationPermissionResolved = true;
      try {
        if (!await Permission.notification.isGranted) {
          await Permission.notification.request();
        }
      } catch (_) {
        // ActivityKit does not depend on notification permission. A denied or
        // unavailable prompt only removes the separate storage-full alert.
      }
    }
    return true;
  }

  @override
  Future<void> updateLiveStatus(BackgroundLiveStatus status) async {
    if (_liveStatus == status) return;
    _liveStatus = status;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<void>('updateLiveStatus', status.toMap());
      } on MissingPluginException {
        // Older hosts keep capture working without the optional live surface.
      }
    }
  }

  @override
  Future<void> stop() async {
    _active = BackgroundRuntimeRequest.idle;
    _liveStatus = null;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<void>('clearLiveStatus');
      } on MissingPluginException {
        // Optional on hosts built before Live Activity support.
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _channel.setMethodCallHandler(null);
    }
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
  BackgroundLiveStatus? _liveStatus;
  String? _widgetPayload;

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
        case 'widgetPhoneRecordingRequested':
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.phoneRecordingRequested,
            ),
          );
        case 'widgetActionRequested':
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.widgetActionRequested,
            ),
          );
        case 'watchRecordingAvailable':
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.watchRecordingAvailable,
            ),
          );
        case 'watchTransferStarted':
          _events.add(
            const BackgroundCaptureEvent(
              BackgroundCaptureEventType.watchTransferStarted,
            ),
          );
        case 'watchTransferFinished':
          final arguments = call.arguments;
          _events.add(
            BackgroundCaptureEvent(
              BackgroundCaptureEventType.watchTransferFinished,
              message: arguments is Map ? arguments['error'] as String? : null,
            ),
          );
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
  Future<bool> takePendingWidgetPhoneRecordingRequest() async {
    try {
      return await _channel.invokeMethod<bool>(
            'takePendingWidgetPhoneRecordingRequest',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> publishWidgetSnapshot(HomeWidgetSnapshot snapshot) async {
    final payload = snapshot.encode();
    if (payload == _widgetPayload) return;
    _widgetPayload = payload;
    try {
      await _channel.invokeMethod<void>('publishWidgetData', <String, Object?>{
        'payload': payload,
      });
    } catch (_) {
      // Widgets are an accessory surface: a host that cannot take the snapshot
      // must never disturb capture. The next publish resends it anyway, so
      // clear the cache to make sure that retry actually goes out.
      _widgetPayload = null;
    }
  }

  @override
  Future<List<HomeWidgetAction>> takePendingWidgetActions() async {
    try {
      final rows = await _channel.invokeListMethod<dynamic>(
        'takePendingWidgetActions',
      );
      return rows
              ?.whereType<Map<Object?, Object?>>()
              .map(HomeWidgetAction.fromMap)
              .where((action) => action.type.isNotEmpty)
              .toList(growable: false) ??
          const <HomeWidgetAction>[];
    } catch (_) {
      return const <HomeWidgetAction>[];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> takePendingWatchRecordings() async {
    try {
      final rows = await _channel.invokeListMethod<dynamic>(
        'takePendingWatchRecordings',
      );
      return rows
              ?.whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false) ??
          const <Map<String, dynamic>>[];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  @override
  Future<void> markWatchRecordingImported(String recordingId) =>
      _channel.invokeMethod<void>(
        'markWatchRecordingImported',
        <String, Object?>{'recordingId': recordingId},
      );

  @override
  Future<bool> acknowledgeWatchRecording(
    String recordingId,
    Map<String, dynamic> receipt,
  ) async =>
      await _channel.invokeMethod<bool>(
        'acknowledgeWatchRecording',
        <String, Object?>{'recordingId': recordingId, 'receipt': receipt},
      ) ??
      false;

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
      await _channel.invokeMethod<bool>(
        'applyBackgroundHolds',
        <String, Object?>{'holds': request.wireHolds},
      );
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

  @override
  Future<void> updateLiveStatus(BackgroundLiveStatus status) async {
    if (!_initialized) await initialize();
    if (_liveStatus == status) return;
    _liveStatus = status;
    try {
      await _channel.invokeMethod<void>('updateLiveStatus', status.toMap());
    } catch (error) {
      _message('Background status could not be updated: $error');
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
        'Notification permission is off. Android will keep background capture visible in its active-apps controls, but the recording notice may not appear in the notification drawer.',
      );
    }
    if (request.needsMicrophone) {
      final microphone = await _resolvePermission(Permission.microphone);
      if (!microphone) {
        _message(
          'Cannot capture in the background without microphone permission.',
        );
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
    _liveStatus = null;
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
