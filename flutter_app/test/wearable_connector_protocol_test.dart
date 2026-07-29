import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/ble/gatt_connector_transport.dart';
import 'package:neorecall/src/devices/omi/custom_command_connector.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/limitless_connector.dart';
import 'package:neorecall/src/devices/omi/omi_connector.dart';
import 'package:neorecall/src/devices/omi/plaud_connector.dart';

void main() {
  test('OmiGlass uses its documented Opus fallback codec', () async {
    final connector = OmiGlassConnector(
      device: _device(WearableDeviceType.omiGlass),
      transport: _FakeWearableTransport(),
    );
    await connector.connect();
    expect(connector.codec, WearableAudioCodec.opus);
    await connector.dispose();
  });

  test('PLAUD uses FS320 frames and syncs from returned start time', () async {
    final transport = _FakeWearableTransport();
    final connector = PlaudConnector(
      device: _device(WearableDeviceType.plaud),
      transport: transport,
    );
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.plaudWrite ||
          value.length < 3) {
        return;
      }
      final command = value[1] | (value[2] << 8);
      final response = switch (command) {
        20 => <int>[0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55, 0, 0],
        _ => <int>[0],
      };
      scheduleMicrotask(
        () => transport.emit(
          WearableDeviceUuids.plaudService,
          WearableDeviceUuids.plaudNotify,
          <int>[1, command & 0xff, command >> 8, ...response],
        ),
      );
    };

    await connector.connect();
    await connector.startRecording();

    expect(connector.codec, WearableAudioCodec.opusFs320);
    final syncWrite = transport.writes.firstWhere(
      (write) => write.value[1] == 28,
    );
    expect(syncWrite.value.sublist(3, 11), <int>[
      0x44,
      0x33,
      0x22,
      0x11,
      0,
      0,
      0,
      0,
    ]);
    expect(syncWrite.value.sublist(11, 19), <int>[
      0x88,
      0x77,
      0x66,
      0x55,
      0,
      0,
      0,
      0,
    ]);

    final audioFuture = connector.audioBytes.stream.first;
    transport.emit(
      WearableDeviceUuids.plaudService,
      WearableDeviceUuids.plaudNotify,
      <int>[2, 0, 0, 0, 0, 0, 0, 0, 0, 40, ...List<int>.filled(40, 0xb8)],
    );
    transport.emit(
      WearableDeviceUuids.plaudService,
      WearableDeviceUuids.plaudNotify,
      <int>[2, 0, 0, 0, 0, 40, 0, 0, 0, 40, ...List<int>.filled(40, 0x78)],
    );
    expect((await audioFuture).length, 80);
    await connector.dispose();
  });

  test(
    'Limitless uses protobuf commands and reassembles Opus payloads',
    () async {
      final transport = _FakeWearableTransport();
      final connector = LimitlessConnector(
        device: _device(WearableDeviceType.limitless),
        transport: transport,
      );
      await connector.connect(requiresPairing: true);
      expect(transport.requiredPairing, isTrue);
      expect(transport.writes.single.value.first, 0x08);

      await connector.startRecording();
      final startCommand = transport.writes.last.value;
      expect(startCommand, contains(0x42));

      final frame = <int>[0xb8, ...List<int>.generate(11, (index) => index)];
      final innerPayload = <int>[0x22, frame.length, ...frame];
      final wrapper = <int>[
        0x08,
        7,
        0x10,
        0,
        0x18,
        1,
        0x22,
        innerPayload.length,
        ...innerPayload,
      ];
      final frameFuture = connector.audioBytes.stream.first;
      transport.emit(
        WearableDeviceUuids.limitlessService,
        WearableDeviceUuids.limitlessRx,
        wrapper,
      );
      expect(await frameFuture, frame);
      await connector.dispose();
    },
  );

  test('Fieldy splits each notification into FS320 Opus frames', () async {
    final transport = _FakeWearableTransport();
    final connector = FieldyConnector(
      device: _device(WearableDeviceType.fieldy),
      transport: transport,
    );
    await connector.connect();
    await connector.startRecording();
    final received = <List<int>>[];
    final subscription = connector.audioBytes.stream.listen(received.add);
    transport.emit(
      WearableDeviceUuids.fieldyService,
      WearableDeviceUuids.fieldyAudio,
      <int>[...List<int>.filled(40, 0xb8), ...List<int>.filled(40, 0x78)],
    );
    await Future<void>.delayed(Duration.zero);
    expect(received.map((frame) => frame.length), <int>[40, 40]);
    await subscription.cancel();
    await connector.dispose();
  });
}

DiscoveredWearable _device(WearableDeviceType type) =>
    DiscoveredWearable(id: 'device-id', name: type.name, type: type, rssi: -45);

class _GattWrite {
  const _GattWrite(this.service, this.characteristic, this.value);

  final String service;
  final String characteristic;
  final List<int> value;
}

class _FakeWearableTransport implements WearableTransport {
  final Map<String, StreamController<List<int>>> _streams =
      <String, StreamController<List<int>>>{};
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final List<_GattWrite> writes = <_GattWrite>[];
  void Function(String service, String characteristic, List<int> value)?
  onWrite;
  bool requiredPairing = false;

  @override
  String get deviceId => 'device-id';

  @override
  Stream<bool> get connectionStateStream => _connections.stream;

  String _key(String service, String characteristic) =>
      '$service:$characteristic';

  @override
  Future<void> connect({
    bool requiresPairing = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requiredPairing = requiresPairing;
    _connections.add(true);
  }

  @override
  Future<void> disconnect() async {
    _connections.add(false);
  }

  @override
  Future<Stream<List<int>>> characteristicStream(
    String serviceUuid,
    String characteristicUuid,
  ) async => _streams
      .putIfAbsent(
        _key(serviceUuid, characteristicUuid),
        () => StreamController<List<int>>.broadcast(),
      )
      .stream;

  void emit(String service, String characteristic, List<int> value) {
    _streams
        .putIfAbsent(
          _key(service, characteristic),
          () => StreamController<List<int>>.broadcast(),
        )
        .add(value);
  }

  @override
  Future<List<int>> readCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) async => <int>[];

  @override
  Future<void> writeCharacteristic(
    String serviceUuid,
    String characteristicUuid,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final copy = List<int>.from(value);
    writes.add(_GattWrite(serviceUuid, characteristicUuid, copy));
    onWrite?.call(serviceUuid, characteristicUuid, copy);
  }
}
