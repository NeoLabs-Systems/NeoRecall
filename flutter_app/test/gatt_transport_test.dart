import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/omi_device_adapter.dart';

void main() {
  test('GATT scan requires a protocol selector', () {
    expect(const GattScanSpec().hasProtocolSelector, isFalse);
    expect(
      const GattScanSpec(serviceUuids: <String>['service']).hasProtocolSelector,
      isTrue,
    );
    expect(
      const GattScanSpec(manufacturerIds: <int>[42]).hasProtocolSelector,
      isTrue,
    );
  });

  test('scan chooser only advertises end-to-end decodable protocols', () async {
    final transport = _FakeGattTransport();
    final adapter = OmiDeviceAdapter(gatt: transport);
    await adapter.startScan();

    expect(
      transport.lastScanSpec!.serviceUuids,
      isNot(contains(WearableDeviceUuids.beeService)),
    );
    expect(
      transport.lastScanSpec!.serviceUuids,
      isNot(contains(WearableDeviceUuids.friendService)),
    );
    expect(
      transport.lastScanSpec!.serviceUuids,
      contains(WearableDeviceUuids.limitlessService),
    );
    await adapter.dispose();
  });

  test(
    'Pocket is discoverable and probes services before being saved',
    () async {
      final transport = _FakeGattTransport()
        ..discoveredServiceUuids = const <String>['unknown-service'];
      final adapter = OmiDeviceAdapter(gatt: transport);
      final discovery = expectLater(
        adapter.discoveries,
        emits(
          isA<AudioDeviceDescriptor>()
              .having((device) => device.displayName, 'name', 'Pocket')
              .having(
                (device) => device.metadata['compatibilityUnknown'],
                'compatibility',
                isTrue,
              ),
        ),
      );

      await adapter.startScan();
      transport.emitPeripheral(
        const GattPeripheral(
          id: 'pocket-device',
          name: 'Pocket',
          serviceUuids: <String>[],
        ),
      );
      await discovery;
      const descriptor = AudioDeviceDescriptor(
        adapterId: 'omi_family',
        deviceKey: 'pocket-device',
        displayName: 'Pocket',
        transport: 'bluetooth_le',
        supportsMicrophone: false,
        metadata: <String, Object?>{
          'type': 'custom',
          'compatibilityUnknown': true,
        },
      );
      await expectLater(adapter.connect(descriptor), throwsUnsupportedError);
      expect(transport.pairCalls, 1);
      expect(
        transport.discoverServicesCalls,
        2,
        reason: 'services are refreshed after pairing',
      );
      await adapter.dispose();
    },
  );

  test('unexpected disconnect resumes an active wearable recording', () async {
    final transport = _FakeGattTransport();
    final adapter = OmiDeviceAdapter(gatt: transport);
    const device = AudioDeviceDescriptor(
      adapterId: 'omi_family',
      deviceKey: 'omi-device',
      displayName: 'omi',
      transport: 'bluetooth_le',
      metadata: <String, Object?>{
        'type': 'omi',
        'serviceUuids': <String>[WearableDeviceUuids.omiService],
      },
    );

    await adapter.connect(device);
    expect(transport.lastAutoReconnect, isFalse);
    expect(transport.discoverServicesCalls, 1);
    await adapter.requestStartRecording();
    transport.emitConnection(false);
    await Future<void>.delayed(Duration.zero);

    final resumed = expectLater(
      adapter.transportStates,
      emitsThrough(DeviceTransportState.recording),
    );
    await adapter.connect(device);
    await resumed;
    expect(transport.discoverServicesCalls, 2);
    await adapter.dispose();
  });

  test('an explicit stop is not restarted after reconnect', () async {
    final transport = _FakeGattTransport();
    final adapter = OmiDeviceAdapter(gatt: transport);
    final states = <DeviceTransportState>[];
    final subscription = adapter.transportStates.listen(states.add);
    const device = AudioDeviceDescriptor(
      adapterId: 'omi_family',
      deviceKey: 'omi-device',
      displayName: 'omi',
      transport: 'bluetooth_le',
      metadata: <String, Object?>{
        'type': 'omi',
        'serviceUuids': <String>[WearableDeviceUuids.omiService],
      },
    );

    await adapter.connect(device);
    await adapter.requestStartRecording();
    await adapter.requestStopRecording();
    transport.emitConnection(false);
    await Future<void>.delayed(Duration.zero);
    await adapter.connect(device);
    await Future<void>.delayed(Duration.zero);

    expect(states.last, DeviceTransportState.connectedStandby);
    await subscription.cancel();
    await adapter.dispose();
  });
}

class _FakeGattTransport implements GattTransport {
  final StreamController<GattPeripheral> _discoveries =
      StreamController<GattPeripheral>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final StreamController<Uint8List> _notifications =
      StreamController<Uint8List>.broadcast();

  bool? lastAutoReconnect;
  int discoverServicesCalls = 0;
  int pairCalls = 0;
  List<String> discoveredServiceUuids = const <String>[
    WearableDeviceUuids.omiService,
  ];
  GattScanSpec? lastScanSpec;

  @override
  Stream<GattPeripheral> get discoveries => _discoveries.stream;

  void emitConnection(bool connected) {
    _connections.add(connected);
  }

  void emitPeripheral(GattPeripheral peripheral) {
    _discoveries.add(peripheral);
  }

  @override
  Future<GattAvailability> availability() async => GattAvailability.ready;

  @override
  Stream<bool> connectionChanges(String deviceId) => _connections.stream;

  @override
  Future<void> connect(
    String deviceId, {
    bool autoReconnect = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    lastAutoReconnect = autoReconnect;
    emitConnection(true);
  }

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Future<void> pair(String deviceId) async {
    pairCalls += 1;
  }

  @override
  Future<int?> requestMtu(String deviceId, int expectedMtu) async =>
      expectedMtu;

  @override
  Future<List<String>> discoverServices(String deviceId) async {
    discoverServicesCalls += 1;
    return discoveredServiceUuids;
  }

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _connections.close();
    await _notifications.close();
  }

  @override
  Future<Uint8List> read(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async => Uint8List(0);

  @override
  Future<void> requestAccess() async {}

  @override
  Future<void> startScan(
    GattScanSpec spec, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    lastScanSpec = spec;
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<Stream<Uint8List>> subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async => _notifications.stream;

  @override
  Future<void> unsubscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {}

  @override
  Future<void> write(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {}
}
