import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/client_diagnostic_log.dart';
import 'audio_device_adapter.dart';

/// Coordinates preferred external capture device selection and reconnect.
class DeviceSessionController {
  DeviceSessionController({
    required this.registry,
    this.reconnectPolicy = const DeviceReconnectPolicy(),
  });

  final AudioDeviceAdapterRegistry registry;
  final DeviceReconnectPolicy reconnectPolicy;
  AudioDeviceDescriptor? preferredDevice;
  AudioDeviceAdapter? activeAdapter;
  DeviceTransportState state = DeviceTransportState.disconnected;
  bool autoReconnect = true;
  bool preferBluetooth = true;

  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<DeviceControlEvent> _controlEvents =
      StreamController<DeviceControlEvent>.broadcast();
  final StreamController<bool> _linkIntents =
      StreamController<bool>.broadcast();
  StreamSubscription<DeviceTransportState>? _stateSub;
  StreamSubscription<DeviceControlEvent>? _controlSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// The connect attempt currently in flight, if any.
  ///
  /// Attempts are serialised rather than dropped: a tap that arrived while a
  /// background reconnect was running used to return false immediately, which
  /// [selectPreferred] surfaced as "could not be connected" even though nothing
  /// was wrong — the user tapped again and it worked. That was the "press pair
  /// twice" symptom. Waiting for the in-flight attempt makes one tap enough.
  Future<bool>? _connectOperation;
  bool _disconnecting = false;
  String? _accountId;

  Stream<DeviceTransportState> get states => _states.stream;
  Stream<String> get messages => _messages.stream;
  Stream<DeviceControlEvent> get controlEvents => _controlEvents.stream;

  /// Emits whenever [linkDesired] may have changed (device chosen or cleared,
  /// Bluetooth preference toggled, account rebound).
  ///
  /// The always-on host subscribes to this instead of polling: keeping a paired
  /// wearable linked is what lets its recordings sync with no app open, so the
  /// decision to hold the process alive follows the same signal that decides
  /// whether a device should be connected at all.
  Stream<bool> get linkIntents => _linkIntents.stream;

  /// True when a paired wearable should stay connected even while nothing is
  /// being recorded, so reconnect, device-storage sync, and upload keep running.
  bool get linkDesired => preferBluetooth && hasPreferredDevice;

  /// Whether the transport is linked right now. A preferred device and an
  /// active adapter only describe what should connect; neither proves that the
  /// BLE link exists.
  bool get isConnected =>
      state == DeviceTransportState.connectedStandby ||
      state == DeviceTransportState.recording;

  bool get hasPreferredDevice {
    final device = preferredDevice;
    return device != null && registry[device.adapterId] != null;
  }

  void _notifyLinkIntent() {
    if (_linkIntents.isClosed) return;
    _linkIntents.add(linkDesired);
  }

  String? get accountId => _accountId;

  String get _prefsKey => 'preferred_audio_device_v2:$_accountId';

  Future<void> bindAccount(String? value) async {
    if (_accountId == value) return;
    await disconnect();
    preferredDevice = null;
    activeAdapter = null;
    preferBluetooth = true;
    _accountId = value;
    if (value != null) await restore();
    _notifyLinkIntent();
  }

  Future<void> restore() async {
    if (_accountId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      preferredDevice = AudioDeviceDescriptor(
        adapterId: map['adapterId'] as String,
        deviceKey: map['deviceKey'] as String,
        displayName: map['displayName'] as String,
        transport: map['transport'] as String? ?? 'bluetooth',
        supportsMicrophone: map['supportsMicrophone'] as bool? ?? true,
        supportsSystemAudio: map['supportsSystemAudio'] as bool? ?? false,
        supportsHardwareButtons:
            map['supportsHardwareButtons'] as bool? ?? false,
        metadata: Map<String, Object?>.from(
          map['metadata'] as Map? ?? const {},
        ),
      );
      activeAdapter = registry[preferredDevice!.adapterId];
      preferBluetooth = map['preferBluetooth'] as bool? ?? true;
    } catch (error) {
      _messages.add('Preferred device restore failed: $error');
    }
  }

  Future<void> _persist() async {
    if (_accountId == null) {
      throw StateError('A signed-in account is required to save a device.');
    }
    final prefs = await SharedPreferences.getInstance();
    final device = preferredDevice;
    if (device == null) {
      await prefs.remove(_prefsKey);
      return;
    }
    await prefs.setString(
      _prefsKey,
      jsonEncode(<String, Object?>{
        'adapterId': device.adapterId,
        'deviceKey': device.deviceKey,
        'displayName': device.displayName,
        'transport': device.transport,
        'supportsMicrophone': device.supportsMicrophone,
        'supportsSystemAudio': device.supportsSystemAudio,
        'supportsHardwareButtons': device.supportsHardwareButtons,
        'metadata': device.metadata,
        'preferBluetooth': preferBluetooth,
      }),
    );
  }

  Future<void> setPreferBluetooth(bool value) async {
    preferBluetooth = value;
    if (!value) {
      // Phone capture means the wearable is no longer a standing runtime
      // dependency. Cancel both the current link and any delayed reconnect so
      // a stale device cannot keep producing timeout banners in this mode.
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      await disconnect();
    }
    // The source picker can be rendered briefly while account restoration is
    // still completing. Apply the runtime choice immediately, but never write
    // an unscoped preference that could leak across accounts.
    if (_accountId != null) await _persist();
    _notifyLinkIntent();
  }

