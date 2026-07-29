import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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
  StreamSubscription<DeviceTransportState>? _stateSub;
  StreamSubscription<DeviceControlEvent>? _controlSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _connecting = false;
  String? _accountId;

  Stream<DeviceTransportState> get states => _states.stream;
  Stream<String> get messages => _messages.stream;
  Stream<DeviceControlEvent> get controlEvents => _controlEvents.stream;
  bool get hasPreferredDevice {
    final device = preferredDevice;
    return device != null && registry[device.adapterId] != null;
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
    await _persist();
  }

  Future<void> prefer(AudioDeviceDescriptor device) async {
    preferredDevice = device;
    activeAdapter = registry[device.adapterId];
    await _persist();
    await connectPreferred();
  }

  Future<void> clearPreferred() async {
    preferredDevice = null;
    await disconnect();
    await _persist();
  }

  Future<bool> connectPreferred() async {
    final device = preferredDevice;
    final adapter =
        activeAdapter ?? (device == null ? null : registry[device.adapterId]);
    if (device == null || adapter == null) {
      _messages.add('No preferred Bluetooth device is configured yet.');
      return false;
    }
    if (_connecting) return false;
    _connecting = true;
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
          value == DeviceTransportState.disconnected &&
          preferredDevice != null) {
        _scheduleReconnect();
      }
    });
    _controlSub = adapter.controlEvents.listen((event) {
      _controlEvents.add(event);
      _messages.add(
        'Device event ${event.type.name} from ${device.displayName}',
      );
    });
    try {
      await adapter.connect(device);
      _reconnectAttempt = 0;
      _messages.add('Connected to ${device.displayName}');
      return true;
    } catch (error) {
      state = DeviceTransportState.faulted;
      _states.add(state);
      _messages.add('Connect failed: $error');
      if (autoReconnect) _scheduleReconnect();
      return false;
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) return;
    final delay = reconnectPolicy.delayForAttempt(_reconnectAttempt);
    _reconnectAttempt += 1;
    _reconnectTimer = Timer(delay, () {
      unawaited(connectPreferred());
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    await activeAdapter?.disconnect();
    state = DeviceTransportState.disconnected;
    _states.add(state);
  }

  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await _stateSub?.cancel();
    await _controlSub?.cancel();
    await disconnect();
    await _states.close();
    await _messages.close();
    await _controlEvents.close();
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
