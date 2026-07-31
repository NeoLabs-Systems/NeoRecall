import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

enum GattAvailability { unknown, ready, poweredOff, unauthorized, unsupported }

class GattScanSpec {
  const GattScanSpec({
    this.serviceUuids = const <String>[],
    this.namePrefixes = const <String>[],
    this.manufacturerIds = const <int>[],
  });

  final List<String> serviceUuids;
  final List<String> namePrefixes;
  final List<int> manufacturerIds;

  bool get hasProtocolSelector =>
      serviceUuids.isNotEmpty ||
      namePrefixes.isNotEmpty ||
      manufacturerIds.isNotEmpty;
}

class GattPeripheral {
  const GattPeripheral({
    required this.id,
    required this.name,
    required this.serviceUuids,
    this.rssi,
    this.manufacturerData = const <int, Uint8List>{},
  });

  final String id;
  final String name;
  final int? rssi;
  final List<String> serviceUuids;
  final Map<int, Uint8List> manufacturerData;
}

/// One discovered GATT characteristic: which service it belongs to, its UUID,
/// and the (lower-cased) property names it exposes (`read`, `write`,
/// `writeWithoutResponse`, `notify`, `indicate`, …). Lets connectors gate every
/// operation on what the connected firmware actually offers instead of blindly
/// reading/writing/subscribing characteristics that may not exist on a given
/// device model or firmware revision.
class GattDiscoveredCharacteristic {
  const GattDiscoveredCharacteristic({
    required this.serviceUuid,
    required this.uuid,
    required this.properties,
  });

  final String serviceUuid;
  final String uuid;
  final Set<String> properties;

  bool get canNotify =>
      properties.contains('notify') || properties.contains('indicate');
  bool get canWrite =>
      properties.contains('write') ||
      properties.contains('writeWithoutResponse');
}

/// Vendor-neutral BLE GATT transport for protocol adapters.
///
/// Device integrations own packet formats, codecs, commands, and hardware
/// button semantics. This layer owns only cross-platform discovery,
/// connection, characteristic I/O, and subscriptions.
abstract class GattTransport {
  Stream<GattPeripheral> get discoveries;
  Stream<bool> connectionChanges(String deviceId);

  Future<GattAvailability> availability();
  Future<void> requestAccess();
  Future<void> startScan(
    GattScanSpec spec, {
    Duration timeout = const Duration(seconds: 12),
  });
  Future<void> stopScan();
  Future<void> connect(
    String deviceId, {
    bool autoReconnect = true,
    Duration timeout = const Duration(seconds: 30),
  });
  Future<int?> requestMtu(String deviceId, int expectedMtu);
  Future<void> pair(String deviceId);
  Future<void> disconnect(String deviceId);
  Future<List<String>> discoverServices(String deviceId);
  Future<List<GattDiscoveredCharacteristic>> discoverCharacteristics(
    String deviceId,
  );
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  });
  Future<Stream<Uint8List>> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );
  Future<void> dispose();
}

GattTransport createGattTransport() => UniversalGattTransport();

class UniversalGattTransport implements GattTransport {
  final StreamController<GattPeripheral> _discoveries =
      StreamController<GattPeripheral>.broadcast();
  StreamSubscription<BleDevice>? _scanSubscription;
  Timer? _scanTimer;
  bool _scanning = false;

  @override
  Stream<GattPeripheral> get discoveries => _discoveries.stream;

  @override
  Stream<bool> connectionChanges(String deviceId) =>
      UniversalBle.connectionStream(deviceId).distinct();

  @override
  Future<GattAvailability> availability() async {
    if (kIsWeb) {
      // Web Bluetooth exposes availability through the chooser rather than a
      // stable adapter-state API. A scan initiated by a user gesture is the
      // authoritative capability check.
      return GattAvailability.unknown;
    }
    final state = await UniversalBle.getBluetoothAvailabilityState();
    return switch (state) {
      AvailabilityState.poweredOn => GattAvailability.ready,
      AvailabilityState.poweredOff => GattAvailability.poweredOff,
      AvailabilityState.unauthorized => GattAvailability.unauthorized,
      AvailabilityState.unsupported => GattAvailability.unsupported,
      _ => GattAvailability.unknown,
    };
  }

