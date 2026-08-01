import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/ble/gatt_connector_transport.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/heypocket_connector.dart';
import 'package:neorecall/src/devices/omi/offline_sync.dart';
import 'package:neorecall/src/devices/omi/omi_connector.dart';
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

  group('HeyPocket capture time', () {
    // A synced recording that lands on the wrong day is indistinguishable from
    // one that never synced: the user looks where they recorded and finds
    // nothing. The time is in the file id, not in the listing date.
    test('comes from the file id, not just the day', () {
      const file = HeyPocketStoredFile(date: '2026-07-31', fileId: '20260731180000');
      final captured = file.capturedAt!;
      expect(captured.isUtc, isTrue);
      expect(captured, DateTime(2026, 7, 31, 18).toUtc());
    });

    test('two recordings from one day do not collapse onto one instant', () {
      const morning = HeyPocketStoredFile(date: '2026-07-31', fileId: '20260731080000');
      const evening = HeyPocketStoredFile(date: '2026-07-31', fileId: '20260731203000');
      expect(morning.capturedAt, isNot(evening.capturedAt));
      expect(
        evening.capturedAt!.difference(morning.capturedAt!),
        const Duration(hours: 12, minutes: 30),
      );
    });

    test('a file id without a timestamp still falls back to its day', () {
      const file = HeyPocketStoredFile(date: '2026-07-31', fileId: '0007');
      expect(file.capturedAt, DateTime.tryParse('2026-07-31')?.toUtc());
    });
  });

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
      // The device reports PCM8 (codec id 1) so the drain decodes without a
      // native Opus codec, which the test VM does not have. Stated explicitly:
      // the connector's fallback is Opus, matching real hardware.
      transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
      transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
      ];
      await connector.connect();
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
            // Real firmware always announces the transfer size first; the drain
            // uses it to prove nothing was dropped in transit.
            emit(<int>[
              RingProtocol.notifyReadBegin,
              ...List<int>.filled(8, 0), // transferStartSeq u64 BE = 0
              0, 0, 0, 1, // packetCount u32 BE = 1
            ]);
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
    // PCM8 (codec id 1) so the drain decodes without a native Opus codec.
    transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
    transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
      0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
    ];
    await connector.connect();
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
          // Real firmware announces the transfer size first.
          emit(<int>[
            RingProtocol.notifyReadBegin,
            ...List<int>.filled(8, 0),
            0, 0, 0, 1, // packetCount = 1
          ]);
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

  test('a drain that loses a notification is retried, never ingested', () async {
    // The ring arrives as one unframed byte stream, so a single notification
    // dropped by the host stack (documented on Web Bluetooth) shifts every
    // following 444-byte boundary — the audio decodes into garbage instead of
    // failing. The device still reports DONE status=0, because it sent
    // everything. Only READ_BEGIN's announced packet count catches this.
    final transport = _FakeWearableTransport();
    final connector = OmiConnector(
      device: _device(WearableDeviceType.omi),
      transport: transport,
    );
    transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
    transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
      0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
    ];
    await connector.connect();
    final frame = List<int>.filled(8, 0x40);
    final record = <int>[
      0, 0, 0, 1,
      frame.length,
      ...frame,
      ...List<int>.filled(440 - (frame.length + 1), 0),
    ];
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.omiStorageData ||
          value.isEmpty) {
        return;
      }
      void emit(List<int> n) => scheduleMicrotask(
        () => transport.emit(
          WearableDeviceUuids.omiStorageService,
          WearableDeviceUuids.omiStorageData,
          n,
        ),
      );
      switch (value[0]) {
        case RingProtocol.cmdInfo:
          emit(<int>[
            RingProtocol.notifyInfo,
            ...List<int>.filled(7, 0), 0,
            ...List<int>.filled(7, 0), 2,
            0, 0, 0, 0,
            ...List<int>.filled(8, 0),
            0, 0,
          ]);
        case RingProtocol.cmdRead:
          // Two packets announced...
          emit(<int>[
            RingProtocol.notifyReadBegin,
            ...List<int>.filled(8, 0),
            0, 0, 0, 2,
          ]);
          // ...but only one arrives: the second is dropped in transit.
          emit(<int>[RingProtocol.notifyData, ...record]);
          emit(<int>[RingProtocol.notifyDone, 0, ...List<int>.filled(7, 0), 2]);
      }
    };

    var ingested = 0;
    // Reported as a failure, not as "no new recordings" — the device is holding
    // audio, and a silent zero would read as an empty device.
    await expectLater(
      connector.drainStoredAudio((_) async => ingested += 1),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('received 1 of 2 packets'),
        ),
      ),
    );

    expect(ingested, 0, reason: 'a short transfer must never reach the import');
    expect(
      transport.writes.where(
        (w) => w.value.isNotEmpty && w.value[0] == RingProtocol.cmdAdvance,
      ),
      isEmpty,
      reason: 'the cursor stays put so the range is re-read intact next sweep',
    );
    expect(connector.syncDiagnostics['packetsExpected'], 2);
    expect(connector.syncDiagnostics['packetsTransferred'], 1);

    await connector.dispose();
  });

  group('draining while live capture runs', () {
    // A wearable that keeps recording while the phone is away only helps if the
    // app can pull that backlog *and* stream live at once — otherwise every
    // reconnect forces a choice between the past and the present. Whether that
    // is safe is a property of the device, so it is a capability, and claiming
    // it wrongly corrupts both streams instead of failing loudly.

    test('Omi allows it: the ring and live audio are separate services', () {
      final transport = _FakeWearableTransport();
      final connector = OmiConnector(
        device: _device(WearableDeviceType.omi),
        transport: transport,
      );
      expect(connector.supportsConcurrentCapture, isTrue);
      // The claim rests entirely on these being different characteristics on
      // different services; if a UUID edit ever collapsed them, a concurrent
      // drain would start eating live audio.
      expect(
        WearableDeviceUuids.omiAudioData,
        isNot(WearableDeviceUuids.omiStorageData),
      );
      expect(
        WearableDeviceUuids.omiService,
        isNot(WearableDeviceUuids.omiStorageService),
      );
    });

    test('Omi still drains while it is recording', () async {
      final transport = _FakeWearableTransport();
      final connector = OmiConnector(
        device: _device(WearableDeviceType.omi),
        transport: transport,
      );
      transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
      transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
        0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
      ];
      await connector.connect();
      await connector.startRecording();
      expect(connector.recording, isTrue);

      await connector.drainStoredAudio((_) async {});

      // Previously this returned 0 without touching the device. The drain must
      // now reach the ring: it asks for INFO on the storage characteristic.
      final storageWrites = transport.writes
          .where((w) => w.characteristic == WearableDeviceUuids.omiStorageData)
          .toList();
      expect(
        storageWrites.any((w) => w.value.first == RingProtocol.cmdInfo),
        isTrue,
        reason: 'a recording Omi must still be asked for its backlog',
      );
      await connector.dispose();
    });

    test('HeyPocket refuses it: one notify channel carries both', () async {
      // HeyPocket routes binary notifications to the download buffer while a
      // transfer is active and to live audio otherwise — the two are told apart
      // by context, not by channel. Draining mid-capture would splice live
      // frames into the downloaded file and lose them from the recording.
      final transport = _FakeWearableTransport();
      final connector = HeyPocketConnector(
        device: _device(WearableDeviceType.heyPocket),
        transport: transport,
      );
      expect(connector.supportsConcurrentCapture, isFalse);
      await connector.dispose();
    });
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
