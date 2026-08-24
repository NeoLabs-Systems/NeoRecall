import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/devices/ble/gatt_connector_transport.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';
import 'package:neorecall/src/devices/device_session_controller.dart';
import 'package:neorecall/src/devices/omi/device_adapter.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';

/// Regressions for the two ways a single "Pair" tap used to fail and only work
/// on the second attempt, plus the web-only service-permission gap.
void main() {
  test('bonding happens before characteristic discovery', () async {
    final gatt = _RecordingGattTransport();
    final transport = GattConnectorTransport(gatt: gatt, deviceId: 'dev-1');

    await transport.connect(requiresPairing: true);

    // A peripheral that requires bonding can hide its encrypted services until
    // the link is encrypted. Discovering first cached an incomplete table, every
    // hasCharacteristic() gate false-negatived, and only a second connect (by
    // then bonded) worked — the "press pair twice" symptom.
    expect(gatt.callOrder, contains('pair'));
    expect(
      gatt.callOrder.indexOf('pair'),
      lessThan(gatt.callOrder.indexOf('discoverCharacteristics')),
      reason: 'the table must be discovered over an already-bonded link',
    );
  });

  test('a pairing failure still leaves a usable connection', () async {
    // pair() is unimplemented on web and macOS; it must not abort the connect.
    final gatt = _RecordingGattTransport()..pairThrows = true;
    final transport = GattConnectorTransport(gatt: gatt, deviceId: 'dev-1');

    await transport.connect(requiresPairing: true);

    expect(gatt.callOrder, contains('discoverCharacteristics'));
    expect(
      transport.hasCharacteristic(
        WearableDeviceUuids.omiService,
        WearableDeviceUuids.omiService,
      ),
      isTrue,
    );
  });

  test('web scan grants every service the connectors later use', () async {
    final gatt = _RecordingGattTransport();
    final adapter = DeviceAdapter(gatt: gatt);
    await adapter.startScan();

    final granted = gatt.lastScanSpec!.webAccessibleServices;
    // Web Bluetooth authorises per service: anything missing here throws a
    // SecurityError after connecting, on web only. Selecting a device by its
    // primary service does not grant these.
    expect(granted, contains(WearableDeviceUuids.omiStorageService));
    expect(granted, contains(WearableDeviceUuids.batteryService));
    expect(granted, contains(WearableDeviceUuids.buttonService));
    expect(granted, contains(WearableDeviceUuids.timeSyncService));
    // The scan selectors themselves are still present.
    expect(granted, contains(WearableDeviceUuids.omiService));
    expect(granted, contains(WearableDeviceUuids.heyPocketService));
    await adapter.dispose();
  });

  test('an OmiGlass found by name only is still accepted', () async {
    // The scan carries 'OmiGlass'/'OpenGlass' name prefixes precisely for
    // firmware that omits the service UUID from its advertisement. Requiring
    // both the UUID and the name rejected exactly those devices, so connect()
    // threw "no fully local, validated capture pipeline" for a supported unit.
    final gatt = _RecordingGattTransport();
    final adapter = DeviceAdapter(gatt: gatt);
    final connected = expectLater(
      adapter.transportStates,
      emitsThrough(DeviceTransportState.connectedStandby),
    );
    const descriptor = AudioDeviceDescriptor(
      adapterId: 'omi_family',
      deviceKey: 'glass-1',
      displayName: 'OpenGlass',
      transport: 'bluetooth_le',
      metadata: <String, Object?>{
        'type': 'omiGlass',
        'serviceUuids': <String>[],
      },
    );
    await adapter.connect(descriptor);
    await connected;
    await adapter.dispose();
  });

  test(
    'pairing while a reconnect is in flight succeeds on the first tap',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final adapter = _SlowAdapter();
      final registry = AudioDeviceAdapterRegistry()..register(adapter);
      final sessions = DeviceSessionController(registry: registry);
      await sessions.bindAccount('acct-1'); // prefer() persists the choice
      const device = AudioDeviceDescriptor(
        adapterId: 'fake',
        deviceKey: 'dev-1',
        displayName: 'Omi',
        transport: 'bluetooth_le',
      );

      // Simulate a background reconnect already running when the user taps Pair.
      sessions.preferredDevice = device;
      sessions.activeAdapter = adapter;
      final backgroundAttempt = sessions.connectPreferred();
      await Future<void>.delayed(Duration.zero);

      // Previously this returned false immediately and prefer() reported
      // "could not be connected", so the user had to tap a second time.
      await expectLater(sessions.prefer(device), completes);
      await backgroundAttempt;
      expect(adapter.connectCalls, greaterThanOrEqualTo(1));
      await sessions.disconnect();
    },
  );

  test(
    'connection timeouts are user-facing and phone mode stops reconnecting',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final adapter = _SlowAdapter()
        ..connectError = TimeoutException('raw future timeout');
      final registry = AudioDeviceAdapterRegistry()..register(adapter);
      final sessions = DeviceSessionController(registry: registry);
      await sessions.bindAccount('acct-1');
      const device = AudioDeviceDescriptor(
        adapterId: 'fake',
        deviceKey: 'dev-1',
        displayName: 'Pocket recorder',
        transport: 'bluetooth_le',
      );
      sessions.preferredDevice = device;
      sessions.activeAdapter = adapter;
      final message = sessions.messages.first;

      expect(
        await sessions.connectPreferred(scheduleReconnect: false),
        isFalse,
      );
      final displayed = await message;
      expect(displayed, contains('Bluetooth connection timed out'));
      expect(displayed, isNot(contains('TimeoutException')));
      expect(displayed, isNot(contains('Future not completed')));

      await sessions.setPreferBluetooth(false);
      expect(sessions.preferBluetooth, isFalse);
      expect(adapter.disconnectCalls, 1);
      await sessions.dispose();
    },
  );

  test(
    'an in-flight failure cannot re-arm Bluetooth after phone selection',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final adapter = _SlowAdapter()
        ..connectError = TimeoutException('connect completed after disconnect');
      final registry = AudioDeviceAdapterRegistry()..register(adapter);
      final sessions = DeviceSessionController(
        registry: registry,
        reconnectPolicy: const DeviceReconnectPolicy(
          initialDelay: Duration(milliseconds: 10),
          maximumDelay: Duration(milliseconds: 20),
        ),
      );
      await sessions.bindAccount('acct-1');
      sessions.preferredDevice = const AudioDeviceDescriptor(
        adapterId: 'fake',
        deviceKey: 'dev-1',
        displayName: 'Pocket recorder',
        transport: 'bluetooth_le',
      );
      sessions.activeAdapter = adapter;

      final inFlight = sessions.connectPreferred();
      await Future<void>.delayed(Duration.zero);
      await sessions.setPreferBluetooth(false);
      expect(await inFlight, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(adapter.connectCalls, 1);
      expect(sessions.preferBluetooth, isFalse);
      await sessions.dispose();
    },
  );
}

