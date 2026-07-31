import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/ble/gatt_connector_transport.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/heypocket_connector.dart';
import 'package:neorecall/src/devices/omi/offline_sync.dart';
import 'package:neorecall/src/devices/omi/omi_connector.dart';
import 'package:neorecall/src/devices/omi/plaud_connector.dart';
import 'package:neorecall/src/devices/omi/ring_protocol.dart';

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
      // Mirror the real device: acknowledge each session-preamble chunk with
      // `[0x12][0xfe][total][index]` before any command is answered.
      if (value[0] == 0x10 && value[1] == 0xfe) {
        scheduleMicrotask(
          () => transport.emit(
            WearableDeviceUuids.plaudService,
            WearableDeviceUuids.plaudNotify,
            <int>[0x12, 0xfe, value[2], value[3]],
          ),
        );
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

    // Each device-declared chunk is a self-contained Opus frame and must be
    // forwarded as its own packet (matching Omi's reference), not concatenated.
    final frames = <List<int>>[];
    final audioSub = connector.audioBytes.stream.listen(frames.add);
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
    await Future<void>.delayed(Duration.zero);
    expect(frames.map((frame) => frame.length), <int>[40, 40]);
    expect(frames[0].every((byte) => byte == 0xb8), isTrue);
    expect(frames[1].every((byte) => byte == 0x78), isTrue);
    await audioSub.cancel();
    await connector.dispose();
  });

  test('PLAUD sends the captured session preamble before any command', () async {
    final transport = _FakeWearableTransport();
    final connector = PlaudConnector(
      device: _device(WearableDeviceType.plaud),
      transport: transport,
    );
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.plaudWrite) return;
      if (value.length >= 4 && value[0] == 0x10 && value[1] == 0xfe) {
        scheduleMicrotask(
          () => transport.emit(
            WearableDeviceUuids.plaudService,
            WearableDeviceUuids.plaudNotify,
            <int>[0x12, 0xfe, value[2], value[3]],
          ),
        );
      }
    };

    await connector.connect();

    final preamble = transport.writes
        .where(
          (write) =>
              write.characteristic == WearableDeviceUuids.plaudWrite &&
              write.value.length >= 4 &&
              write.value[0] == 0x10 &&
              write.value[1] == 0xfe,
        )
        .toList();
    // Three chunks, framed [0x10][0xfe][total=3][index], carrying 256 bytes —
    // exactly what the official app sends (verified byte-for-byte against the
    // HCI capture; see _handshakeChunksHex).
    expect(preamble.length, 3);
    expect(preamble.map((write) => write.value[2]), everyElement(3));
    expect(preamble.map((write) => write.value[3]), <int>[0, 1, 2]);
    expect(
      preamble.fold<int>(0, (sum, write) => sum + write.value.length - 4),
      256,
    );
    expect(preamble.first.value.sublist(4, 8), <int>[0x55, 0x18, 0xb7, 0xd8]);
    expect(connector.handshakeCompleted, isTrue);

    // The preamble must precede every command write on the same channel.
    final firstCommand = transport.writes.indexWhere(
      (write) =>
          write.characteristic == WearableDeviceUuids.plaudWrite &&
          write.value.isNotEmpty &&
          write.value[0] == 0x01,
    );
    final lastPreamble = transport.writes.lastIndexWhere(
      (write) =>
          write.value.length >= 2 &&
          write.value[0] == 0x10 &&
          write.value[1] == 0xfe,
    );
    if (firstCommand != -1) expect(lastPreamble, lessThan(firstCommand));
    await connector.dispose();
  });

  test('HeyPocket separates ASCII control frames from binary MP3 audio', () async {
    final transport = _FakeWearableTransport();
    final connector = HeyPocketConnector(
      device: _device(WearableDeviceType.heyPocket),
      transport: transport,
    );
    // The device ignores commands until the APP&SK session-key handshake is
    // acknowledged; replies are routed by content, not by which channel.
    transport.onWrite = (service, characteristic, value) {
      if (characteristic == WearableDeviceUuids.heyPocketControlWrite &&
          ascii.decode(value).startsWith('APP&SK&')) {
        scheduleMicrotask(
          () => transport.emit(
            WearableDeviceUuids.heyPocketService,
            WearableDeviceUuids.heyPocketAudioNotify,
            ascii.encode('MCU&SK&OK'),
          ),
        );
      }
    };
    await connector.connect();
    expect(connector.codec, WearableAudioCodec.mp3);

    // A battery response updates the battery stream (routed by content).
    final batteryFuture = connector.batteryLevels.stream.first;
    transport.emit(
      WearableDeviceUuids.heyPocketService,
      WearableDeviceUuids.heyPocketControlNotify,
      ascii.encode('MCU&BAT&87'),
    );
    expect(await batteryFuture, 87);

    // Recording enables the audio stream and issues the documented command.
    await connector.startRecording();
    expect(
      transport.writes.map((write) => ascii.decode(write.value)),
      contains('APP&STA'),
    );

    final frames = <List<int>>[];
    final audioSub = connector.audioBytes.stream.listen(frames.add);
    final mp3Frame = <int>[0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22];
    transport.emit(
      WearableDeviceUuids.heyPocketService,
      WearableDeviceUuids.heyPocketAudioNotify,
      mp3Frame,
    );
    // An ASCII control frame arriving on the audio path is parsed, not captured.
    transport.emit(
      WearableDeviceUuids.heyPocketService,
      WearableDeviceUuids.heyPocketAudioNotify,
      ascii.encode('MCU&STO'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(frames, <List<int>>[mp3Frame]);

    await connector.stopRecording();
    expect(
      transport.writes.map((write) => ascii.decode(write.value)),
      contains('APP&STO'),
    );

    await audioSub.cancel();
    await connector.dispose();
  });

  test(
    'HeyPocket offline drain lists, downloads until MCU&OFF, and deletes',
    () async {
      final transport = _FakeWearableTransport();
      final connector = HeyPocketConnector(
        device: _device(WearableDeviceType.heyPocket),
        transport: transport,
      );
      final now = DateTime.now();
      String pad(int value) => value.toString().padLeft(2, '0');
      final ymd =
          '${now.year.toString().padLeft(4, '0')}${pad(now.month)}${pad(now.day)}';
      final today =
          '${now.year.toString().padLeft(4, '0')}-${pad(now.month)}-${pad(now.day)}';
      final fileId = '${ymd}120000';
      final mp3 = <int>[0xFF, 0xFB, 0x00, 0x11, 0x22, 0x33];

      // Real protocol: APP&SK auth first, per-day listing terminated by
      // MCU&LIST&<count>, download ending in MCU&OFF, then delete ack. Captured
      // firmware sends control on the a3 channel and MP3 data on a1; the
      // connector routes both by content, so this exercises that mapping.
      transport.onWrite = (service, characteristic, value) {
        if (characteristic != WearableDeviceUuids.heyPocketControlWrite) return;
        final command = ascii.decode(value);
        void ctrl(String s) => scheduleMicrotask(
          () => transport.emit(
            WearableDeviceUuids.heyPocketService,
            WearableDeviceUuids.heyPocketAudioNotify,
            ascii.encode(s),
          ),
        );
        if (command.startsWith('APP&SK&')) {
          ctrl('MCU&SK&OK');
        } else if (command == 'APP&LIST&$today') {
          ctrl('MCU&F&$today&$fileId&1');
          ctrl('MCU&LIST&001');
        } else if (command.startsWith('APP&LIST&')) {
          ctrl('MCU&LIST&0');
        } else if (command == 'APP&U&$today&$fileId') {
          scheduleMicrotask(() {
            ctrl('MCU&U&6');
            transport.emit(
              WearableDeviceUuids.heyPocketService,
              WearableDeviceUuids.heyPocketControlNotify,
              mp3,
            );
            ctrl('MCU&OFF');
          });
        } else if (command == 'APP&D&$today&$fileId') {
          ctrl('MCU&D');
        }
      };

      await connector.connect();

      // Downloaded bytes must never leak into the live-capture stream.
      final captured = <List<int>>[];
      final audioSub = connector.audioBytes.stream.listen(captured.add);

      final recordings = <WearableRecording>[];
      final count = await connector.drainStoredAudio((recording) async {
        recordings.add(recording);
      });

      expect(count, 1);
      expect(recordings.single.bytes, mp3);
      expect(recordings.single.contentType, 'audio/mpeg');
      expect(recordings.single.filename, 'heypocket-$today-$fileId.mp3');
      expect(captured, isEmpty);
      // The file is deleted only after the recording was handed off.
      expect(
        transport.writes.map((write) => ascii.decode(write.value)),
        containsAll(<String>['APP&U&$today&$fileId', 'APP&D&$today&$fileId']),
      );

      await audioSub.cancel();
      await connector.dispose();
    },
  );

  test('HeyPocket readBatteryLevel round-trips APP&BAT/MCU&BAT', () async {
    final transport = _FakeWearableTransport();
    final connector = HeyPocketConnector(
      device: _device(WearableDeviceType.heyPocket),
      transport: transport,
    );
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.heyPocketControlWrite) return;
      final cmd = ascii.decode(value);
      void ctrl(String s) => scheduleMicrotask(
        () => transport.emit(
          WearableDeviceUuids.heyPocketService,
          WearableDeviceUuids.heyPocketAudioNotify,
          ascii.encode(s),
        ),
      );
      if (cmd.startsWith('APP&SK&')) {
        ctrl('MCU&SK&OK');
      } else if (cmd == 'APP&BAT') {
        ctrl('MCU&BAT&64');
      }
    };

    await connector.connect();
    expect(await connector.readBatteryLevel(), 64);
    await connector.dispose();
  });

  test(
    'Omi ring drain advances the read cursor only after durable ingest',
    () async {
      final transport = _FakeWearableTransport();
      final connector = OmiConnector(
        device: _device(WearableDeviceType.omi),
        transport: transport,
      );
      // RingStatus (usedBytes, unreadPackets=1, freeBytes, rtcValid) so the
      // drain's status probe on 30295782 finds data to pull.
      transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
      ];
      // Default codec is PCM8, so the drain decodes without native Opus (which
      // is unavailable in the test VM).
      expect(connector.codec, WearableAudioCodec.pcm8);

      // One 444-byte ring record: [4-byte timestamp][440-byte payload]; the
      // payload holds a single size-prefixed PCM8 frame then zero padding.
      final frame = List<int>.filled(8, 0x40);
      final payload = <int>[
        frame.length,
        ...frame,
        ...List<int>.filled(440 - (frame.length + 1), 0),
      ];
      final record = <int>[0, 0, 0, 1, ...payload];
      expect(record.length, 444);

      // Answer each storage command with the documented notify sequence.
      transport.onWrite = (service, characteristic, value) {
        if (characteristic != WearableDeviceUuids.omiStorageData ||
            value.isEmpty) {
          return;
        }
        void emit(List<int> notification) => scheduleMicrotask(
          () => transport.emit(
            WearableDeviceUuids.omiStorageService,
            WearableDeviceUuids.omiStorageData,
            notification,
          ),
        );
        switch (value[0]) {
          case RingProtocol.cmdInfo:
            emit(<int>[
              RingProtocol.notifyInfo,
              ...List<int>.filled(7, 0), 0, // readSeq u64 BE = 0
              ...List<int>.filled(7, 0), 1, // writeSeq u64 BE = 1
              0, 0, 0, 0, // capacity
              ...List<int>.filled(8, 0), // dropped
              0, 0, // packet size
            ]);
          case RingProtocol.cmdRead:
            emit(<int>[RingProtocol.notifyData, ...record]);
            emit(<int>[
              RingProtocol.notifyDone,
              0, // status ok
              ...List<int>.filled(7, 0), 1, // nextSeq u64 BE = 1
            ]);
        }
      };

      var advancesAtIngest = -1;
      final recordings = <WearableRecording>[];
      final count = await connector.drainStoredAudio((recording) async {
        recordings.add(recording);
        // The ring cursor must NOT have advanced yet: ingest happens first.
        advancesAtIngest = transport.writes
            .where(
              (w) => w.value.isNotEmpty && w.value[0] == RingProtocol.cmdAdvance,
            )
            .length;
      });

      expect(count, 1);
      expect(recordings.single.contentType, 'audio/wav');
      // WAV header (44 bytes) + decoded PCM16 (8 PCM8 samples -> 16 bytes).
      expect(recordings.single.bytes.length, 44 + 16);
      // No advance had been written at the moment of ingest...
      expect(advancesAtIngest, 0);
      // ...and exactly one advance, targeting nextSeq = 1, was written after.
      final advances = transport.writes
          .where(
            (w) => w.value.isNotEmpty && w.value[0] == RingProtocol.cmdAdvance,
          )
          .toList();
      expect(advances.length, 1);
      expect(advances.single.value.sublist(1), <int>[0, 0, 0, 0, 0, 0, 0, 1]);

      await connector.dispose();
    },
  );

  test('Omi ring drain does not advance the cursor when ingest fails', () async {
    final transport = _FakeWearableTransport();
    final connector = OmiConnector(
      device: _device(WearableDeviceType.omi),
      transport: transport,
    );
    transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
      0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
    ];
    final frame = List<int>.filled(8, 0x40);
    final payload = <int>[
      frame.length,
      ...frame,
      ...List<int>.filled(440 - (frame.length + 1), 0),
    ];
    final record = <int>[0, 0, 0, 1, ...payload];
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.omiStorageData ||
          value.isEmpty) {
        return;
      }
      void emit(List<int> notification) => scheduleMicrotask(
        () => transport.emit(
          WearableDeviceUuids.omiStorageService,
          WearableDeviceUuids.omiStorageData,
          notification,
        ),
      );
      switch (value[0]) {
        case RingProtocol.cmdInfo:
          emit(<int>[
            RingProtocol.notifyInfo,
            ...List<int>.filled(7, 0), 0,
            ...List<int>.filled(7, 0), 1,
            0, 0, 0, 0,
            ...List<int>.filled(8, 0),
            0, 0,
          ]);
        case RingProtocol.cmdRead:
          emit(<int>[RingProtocol.notifyData, ...record]);
          emit(<int>[RingProtocol.notifyDone, 0, ...List<int>.filled(7, 0), 1]);
      }
    };

    // An ingest failure must leave the records on the device (no advance), so
    // the range is re-drained next sync rather than lost.
    await expectLater(
      connector.drainStoredAudio((recording) async {
        throw StateError('ingest failed');
      }),
      throwsA(isA<StateError>()),
    );
    final advances = transport.writes
        .where(
          (w) => w.value.isNotEmpty && w.value[0] == RingProtocol.cmdAdvance,
        )
        .toList();
    expect(advances, isEmpty);

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

  // The fake exposes every characteristic as present so gated connector paths
  // (e.g. the Omi storage drain) run exactly as before this capability existed.
  @override
  bool hasCharacteristic(String serviceUuid, String characteristicUuid) => true;

  @override
  List<GattDiscoveredCharacteristic> get discoveredCharacteristics =>
      const <GattDiscoveredCharacteristic>[];

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

  final Map<String, List<int>> readValues = <String, List<int>>{};

  @override
  Future<List<int>> readCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) async => readValues[characteristicUuid] ?? <int>[];

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