  @override
  Future<void> requestAccess() =>
      UniversalBle.requestPermissions(withAndroidFineLocation: false);

  @override
  Future<void> startScan(
    GattScanSpec spec, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (!spec.hasProtocolSelector) {
      throw StateError(
        'A validated service, manufacturer, or name selector is required before scanning.',
      );
    }
    if (kIsWeb && spec.serviceUuids.isEmpty) {
      throw StateError(
        'Web Bluetooth requires the device protocol service UUIDs before the browser chooser can open.',
      );
    }
    await stopScan();
    _scanSubscription = UniversalBle.scanStream.listen((device) {
      if (_discoveries.isClosed) return;
      _discoveries.add(
        GattPeripheral(
          id: device.deviceId,
          name: (device.name ?? '').trim(),
          rssi: device.rssi,
          serviceUuids: List<String>.unmodifiable(device.services),
          manufacturerData: <int, Uint8List>{
            for (final item in device.manufacturerDataList)
              item.companyId: Uint8List.fromList(item.payload),
          },
        ),
      );
    });
    _scanning = true;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: spec.serviceUuids,
          withNamePrefix: spec.namePrefixes,
          withManufacturerData: spec.manufacturerIds
              .map((id) => ManufacturerDataFilter(companyIdentifier: id))
              .toList(growable: false),
        ),
        platformConfig: kIsWeb
            ? PlatformConfig(
                web: WebOptions(
                  optionalServices: spec.serviceUuids,
                  optionalManufacturerData: spec.manufacturerIds,
                ),
              )
            : null,
      );
    } catch (_) {
      await stopScan();
      rethrow;
    }
    _scanTimer = Timer(timeout, () => unawaited(stopScan()));
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (!_scanning) return;
    _scanning = false;
    await UniversalBle.stopScan();
  }

  @override
  Future<void> connect(
    String deviceId, {
    bool autoReconnect = true,
    Duration timeout = const Duration(seconds: 30),
  }) => UniversalBle.connect(
    deviceId,
    autoConnect: autoReconnect && _nativeAutoReconnectSupported,
    timeout: timeout,
  );

  @override
  Future<int?> requestMtu(String deviceId, int expectedMtu) async {
    if (kIsWeb) return null;
    try {
      return await UniversalBle.requestMtu(deviceId, expectedMtu);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> pair(String deviceId) => UniversalBle.pair(deviceId);

  bool get _nativeAutoReconnectSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<void> disconnect(String deviceId) => UniversalBle.disconnect(deviceId);

  @override
  Future<List<String>> discoverServices(String deviceId) async =>
      (await UniversalBle.discoverServices(deviceId))
          .map((service) => service.uuid.toLowerCase())
          .toList(growable: false);

  @override
  Future<List<GattDiscoveredCharacteristic>> discoverCharacteristics(
    String deviceId,
  ) async {
    final services = await UniversalBle.discoverServices(deviceId);
    final out = <GattDiscoveredCharacteristic>[];
    for (final service in services) {
      final serviceUuid = service.uuid.toLowerCase();
      for (final characteristic in service.characteristics) {
        out.add(
          GattDiscoveredCharacteristic(
            serviceUuid: serviceUuid,
            uuid: characteristic.uuid.toLowerCase(),
            properties: characteristic.properties
                .map((property) => property.name)
                .toSet(),
          ),
        );
      }
    }
    return out;
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => UniversalBle.read(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) => UniversalBle.write(
    deviceId,
    serviceUuid,
    characteristicUuid,
    value,
    withoutResponse: withoutResponse,
  );

  @override
  Future<Stream<Uint8List>> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    await UniversalBle.subscribeNotifications(
      deviceId,
      serviceUuid,
      characteristicUuid,
    );
    return UniversalBle.characteristicValueStream(deviceId, characteristicUuid);
  }

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) => UniversalBle.unsubscribe(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> dispose() async {
    await stopScan();
    await _discoveries.close();
  }
}
