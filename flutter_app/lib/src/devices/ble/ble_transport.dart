import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thin BLE transport used by all Omi-style wearable connectors.
class BleTransport {
  BleTransport(this.remoteId, {this.requiresBond = false});

  final String remoteId;
  final bool requiresBond;
  BluetoothDevice? _device;
  final Map<String, StreamController<List<int>>> _streams =
      <String, StreamController<List<int>>>{};
  final Map<String, StreamSubscription<List<int>>> _subs =
      <String, StreamSubscription<List<int>>>{};
  final StreamController<BluetoothConnectionState> _connectionStates =
      StreamController<BluetoothConnectionState>.broadcast();
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  bool _connected = false;

  bool get isConnected => _connected;
  Stream<BluetoothConnectionState> get connectionStateStream =>
      _connectionStates.stream;

  static Future<bool> ensurePermissions() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return statuses.values.every(
        (status) => status.isGranted || status.isLimited,
      );
    }
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted || status.isLimited;
    }
    return true;
  }

  static Future<bool> isAdapterOn() async {
    try {
      return await FlutterBluePlus.isSupported &&
          await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  Future<void> connect({Duration timeout = const Duration(seconds: 30)}) async {
    if (_connected) return;
    await ensurePermissions();
    if (!await isAdapterOn()) {
      throw StateError('Bluetooth is turned off.');
    }
    _device = BluetoothDevice.fromId(remoteId);
    _connectionSub = _device!.connectionState.listen((state) {
      _connected = state == BluetoothConnectionState.connected;
      if (!_connectionStates.isClosed) _connectionStates.add(state);
    });
    await _device!.connect(
      autoConnect: false,
      timeout: timeout,
    );
    await _device!.discoverServices();
    if (requiresBond) {
      try {
        await _device!.createBond();
      } catch (_) {
        // Bonding is best-effort; some stacks bond during characteristic access.
      }
    }
    _connected = true;
  }

  Future<void> disconnect() async {
    for (final sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    for (final controller in _streams.values) {
      await controller.close();
    }
    _streams.clear();
    await _connectionSub?.cancel();
    _connectionSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _connected = false;
  }

  String _key(String serviceUuid, String characteristicUuid) =>
      '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';

  BluetoothCharacteristic? _findCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) {
    final device = _device;
    if (device == null) return null;
    final serviceTarget = serviceUuid.toLowerCase();
    final charTarget = characteristicUuid.toLowerCase();
    for (final service in device.servicesList) {
      if (service.uuid.str128.toLowerCase() != serviceTarget &&
          service.uuid.str.toLowerCase() != serviceTarget) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final id = characteristic.uuid.str128.toLowerCase();
        final short = characteristic.uuid.str.toLowerCase();
        if (id == charTarget || short == charTarget) return characteristic;
      }
    }
    // Fallback: search all services by characteristic UUID only.
    for (final service in device.servicesList) {
      for (final characteristic in service.characteristics) {
        final id = characteristic.uuid.str128.toLowerCase();
        final short = characteristic.uuid.str.toLowerCase();
        if (id == charTarget || short == charTarget) return characteristic;
      }
    }
    return null;
  }

  Future<List<int>> readCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) async {
    final characteristic = _findCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      throw StateError('Characteristic not found: $characteristicUuid');
    }
    return characteristic.read();
  }

  Future<void> writeCharacteristic(
    String serviceUuid,
    String characteristicUuid,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final characteristic = _findCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      throw StateError('Characteristic not found: $characteristicUuid');
    }
    await characteristic.write(
      value,
      withoutResponse: withoutResponse,
      allowLongWrite: true,
    );
  }

  Stream<List<int>> getCharacteristicStream(
    String serviceUuid,
    String characteristicUuid,
  ) {
    final key = _key(serviceUuid, characteristicUuid);
    final existing = _streams[key];
    if (existing != null) return existing.stream;
    final controller = StreamController<List<int>>.broadcast();
    _streams[key] = controller;
    () async {
      try {
        final characteristic =
            _findCharacteristic(serviceUuid, characteristicUuid);
        if (characteristic == null) {
          controller.addError(
            StateError('Characteristic not found: $characteristicUuid'),
          );
          return;
        }
        await characteristic.setNotifyValue(true);
        _subs[key] = characteristic.onValueReceived.listen(controller.add);
      } catch (error) {
        controller.addError(error);
      }
    }();
    return controller.stream;
  }

  Future<void> dispose() async {
    await disconnect();
    await _connectionStates.close();
  }
}