  Future<void> prefer(AudioDeviceDescriptor device) async {
    final previousDevice = preferredDevice;
    final previousAdapter = activeAdapter;
    preferredDevice = device;
    activeAdapter = registry[device.adapterId];
    final connected = await connectPreferred(scheduleReconnect: false);
    if (!connected) {
      preferredDevice = previousDevice;
      activeAdapter = previousAdapter;
      throw StateError(
        '${device.displayName} could not be connected as an audio device.',
      );
    }
    await _persist();
    _notifyLinkIntent();
  }

  Future<void> clearPreferred() async {
    preferredDevice = null;
    await disconnect();
    await _persist();
    _notifyLinkIntent();
  }

  Future<bool> connectPreferred({bool scheduleReconnect = true}) async {
    // Let any in-flight attempt finish first so this one is queued, not dropped.
    while (_connectOperation != null) {
      await _connectOperation;
    }
    // Claim the slot synchronously (before the first await below) so two callers
    // in the same microtask cannot both start connecting.
    final completer = Completer<bool>();
    _connectOperation = completer.future;
    try {
      final connected = await _connect(scheduleReconnect: scheduleReconnect);
      completer.complete(connected);
      return connected;
    } catch (_) {
      completer.complete(false);
      rethrow;
    } finally {
      if (identical(_connectOperation, completer.future)) {
        _connectOperation = null;
      }
    }
  }

  Future<bool> _connect({required bool scheduleReconnect}) async {
    final device = preferredDevice;
    final adapter =
        activeAdapter ?? (device == null ? null : registry[device.adapterId]);
    if (device == null || adapter == null) {
      _messages.add('No preferred Bluetooth device is configured yet.');
      return false;
    }
    // Already linked (e.g. the attempt we just waited on connected this very
    // device): report success instead of tearing a good link down.
    if (state == DeviceTransportState.connectedStandby ||
        state == DeviceTransportState.recording) {
      return true;
    }
    activeAdapter = adapter;
    await _stateSub?.cancel();
    await _controlSub?.cancel();
    _stateSub = adapter.transportStates.listen((value) {
      state = value;
      _states.add(value);
      if (value == DeviceTransportState.connectedStandby ||
          value == DeviceTransportState.recording) {
        _reconnectAttempt = 0;
        _reconnectTimer?.cancel();
      }
      if (autoReconnect &&
          !_disconnecting &&
          linkDesired &&
          value == DeviceTransportState.disconnected &&
          preferredDevice != null) {
        _scheduleReconnect();
      }
    });
    // Control events (button presses, battery pushes, power state) are raw
    // wearable telemetry, not user-facing warnings — forward them on
    // controlEvents for callers that care (e.g. battery UI) but never surface
    // their names as a banner.
    _controlSub = adapter.controlEvents.listen(_controlEvents.add);
    try {
      await adapter.connect(device);
      _reconnectAttempt = 0;
      _messages.add('Connected to ${device.displayName}');
      return true;
    } catch (error) {
      ClientDiagnosticLog.instance.record(
        'bluetooth',
        'preferred_connection_failed',
        level: 'error',
        details: <String, Object?>{
          'name': device.displayName,
          'error': error.toString(),
        },
      );
      state = DeviceTransportState.faulted;
      _states.add(state);
      _messages.add(
        error is TimeoutException
            ? 'Bluetooth connection timed out. Make sure ${device.displayName} is nearby, awake, and not connected to another phone.'
            : 'Could not connect to ${device.displayName}. Check the device and try again.',
      );
      if (autoReconnect && scheduleReconnect && linkDesired) {
        _scheduleReconnect();
      }
      return false;
    }
  }

  void _scheduleReconnect() {
    if (!linkDesired || _disconnecting) return;
    if (_reconnectTimer?.isActive ?? false) return;
    final delay = reconnectPolicy.delayForAttempt(_reconnectAttempt);
    _reconnectAttempt += 1;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!linkDesired || _disconnecting) return;
      unawaited(connectPreferred());
    });
  }

  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    try {
      await activeAdapter?.disconnect();
    } finally {
      state = DeviceTransportState.disconnected;
      _states.add(state);
      _disconnecting = false;
    }
  }

  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await _stateSub?.cancel();
    await _controlSub?.cancel();
    await disconnect();
    await _states.close();
    await _messages.close();
    await _controlEvents.close();
    await _linkIntents.close();
  }
}

class DeviceReconnectPolicy {
  const DeviceReconnectPolicy({
    this.initialDelay = const Duration(seconds: 2),
    this.maximumDelay = const Duration(minutes: 2),
    this.multiplier = 2,
  });

  final Duration initialDelay;
  final Duration maximumDelay;
  final int multiplier;

  Duration delayForAttempt(int attempt) {
    if (initialDelay <= Duration.zero ||
        maximumDelay < initialDelay ||
        multiplier < 1) {
      throw StateError('Invalid device reconnect policy.');
    }
    if (attempt < 0) {
      throw RangeError.value(attempt, 'attempt', 'Must not be negative.');
    }
    var milliseconds = initialDelay.inMilliseconds;
    for (var index = 0; index < attempt; index += 1) {
      milliseconds = (milliseconds * multiplier).clamp(
        initialDelay.inMilliseconds,
        maximumDelay.inMilliseconds,
      );
      if (milliseconds == maximumDelay.inMilliseconds) break;
    }
    return Duration(milliseconds: milliseconds);
  }
}
