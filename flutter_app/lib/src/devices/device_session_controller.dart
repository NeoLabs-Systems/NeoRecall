import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'audio_device_adapter.dart';

/// Coordinates preferred external capture device selection and reconnect.
class DeviceSessionController {
  DeviceSessionController({required this.registry});

  final AudioDeviceAdapterRegistry registry;
  AudioDeviceDescriptor? preferredDevice;
  AudioDeviceAdapter? activeAdapter;
  DeviceTransportState state = DeviceTransportState.disconnected;
  bool autoReconnect = true;
  bool preferBluetooth = true;

  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  StreamSubscription<DeviceTransportState>? _stateSub;
  StreamSubscription<DeviceControlEvent>? _controlSub;
  Timer? _reconnectTimer;
  static const _prefsKey = 'preferred_audio_device_v1';

  Stream<DeviceTransportState> get states => _states.stream;
  Stream<String> get messages => _messages.stream;
  bool get hasPreferredDevice => preferredDevice != null;

  Future<void> restore() async {
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
        supportsHardwareButtons: map['supportsHardwareButtons'] as bool? ?? false,
        metadata: Map<String, Object?>.from(map['metadata'] as Map? ?? const {}),
      );
      activeAdapter = registry[preferredDevice!.adapterId];
      preferBluetooth = map['preferBluetooth'] as bool? ?? true;
    } catch (error) {
      _messages.add('Preferred device restore failed: $error');
    }
  }

  Future<void> _persist() async {
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

  Future<void> connectPreferred() async {
    final device = preferredDevice;
    final adapter = activeAdapter ??
        (device == null ? null : registry[device.adapterId]);
    if (device == null || adapter == null) {
      _messages.add('No preferred Bluetooth device is configured yet.');
      return;
    }
    activeAdapter = adapter;
    await _stateSub?.cancel();
    await _controlSub?.cancel();
    _stateSub = adapter.transportStates.listen((value) {
      state = value;
      _states.add(value);
      if (autoReconnect &&
          value == DeviceTransportState.disconnected &&
          preferredDevice != null) {
        _scheduleReconnect();
      }
    });
    _controlSub = adapter.controlEvents.listen((event) {
      _messages.add(
        'Device event ${event.type.name} from ${device.displayName}',
      );
    });
    try {
      await adapter.connect(device);
      _messages.add('Connected to ${device.displayName}');
    } catch (error) {
      state = DeviceTransportState.faulted;
      _states.add(state);
      _messages.add('Connect failed: $error');
      if (autoReconnect) _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      unawaited(connectPreferred());
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
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
  }
}
