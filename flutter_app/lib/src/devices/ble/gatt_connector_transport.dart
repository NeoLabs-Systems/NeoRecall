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

  /// True when the connected device discovered a characteristic with this
  /// service+characteristic UUID pair. Connectors use it to skip optional
  /// reads/writes/subscriptions the current firmware does not expose, instead of
  /// issuing them blindly (which wastes a round-trip and, on some stacks, an
  /// error). Comparison is case-insensitive. Returns false before connect.
  bool hasCharacteristic(String serviceUuid, String characteristicUuid);

  /// Every characteristic discovered on the connected device, so a connector can
  /// enumerate e.g. all notify endpoints in a service (some firmware variants
  /// emit data on alternate notify characteristics).
  List<GattDiscoveredCharacteristic> get discoveredCharacteristics;
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

  List<GattDiscoveredCharacteristic> _discovered =
      const <GattDiscoveredCharacteristic>[];
  Set<String> _discoveredKeys = const <String>{};

  @override
  final String deviceId;

  static String _key(String service, String characteristic) =>
      '${service.toLowerCase()}|${characteristic.toLowerCase()}';

  @override
  bool hasCharacteristic(String serviceUuid, String characteristicUuid) =>
      _discoveredKeys.contains(_key(serviceUuid, characteristicUuid));

  @override
  List<GattDiscoveredCharacteristic> get discoveredCharacteristics =>
      _discovered;

  @override
  Stream<bool> get connectionStateStream =>
      _gatt.connectionChanges(deviceId).distinct();

  @override
  Future<void> connect({
    bool requiresPairing = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // Clear any stale/pending connection to this peripheral before connecting.
    // On macOS 14+/iOS 17+ we enable CBConnectPeripheralOptionEnableAutoReconnect
    // (autoReconnect below), which leaves a *persistent pending connect* after any
    // disconnect. For an always-on wearable like Omi — the device you reconnect
    // most — a leftover pending connect from a previous app session silently
    // swallows the next explicit connect, so the device "never connects". A
    // cancel first clears that pending state and is a harmless no-op when the
    // peripheral is already disconnected. Verified against real hardware: the Omi
    // itself connects and streams fine (~0.6s), so this stale-pending-connect is
    // the app-side blocker, not the protocol.
    try {
      await _gatt.disconnect(deviceId);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } catch (_) {
      // Nothing was pending; proceed straight to connecting.
    }
    // Always-on wearables rely on the native BLE stack keeping the link alive
    // across brief RF dropouts. The app's session-controller reconnect still
    // handles a *full* disconnect on top of this.
    await _gatt.connect(deviceId, autoReconnect: true, timeout: timeout);
    final negotiatedMtu = await _gatt.requestMtu(deviceId, preferredMtu);
    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'mtu_negotiated',
      details: <String, Object?>{
        'requested': preferredMtu,
        'negotiated': negotiatedMtu,
      },
    );
    // Bond BEFORE discovering. A peripheral that requires bonding may hide or
    // refuse its encrypted services until the link is encrypted, so a table
    // discovered on an unbonded link is incomplete — every hasCharacteristic()
    // gate then false-negatives and the device looks half-broken. Because the
    // bond survives, a second connect attempt would discover the full table,
    // which is exactly the "press pair twice before it works" symptom. Pairing
    // first makes the first attempt behave like the second.
    if (requiresPairing) {
      try {
        await _gatt.pair(deviceId);
      } catch (_) {
        // Not supported on this platform (web/macOS) or already bonded. Apple
        // and Web bond implicitly when an encrypted characteristic is accessed,
        // so keep going and let that path trigger the native prompt.
      }
    }
    // Discover the full characteristic table once, up front, and cache it so
    // hasCharacteristic()/discoveredCharacteristics work for the whole session.
    // This is what lets each connector adapt to the concrete firmware instead of
    // assuming every optional service/characteristic is present.
    _discovered = await _gatt.discoverCharacteristics(deviceId);
    _discoveredKeys = _discovered
        .map(
          (characteristic) =>
              _key(characteristic.serviceUuid, characteristic.uuid),
        )
        .toSet();
    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'characteristics_discovered',
      details: <String, Object?>{
        'count': _discovered.length,
        'bondRequested': requiresPairing,
      },
    );
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
