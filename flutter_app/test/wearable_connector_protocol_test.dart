import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/ble/gatt_connector_transport.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/heypocket_connector.dart';
import 'package:neorecall/src/devices/omi/memoket_connector.dart';
import 'package:neorecall/src/devices/omi/memoket_protocol.dart';
import 'package:neorecall/src/devices/omi/offline_sync.dart';
import 'package:neorecall/src/devices/omi/omi_connector.dart';
import 'package:neorecall/src/devices/omi/ring_protocol.dart';
import 'package:neorecall/src/devices/wearable_ingested_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WearableIngestedFiles.resetForTest();
  });

  test('OmiGlass uses its documented Opus fallback codec', () async {
    final connector = OmiGlassConnector(
      device: _device(WearableDeviceType.omiGlass),
      transport: _FakeWearableTransport(),
    );
    await connector.connect();
    expect(connector.codec, WearableAudioCodec.opus);
    await connector.dispose();
  });

  test(
    'HeyPocket separates ASCII control frames from binary MP3 audio',
    () async {
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
    },
  );

  test(
    'HeyPocket offline drain lists, downloads until MCU&OFF, and deletes',
    () async {
      final transport = _FakeWearableTransport();
      final connector = HeyPocketConnector(
        device: _device(WearableDeviceType.heyPocket),
        transport: transport,
      );
      final now = DateTime.now().toUtc();
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
      const file = HeyPocketStoredFile(
        date: '2026-07-31',
        fileId: '20260731180000',
      );
      final captured = file.capturedAt!;
      expect(captured.isUtc, isTrue);
      expect(captured, DateTime.utc(2026, 7, 31, 18));
    });

    test('two recordings from one day do not collapse onto one instant', () {
      const morning = HeyPocketStoredFile(
        date: '2026-07-31',
        fileId: '20260731080000',
      );
      const evening = HeyPocketStoredFile(
        date: '2026-07-31',
        fileId: '20260731203000',
      );
      expect(morning.capturedAt, isNot(evening.capturedAt));
      expect(
        evening.capturedAt!.difference(morning.capturedAt!),
        const Duration(hours: 12, minutes: 30),
      );
    });

    test('a file id without a timestamp still falls back to its day', () {
      const file = HeyPocketStoredFile(date: '2026-07-31', fileId: '0007');
      expect(file.capturedAt, DateTime.utc(2026, 7, 31));
    });
  });

  test(
    'Memoket remote start/stop and live frames follow the HCI capture',
    () async {
      final transport = _FakeWearableTransport();
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: transport,
      );
      _bindMemoketReplies(transport);

      await connector.connect();
      expect(connector.codec, WearableAudioCodec.opus);
      expect(await connector.readBatteryLevel(), 78);
      expect(
        transport.writes.any(
          (write) =>
              write.value.toString() == MemoketProtocol.batteryQuery.toString(),
        ),
        isTrue,
      );

      await connector.startRecording();
      expect(
        transport.writes.any(
          (write) =>
              write.value.toString() == <int>[0x01, 0x00, 0x00].toString(),
        ),
        isTrue,
      );

      final frames = <List<int>>[];
      final audioSub = connector.audioBytes.stream.listen(frames.add);
      transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketAudioNotify,
        <int>[0, 0, 0, 0, 3, 0xbc, 0x62, 0x11],
      );
      await Future<void>.delayed(Duration.zero);
      expect(frames, <List<int>>[
        <int>[0xbc, 0x62, 0x11],
      ]);

      await connector.stopRecording();
      expect(
        transport.writes.any(
          (write) => write.value.toString() == <int>[0x02, 0x00].toString(),
        ),
        isTrue,
      );
      expect(
        transport.writes.any(
          (write) =>
              write.value.first == MemoketProtocol.opDelete &&
              ascii
                  .decode(write.value.sublist(2))
                  .contains('20260905_222343_2.opus'),
        ),
        isTrue,
        reason:
            'a live take must be deleted so the next drain does not re-import it',
      );

      await audioSub.cancel();
      await connector.dispose();
    },
  );

  test('Memoket live 480-byte notifies emit six Opus frames', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);
    await connector.connect();
    await connector.startRecording();
    final frames = <List<int>>[];
    final audioSub = connector.audioBytes.stream.listen(frames.add);
    final payload = <int>[
      for (var i = 0; i < 6; i += 1) ...<int>[
        0xbc,
        i,
        ...List<int>.filled(78, 0),
      ],
    ];
    transport.emit(
      WearableDeviceUuids.memoketService,
      WearableDeviceUuids.memoketAudioNotify,
      <int>[0, 0, 0, 0, 1, ...payload],
    );
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(6));
    expect(frames[2].first, 0xbc);
    expect(frames[2][1], 2);
    await connector.stopRecording();
    await audioSub.cancel();
    await connector.dispose();
  });

  test('Memoket stop does not delete a take that sent no live audio', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);
    await connector.connect();
    await connector.startRecording();
    await connector.stopRecording();
    expect(
      transport.writes.any(
        (write) =>
            write.value.isNotEmpty &&
            write.value.first == MemoketProtocol.opDelete,
      ),
      isFalse,
    );
    await connector.dispose();
  });

  test('Memoket does not write a battery query while live', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);

    await connector.connect();
    expect(await connector.readBatteryLevel(), 78);
    await connector.startRecording();
    final writesAfterStart = transport.writes.length;
    expect(await connector.readBatteryLevel(), 78);
    expect(
      transport.writes.skip(writesAfterStart).any(
        (write) =>
            write.value.toString() == MemoketProtocol.batteryQuery.toString(),
      ),
      isFalse,
    );
    await connector.stopRecording();
    await connector.dispose();
  });

  test('Memoket radio teardown does not stop an on-device take', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);
    await connector.connect();
    await connector.startRecording();
    expect(
      transport.writes.any(
        (write) => write.value.first == MemoketProtocol.opRecordStart,
      ),
      isTrue,
    );
    final stopsBefore = transport.writes
        .where((write) => write.value.first == MemoketProtocol.opRecordStop)
        .length;
    await connector.disconnect();
    expect(
      transport.writes
          .where((write) => write.value.first == MemoketProtocol.opRecordStop)
          .length,
      stopsBefore,
      reason: 'a background GATT drop must not send 02 and split the take',
    );
    await connector.dispose();
  });

  test('Memoket live frames while idle keep the Gem from being listed', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);
    await connector.connect();
    final payload = <int>[
      for (var i = 0; i < 6; i += 1) ...<int>[
        0xbc,
        i,
        ...List<int>.filled(78, 0),
      ],
    ];
    transport.emit(
      WearableDeviceUuids.memoketService,
      WearableDeviceUuids.memoketAudioNotify,
      <int>[0, 0, 0, 0, 1, ...payload],
    );
    await Future<void>.delayed(Duration.zero);
    final listsBefore = transport.writes
        .where((write) => write.value.first == MemoketProtocol.opListFiles)
        .length;
    final startsBefore = transport.writes
        .where((write) => write.value.first == MemoketProtocol.opRecordStart)
        .length;
    expect(await connector.drainStoredAudio((_) async {}), 0);
    expect(
      transport.writes
          .where((write) => write.value.first == MemoketProtocol.opListFiles)
          .length,
      listsBefore,
    );
    await connector.startRecording();
    expect(
      transport.writes
          .where((write) => write.value.first == MemoketProtocol.opRecordStart)
          .length,
      startsBefore,
      reason: 'joining an already-live Gem must not send 01 and restart it',
    );
    await connector.dispose();
  });

  test('Memoket handshake skips control writes when live audio is already flowing', () async {
    final transport = _FakeWearableTransport();
    transport.onSubscribe = (characteristic) {
      if (characteristic != WearableDeviceUuids.memoketAudioNotify) return;
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        transport.emit(
          WearableDeviceUuids.memoketService,
          WearableDeviceUuids.memoketAudioNotify,
          <int>[
            0,
            0,
            0,
            0,
            1,
            for (var i = 0; i < 6; i += 1) ...<int>[
              0xbc,
              i,
              ...List<int>.filled(78, 0),
            ],
          ],
        );
      });
    };
    _bindMemoketReplies(transport);
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    await connector.connect();
    expect(
      transport.writes.where(
        (write) =>
            write.value.first == MemoketProtocol.opBattery ||
            write.value.first == MemoketProtocol.opFirmware ||
            write.value.first == MemoketProtocol.opSetTime ||
            write.value.first == MemoketProtocol.opListFiles,
      ),
      isEmpty,
      reason: 'handshake writes share the control characteristic with start/stop',
    );
    await connector.dispose();
  });

  test('Memoket vendor battery is not replaced by a 100% standard reading', () async {
    final transport = _FakeWearableTransport();
    transport.readValues[WearableDeviceUuids.batteryLevel] = <int>[100];
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);

    await connector.connect();
    expect(await connector.readBatteryLevel(), 78);
    transport.emit(
      WearableDeviceUuids.batteryService,
      WearableDeviceUuids.batteryLevel,
      <int>[100],
    );
    await Future<void>.delayed(Duration.zero);
    expect(await connector.readBatteryLevel(), 78);
    await connector.dispose();
  });

  test('Memoket falls back to the standard battery when the vendor query is silent', () async {
    final transport = _FakeWearableTransport();
    transport.readValues[WearableDeviceUuids.batteryLevel] = <int>[64];
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport, silentBattery: true);

    await connector.connect();
    expect(await connector.readBatteryLevel(), 64);
    await connector.dispose();
  });

  test(
    'Memoket hardware start/stop raises control events without a phone command',
    () async {
      final transport = _FakeWearableTransport();
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: transport,
      );
      _bindMemoketReplies(transport);

      await connector.connect();

      final buttons = <List<int>>[];
      final frames = <List<int>>[];
      final buttonSub = connector.buttonEvents.stream.listen(buttons.add);
      final audioSub = connector.audioBytes.stream.listen(frames.add);

      transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketControlNotify,
        <int>[
          MemoketProtocol.opRecordStart,
          0x01,
          0x01,
          ...ascii.encode('20260905_223000_2.opus'),
        ],
      );
      await Future<void>.delayed(Duration.zero);
      expect(buttons, <List<int>>[
        <int>[WearableControlCodes.startRecording],
      ]);

      transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketAudioNotify,
        <int>[0, 0, 0, 0, 3, 0xbc, 0x62, 0x11],
      );
      await Future<void>.delayed(Duration.zero);
      expect(frames, <List<int>>[
        <int>[0xbc, 0x62, 0x11],
      ]);

      final writesBeforeAttach = List<_GattWrite>.from(transport.writes);
      await connector.startRecording();
      expect(
        transport.writes
            .skip(writesBeforeAttach.length)
            .any(
              (write) =>
                  write.value.toString() == <int>[0x01, 0x00, 0x00].toString(),
            ),
        isFalse,
        reason: 'a take the Gem already started must not be started again',
      );

      transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketControlNotify,
        <int>[
          MemoketProtocol.opRecordStop,
          0x00,
          0x01,
          0x00,
          ...ascii.encode('20260905_223000_2.opus'),
        ],
      );
      await Future<void>.delayed(Duration.zero);
      expect(buttons.last, <int>[WearableControlCodes.stopRecording]);

      final writesBeforeStop = transport.writes.length;
      await connector.stopRecording();
      expect(
        transport.writes
            .skip(writesBeforeStop)
            .any(
              (write) => write.value.toString() == <int>[0x02, 0x00].toString(),
            ),
        isFalse,
        reason: 'a take the Gem already stopped must not be stopped again',
      );
      expect(
        transport.writes
            .skip(writesBeforeStop)
            .any(
              (write) =>
                  write.value.isNotEmpty &&
                  write.value.first == MemoketProtocol.opDelete &&
                  ascii
                      .decode(write.value.sublist(2), allowInvalid: true)
                      .contains('20260905_223000_2.opus'),
            ),
        isTrue,
      );

      transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketControlNotify,
        <int>[
          MemoketProtocol.opRecordStart,
          0x01,
          0x01,
          ...ascii.encode('20260905_223100_2.opus'),
        ],
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        buttons
            .where(
              (event) => event.first == WearableControlCodes.startRecording,
            )
            .length,
        1,
        reason: 'a late start ack after stop must not open another take',
      );

      await buttonSub.cancel();
      await audioSub.cancel();
      await connector.dispose();
    },
  );

  test(
    'Memoket offline drain lists, downloads, wraps Opus, and deletes',
    () async {
      final transport = _FakeWearableTransport();
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: transport,
      );
      final chunk = List<int>.filled(480, 0xbc);
      _bindMemoketReplies(transport, fileChunk: chunk);

      await connector.connect();

      final captured = <List<int>>[];
      final audioSub = connector.audioBytes.stream.listen(captured.add);
      final recordings = <WearableRecording>[];
      final count = await connector.drainStoredAudio((recording) async {
        recordings.add(recording);
      });

      expect(count, 1);
      expect(recordings.single.contentType, 'audio/ogg');
      expect(recordings.single.filename, 'memoket-20260905_222817_2.ogg');
      expect(recordings.single.bytes.sublist(0, 4), ascii.encode('OggS'));
      expect(captured, isEmpty);
      expect(
        transport.writes.any(
          (write) => write.value.first == MemoketProtocol.opDownload,
        ),
        isTrue,
      );
      expect(
        transport.writes.any(
          (write) => write.value.first == MemoketProtocol.opDelete,
        ),
        isTrue,
      );

      await audioSub.cancel();
      await connector.dispose();
    },
  );

  test('a long Memoket file keeps copying after 90 seconds', () {
    fakeAsync((async) {
      final transport = _FakeWearableTransport();
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: transport,
      );
      const filename = '20260907_080000_2.opus';
      final chunk = List<int>.filled(480, 0xbc);
      const chunkCount = 100;
      void ctrl(List<int> value) => scheduleMicrotask(
        () => transport.emit(
          WearableDeviceUuids.memoketService,
          WearableDeviceUuids.memoketControlNotify,
          value,
        ),
      );
      transport.onWrite = (service, characteristic, value) {
        if (characteristic != WearableDeviceUuids.memoketControlWrite) return;
        if (value.isEmpty) return;
        switch (value.first) {
          case MemoketProtocol.opPing:
            ctrl(<int>[MemoketProtocol.opPing, 0x00]);
          case MemoketProtocol.opBattery:
            ctrl(<int>[MemoketProtocol.opBattery, 78, 0x02]);
          case MemoketProtocol.opFirmware:
            ctrl(<int>[
              MemoketProtocol.opFirmware,
              ...ascii.encode('01.42.01.10'),
            ]);
          case MemoketProtocol.opTimeQuery:
            ctrl(<int>[MemoketProtocol.opTimeQuery, 0x68, 0, 0, 0, 0]);
          case MemoketProtocol.opSetTime:
            ctrl(<int>[MemoketProtocol.opSetTime, 0x01]);
          case MemoketProtocol.opStorage:
            ctrl(<int>[MemoketProtocol.opStorage, 0x0d, 0x00]);
          case MemoketProtocol.opListFiles:
            final size = chunk.length * chunkCount;
            ctrl(<int>[
              MemoketProtocol.opListFiles,
              0x01,
              0x00,
              0x00,
              100,
              filename.length,
              ...ascii.encode(filename),
              (size >> 24) & 0xff,
              (size >> 16) & 0xff,
              (size >> 8) & 0xff,
              size & 0xff,
            ]);
            ctrl(<int>[MemoketProtocol.opListFiles, 0xff]);
          case MemoketProtocol.opDownload:
            scheduleMicrotask(() async {
              for (var i = 0; i < chunkCount; i += 1) {
                await Future<void>.delayed(
                  const Duration(milliseconds: 1150),
                );
                transport.emit(
                  WearableDeviceUuids.memoketService,
                  WearableDeviceUuids.memoketFileNotify,
                  chunk,
                );
              }
              ctrl(<int>[MemoketProtocol.opDownload, 0x02]);
            });
          case MemoketProtocol.opDelete:
            ctrl(<int>[MemoketProtocol.opDelete, 0x01]);
        }
      };

      var count = 0;
      Object? error;
      unawaited(
        connector
            .connect()
            .then((_) => connector.drainStoredAudio((_) async {}))
            .then((value) {
              count = value;
            }, onError: (Object e, StackTrace _) => error = e),
      );
      async.elapse(const Duration(seconds: 130));
      expect(error, isNull, reason: error?.toString());
      expect(count, 1);
      unawaited(connector.dispose());
      async.flushMicrotasks();
    });
  });

  test('Memoket drain skips a file already captured live', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await WearableIngestedFiles.remember(
      'device-id',
      '20260905_222817_2.opus',
    );
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    final chunk = List<int>.filled(480, 0xbc);
    _bindMemoketReplies(transport, fileChunk: chunk);
    await connector.connect();
    final count = await connector.drainStoredAudio((_) async {});
    expect(count, 0);
    expect(
      transport.writes.any(
        (write) => write.value.first == MemoketProtocol.opDownload,
      ),
      isFalse,
    );
    expect(
      transport.writes.any(
        (write) => write.value.first == MemoketProtocol.opDelete,
      ),
      isTrue,
    );
    await connector.dispose();
  });

  test(
    'Memoket drain ignores a repeated list entry for the same file',
    () async {
      final transport = _FakeWearableTransport();
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: transport,
      );
      final chunk = List<int>.filled(480, 0xbc);
      _bindMemoketReplies(transport, fileChunk: chunk, repeatListEntry: true);
      await connector.connect();
      final count = await connector.drainStoredAudio((_) async {});
      expect(count, 1);
      expect(
        transport.writes
            .where((write) => write.value.first == MemoketProtocol.opDownload)
            .length,
        1,
      );
      expect(
        transport.writes
            .where((write) => write.value.first == MemoketProtocol.opDelete)
            .length,
        1,
      );
      await connector.dispose();
    },
  );

  test('Memoket drain reports byte progress inside each file', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    const first = '20260905_222817_2.opus';
    const second = '20260905_222900_2.opus';
    final chunk = List<int>.filled(480, 0xbc);
    void ctrl(List<int> value) => scheduleMicrotask(
      () => transport.emit(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketControlNotify,
        value,
      ),
    );
    List<int> listEntry(String name) => <int>[
      MemoketProtocol.opListFiles,
      0x01,
      0x00,
      0x00,
      0x0a,
      name.length,
      ...ascii.encode(name),
      0x00,
      0x00,
      0x03,
      0xc0,
    ];
    transport.onWrite = (service, characteristic, value) {
      if (characteristic != WearableDeviceUuids.memoketControlWrite) return;
      if (value.isEmpty) return;
      switch (value.first) {
        case MemoketProtocol.opPing:
          ctrl(<int>[MemoketProtocol.opPing, 0x00]);
        case MemoketProtocol.opBattery:
          ctrl(<int>[MemoketProtocol.opBattery, 78, 0x02]);
        case MemoketProtocol.opFirmware:
          ctrl(<int>[
            MemoketProtocol.opFirmware,
            ...ascii.encode('01.42.01.10'),
          ]);
        case MemoketProtocol.opTimeQuery:
          ctrl(<int>[MemoketProtocol.opTimeQuery, 0x68, 0, 0, 0, 0]);
        case MemoketProtocol.opSetTime:
          ctrl(<int>[MemoketProtocol.opSetTime, 0x01]);
        case MemoketProtocol.opStorage:
          ctrl(<int>[MemoketProtocol.opStorage, 0x0d, 0x00]);
        case MemoketProtocol.opListFiles:
          ctrl(listEntry(first));
          ctrl(listEntry(second));
          ctrl(<int>[MemoketProtocol.opListFiles, 0xff]);
        case MemoketProtocol.opDownload:
          scheduleMicrotask(() async {
            transport.emit(
              WearableDeviceUuids.memoketService,
              WearableDeviceUuids.memoketFileNotify,
              chunk,
            );
            await Future<void>.delayed(const Duration(milliseconds: 30));
            transport.emit(
              WearableDeviceUuids.memoketService,
              WearableDeviceUuids.memoketFileNotify,
              chunk,
            );
            ctrl(<int>[MemoketProtocol.opDownload, 0x02]);
          });
        case MemoketProtocol.opDelete:
          ctrl(<int>[MemoketProtocol.opDelete, 0x01]);
      }
    };

    await connector.connect();
    final fractions = <double>[];
    final sub = connector.syncProgress.listen((progress) {
      final fraction = progress.fraction;
      if (fraction != null) fractions.add(fraction);
    });
    final count = await connector.drainStoredAudio((_) async {});
    await sub.cancel();

    expect(count, 2);
    expect(fractions, isNotEmpty);
    expect(fractions.first, closeTo(0.0, 0.001));
    expect(
      fractions.any((value) => value > 0.05 && value < 0.45),
      isTrue,
      reason: 'the first file must move the bar before 50%',
    );
    expect(
      fractions.any((value) => value > 0.55 && value < 0.99),
      isTrue,
      reason: 'the second file must not sit at 50% for the whole copy',
    );
    expect(
      fractions.reduce((a, b) => a > b ? a : b),
      greaterThan(0.99),
      reason: 'finishing the last file must take the bar off 50%',
    );
    await connector.dispose();
  });

  test('Memoket sync maps a BLE write failure to a reconnect hint', () async {
    final transport = _FakeWearableTransport();
    final connector = MemoketConnector(
      device: _device(WearableDeviceType.memoket),
      transport: transport,
    );
    _bindMemoketReplies(transport);
    await connector.connect();
    transport.writeError = StateError(
      'UniversalBleException: Code: UniversalBleErrorCode.unknownError, '
      'Message: Unable to establish connection on channel: '
      '"dev.flutter.pigeon.universal_ble.UniversalBlePlatformChannel.writeValue".',
    );

    await expectLater(
      connector.drainStoredAudio((_) async {}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('official Memoket app'),
        ),
      ),
    );
    await connector.dispose();
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

  test('a time-sync write is never counted as a ring advance', () async {
    // The epoch goes out little-endian, so the first byte of the time-sync
    // write is the low byte of the current second: for one second in every 256
    // it is 0x12, which is also cmdAdvance. Counting advances by first byte
    // alone therefore failed on the clock rather than on the code.
    final transport = _FakeWearableTransport();
    final connector = OmiConnector(
      device: _device(WearableDeviceType.omi),
      transport: transport,
    );
    transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
    await connector.connect();

    final timeSync = transport.writes.where(
      (w) => w.characteristic == WearableDeviceUuids.timeSyncWrite,
    );
    expect(timeSync, isNotEmpty, reason: 'connect() syncs the device clock');
    // Stand in for the unlucky second, whatever second the suite actually runs
    // in, by writing the value that collides.
    await transport.writeCharacteristic(
      WearableDeviceUuids.timeSyncService,
      WearableDeviceUuids.timeSyncWrite,
      <int>[RingProtocol.cmdAdvance, 0, 0, 0],
    );

    expect(
      transport.writes.where(
        (w) => w.value.isNotEmpty && w.value[0] == RingProtocol.cmdAdvance,
      ),
      isNotEmpty,
      reason:
          'the hazard is real: by first byte alone this write looks like one',
    );
    expect(
      transport.ringAdvances,
      isEmpty,
      reason:
          'a colliding first byte on another characteristic is not an advance',
    );

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
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
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
        advancesAtIngest = transport.ringAdvances.length;
      });

      expect(count, 1);
      expect(recordings.single.contentType, 'audio/wav');
      // WAV header (44 bytes) + decoded PCM16 (8 PCM8 samples -> 16 bytes).
      expect(recordings.single.bytes.length, 44 + 16);
      // No advance had been written at the moment of ingest...
      expect(advancesAtIngest, 0);
      // ...and exactly one advance, targeting nextSeq = 1, was written after.
      final advances = transport.ringAdvances.toList();
      expect(advances.length, 1);
      expect(advances.single.value.sublist(1), <int>[0, 0, 0, 0, 0, 0, 0, 1]);

      await connector.dispose();
    },
  );

  test(
    'Omi ring drain does not advance the cursor when ingest fails',
    () async {
      final transport = _FakeWearableTransport();
      final connector = OmiConnector(
        device: _device(WearableDeviceType.omi),
        transport: transport,
      );
      // PCM8 (codec id 1) so the drain decodes without a native Opus codec.
      transport.readValues[WearableDeviceUuids.omiAudioCodec] = <int>[1];
      transport.readValues[WearableDeviceUuids.omiStorageControl] = <int>[
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
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
              ...List<int>.filled(7, 0),
              0,
              ...List<int>.filled(7, 0),
              1,
              0,
              0,
              0,
              0,
              ...List<int>.filled(8, 0),
              0,
              0,
            ]);
          case RingProtocol.cmdRead:
            // Real firmware announces the transfer size first.
            emit(<int>[
              RingProtocol.notifyReadBegin,
              ...List<int>.filled(8, 0),
              0, 0, 0, 1, // packetCount = 1
            ]);
            emit(<int>[RingProtocol.notifyData, ...record]);
            emit(<int>[
              RingProtocol.notifyDone,
              0,
              ...List<int>.filled(7, 0),
              1,
            ]);
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
      final advances = transport.ringAdvances.toList();
      expect(advances, isEmpty);

      await connector.dispose();
    },
  );

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
      0,
      0,
      0,
      0,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
    ];
    await connector.connect();
    final frame = List<int>.filled(8, 0x40);
    final record = <int>[
      0,
      0,
      0,
      1,
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
            ...List<int>.filled(7, 0),
            0,
            ...List<int>.filled(7, 0),
            2,
            0,
            0,
            0,
            0,
            ...List<int>.filled(8, 0),
            0,
            0,
          ]);
        case RingProtocol.cmdRead:
          // Two packets announced...
          emit(<int>[
            RingProtocol.notifyReadBegin,
            ...List<int>.filled(8, 0),
            0,
            0,
            0,
            2,
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
      transport.ringAdvances,
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
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
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

    test('Memoket refuses it: control is shared with the drain', () async {
      final connector = MemoketConnector(
        device: _device(WearableDeviceType.memoket),
        transport: _FakeWearableTransport(),
      );
      expect(connector.supportsConcurrentCapture, isFalse);
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

void _bindMemoketReplies(
  _FakeWearableTransport transport, {
  List<int>? fileChunk,
  bool repeatListEntry = false,
  bool silentBattery = false,
}) {
  const filename = '20260905_222817_2.opus';
  const liveName = '20260905_222343_2.opus';
  void ctrl(List<int> value) => scheduleMicrotask(
    () => transport.emit(
      WearableDeviceUuids.memoketService,
      WearableDeviceUuids.memoketControlNotify,
      value,
    ),
  );
  transport.onWrite = (service, characteristic, value) {
    if (characteristic != WearableDeviceUuids.memoketControlWrite) return;
    if (value.isEmpty) return;
    switch (value.first) {
      case MemoketProtocol.opPing:
        ctrl(<int>[MemoketProtocol.opPing, 0x00]);
      case MemoketProtocol.opBattery:
        if (!silentBattery) {
          ctrl(<int>[MemoketProtocol.opBattery, 78, 0x02]);
        }
      case MemoketProtocol.opFirmware:
        ctrl(<int>[MemoketProtocol.opFirmware, ...ascii.encode('01.42.01.10')]);
      case MemoketProtocol.opTimeQuery:
        ctrl(<int>[MemoketProtocol.opTimeQuery, 0x68, 0, 0, 0, 0]);
      case MemoketProtocol.opSetTime:
        ctrl(<int>[MemoketProtocol.opSetTime, 0x01]);
      case MemoketProtocol.opStorage:
        ctrl(<int>[MemoketProtocol.opStorage, 0x0d, 0x00]);
      case MemoketProtocol.opRecordStart:
        ctrl(<int>[
          MemoketProtocol.opRecordStart,
          0x01,
          0x01,
          ...ascii.encode(liveName),
        ]);
      case MemoketProtocol.opRecordStop:
        ctrl(<int>[
          MemoketProtocol.opRecordStop,
          0x00,
          0x01,
          0x00,
          0x02,
          ...ascii.encode(liveName),
        ]);
      case MemoketProtocol.opListFiles:
        final entry = <int>[
          MemoketProtocol.opListFiles,
          0x01,
          0x00,
          0x00,
          0x0a,
          filename.length,
          ...ascii.encode(filename),
          0x00,
          0x00,
          0x01,
          0xe0,
        ];
        ctrl(entry);
        if (repeatListEntry) ctrl(entry);
        ctrl(<int>[MemoketProtocol.opListFiles, 0xff]);
      case MemoketProtocol.opDownload:
        scheduleMicrotask(() {
          transport.emit(
            WearableDeviceUuids.memoketService,
            WearableDeviceUuids.memoketFileNotify,
            fileChunk ?? List<int>.filled(480, 0xbc),
          );
          ctrl(<int>[MemoketProtocol.opDownload, 0x02]);
        });
      case MemoketProtocol.opDelete:
        ctrl(<int>[MemoketProtocol.opDelete, 0x01]);
    }
  };
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
  /// Ring-cursor advances, and nothing else.
  ///
  /// Matching on the first byte alone counted the time-sync write too: it
  /// carries the epoch as a little-endian uint32, so its first byte is the low
  /// byte of the current second and equals cmdAdvance (0x12) for one second in
  /// every 256. That turned these tests red on the clock rather than on the
  /// code -- twice in CI, 256 seconds apart.
  Iterable<_GattWrite> get ringAdvances => writes.where(
    (w) =>
        w.characteristic == WearableDeviceUuids.omiStorageData &&
        w.value.isNotEmpty &&
        w.value[0] == RingProtocol.cmdAdvance,
  );

  final Map<String, StreamController<List<int>>> _streams =
      <String, StreamController<List<int>>>{};
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final List<_GattWrite> writes = <_GattWrite>[];
  void Function(String service, String characteristic, List<int> value)?
  onWrite;
  void Function(String characteristic)? onSubscribe;
  Object? writeError;
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
  ) async {
    final stream = _streams
        .putIfAbsent(
          _key(serviceUuid, characteristicUuid),
          () => StreamController<List<int>>.broadcast(),
        )
        .stream;
    onSubscribe?.call(characteristicUuid);
    return stream;
  }

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
    final error = writeError;
    if (error != null) throw error;
    final copy = List<int>.from(value);
    writes.add(_GattWrite(serviceUuid, characteristicUuid, copy));
    onWrite?.call(serviceUuid, characteristicUuid, copy);
  }
}