class _RecordingGattTransport implements GattTransport {
  final List<String> callOrder = <String>[];
  final StreamController<GattPeripheral> _discoveries =
      StreamController<GattPeripheral>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  bool pairThrows = false;
  GattScanSpec? lastScanSpec;

  @override
  Stream<GattPeripheral> get discoveries => _discoveries.stream;

  @override
  Future<GattAvailability> availability() async => GattAvailability.ready;

  @override
  Stream<bool> connectionChanges(String deviceId) => _connections.stream;

  @override
  Future<void> connect(
    String deviceId, {
    bool autoReconnect = true,
    Duration timeout = const Duration(seconds: 30),
  }) async => callOrder.add('connect');

  @override
  Future<void> disconnect(String deviceId) async => callOrder.add('disconnect');

  @override
  Future<void> pair(String deviceId) async {
    callOrder.add('pair');
    if (pairThrows) throw UnsupportedError('pair is not implemented');
  }

  @override
  Future<int?> requestMtu(String deviceId, int expectedMtu) async {
    callOrder.add('requestMtu');
    return expectedMtu;
  }

  @override
  Future<List<String>> discoverServices(String deviceId) async {
    callOrder.add('discoverServices');
    return const <String>[WearableDeviceUuids.omiService];
  }

  @override
  Future<List<GattDiscoveredCharacteristic>> discoverCharacteristics(
    String deviceId,
  ) async {
    callOrder.add('discoverCharacteristics');
    return const <GattDiscoveredCharacteristic>[
      GattDiscoveredCharacteristic(
        serviceUuid: WearableDeviceUuids.omiService,
        uuid: WearableDeviceUuids.omiService,
        properties: <String>{'read', 'notify'},
      ),
    ];
  }

  @override
  Future<Uint8List> read(String d, String s, String c) async => Uint8List(0);

  @override
  Future<void> requestAccess() async {}

  @override
  Future<void> startScan(
    GattScanSpec spec, {
    Duration timeout = const Duration(seconds: 12),
  }) async => lastScanSpec = spec;

  @override
  Future<void> stopScan() async {}

  @override
  Future<Stream<Uint8List>> subscribe(String d, String s, String c) async =>
      const Stream<Uint8List>.empty();

  @override
  Future<void> unsubscribe(String d, String s, String c) async {}

  @override
  Future<void> write(
    String d,
    String s,
    String c,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {}

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _connections.close();
  }
}

/// Adapter whose connect takes long enough for a second attempt to overlap it.
class _SlowAdapter implements AudioDeviceAdapter {
  int connectCalls = 0;
  int disconnectCalls = 0;
  Object? connectError;
  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();

  @override
  String get id => 'fake';
  @override
  String get displayName => 'Fake';
  @override
  String get transport => 'bluetooth_le';

  @override
  Stream<AudioDeviceDescriptor> get discoveries =>
      const Stream<AudioDeviceDescriptor>.empty();
  @override
  Stream<DeviceControlEvent> get controlEvents =>
      const Stream<DeviceControlEvent>.empty();
  @override
  Stream<Uint8List> get pcm16Stream => const Stream<Uint8List>.empty();
  @override
  Stream<DeviceTransportState> get transportStates => _states.stream;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {}
  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(AudioDeviceDescriptor device) async {
    connectCalls += 1;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final error = connectError;
    if (error != null) throw error;
    _states.add(DeviceTransportState.connectedStandby);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
    _states.add(DeviceTransportState.disconnected);
  }

  @override
  Future<void> requestStartRecording() async {}
  @override
  Future<void> requestStopRecording() async {}
  @override
  Future<void> dispose() async => _states.close();
}
