import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import 'gatt_transport.dart';

/// The small, plugin-independent GATT surface used by wearable protocols.
abstract interface class WearableTransport {
  String get deviceId;
  Stream<bool> get connectionStateStream;

  Future<void> connect({
    bool requiresPairing = false,
    Duration timeout = const Duration(seconds: 30),
  });
  Future<void> disconnect();
  Future<List<int>> readCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  );
  Future<void> writeCharacteristic(
    String serviceUuid,
    String characteristicUuid,
    List<int> value, {
    bool withoutResponse = false,
  });
  Future<Stream<List<int>>> characteristicStream(
    String serviceUuid,
    String characteristicUuid,
  );
}

/// One peripheral view on top of the application-wide cross-platform GATT
/// transport. Protocol code is therefore identical on mobile, desktop and web.
class GattConnectorTransport implements WearableTransport {
  GattConnectorTransport({required GattTransport gatt, required this.deviceId})
    : _gatt = gatt;

  final GattTransport _gatt;
  static const int preferredMtu = 512;

  @override
  final String deviceId;

  @override
  Stream<bool> get connectionStateStream =>
      _gatt.connectionChanges(deviceId).distinct();

  @override
  Future<void> connect({
    bool requiresPairing = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _gatt.connect(deviceId, autoReconnect: false, timeout: timeout);
    final negotiatedMtu = await _gatt.requestMtu(deviceId, preferredMtu);
    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'mtu_negotiated',
      details: <String, Object?>{
        'requested': preferredMtu,
        'negotiated': negotiatedMtu,
      },
    );
    await _gatt.discoverServices(deviceId);
    if (requiresPairing) {
      try {
        await _gatt.pair(deviceId);
      } catch (_) {
        // Apple and Web trigger pairing when an encrypted characteristic is
        // accessed. Keeping that path alive lets the native prompt appear.
      }
    }
  }

  @override
  Future<void> disconnect() => _gatt.disconnect(deviceId);

  @override
  Future<List<int>> readCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) async => List<int>.from(
    await _gatt.read(deviceId, serviceUuid, characteristicUuid),
  );

  @override
  Future<void> writeCharacteristic(
    String serviceUuid,
    String characteristicUuid,
    List<int> value, {
    bool withoutResponse = false,
  }) => _gatt.write(
    deviceId,
    serviceUuid,
    characteristicUuid,
    Uint8List.fromList(value),
    withoutResponse: withoutResponse,
  );

  @override
  Future<Stream<List<int>>> characteristicStream(
    String serviceUuid,
    String characteristicUuid,
  ) async {
    final source = await _gatt.subscribe(
      deviceId,
      serviceUuid,
      characteristicUuid,
    );
    late final StreamController<List<int>> controller;
    StreamSubscription<Uint8List>? subscription;
    controller = StreamController<List<int>>.broadcast(
      onListen: () {
        subscription = source.listen(
          (value) => controller.add(List<int>.from(value)),
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
        try {
          await _gatt.unsubscribe(deviceId, serviceUuid, characteristicUuid);
        } catch (_) {
          // A lost transport is already unsubscribed from the OS point of view.
        }
        if (!controller.isClosed) await controller.close();
      },
    );
    return controller.stream;
  }
}
