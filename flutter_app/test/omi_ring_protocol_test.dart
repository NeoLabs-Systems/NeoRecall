import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/ring_protocol.dart';

/// Ground-truth bytes captured from a real Omi pendant (BLE MAC
/// c8:a5:cd:31:5d:4a) via a btsnoop HCI log while the official Omi app drained
/// its on-board storage ring. Every command and notification below is exactly
/// what crossed the air, so these tests pin our decoder to real firmware
/// behaviour: an earlier build silently synced nothing, and only a byte-for-byte
/// comparison against a real transfer can catch that class of regression.
Uint8List _hex(String s) => Uint8List.fromList(<int>[
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  group('Omi ring protocol vs. real hardware capture', () {
    test('status read: an empty ring reports no unread packets', () {
      // 30295782 read while nothing was stored.
      final status = RingProtocol.parseStatus(
        _hex('0000000000000000203b631d01000000'),
      );
      expect(status, isNotNull);
      expect(status!.usedBytes, 0);
      expect(status.unreadPackets, 0);
    });

    test('status read: a ring with data reports the unread packet count', () {
      // 30295782 read after ~30s was recorded to flash.
      final status = RingProtocol.parseStatus(
        _hex('40a00100f0000000e09a611d01000000'),
      );
      expect(status, isNotNull);
      expect(status!.usedBytes, 106560);
      expect(status.unreadPackets, 240);
      expect(status.rtcValid, 1);
    });

    test('NOTIFY_INFO decodes the read/write cursors and packet size', () {
      final info = RingProtocol.parseInfoNotification(
        _hex('020000000000000000000000000000015e0010f1b8000000000000000001bc'),
      );
      expect(info, isNotNull);
      expect(info!.readSeq, 0);
      // 350 written, 0 read -> the whole 350-packet range is unread, which is
      // exactly what READ_BEGIN (packetCount) and DONE (nextSeq) confirm below.
      expect(info.writeSeq, 350);
      expect(info.packetSize, 444);
      // The drain only proceeds when there is unread data to fetch.
      expect(info.writeSeq > info.readSeq, isTrue);
    });

    test('NOTIFY_READ_BEGIN reports the transfer packet count', () {
      final begin = RingProtocol.parseReadBeginNotification(
        _hex('0500000000000000000000015e'),
      );
      expect(begin, isNotNull);
      expect(begin!.transferStartSeq, 0);
      expect(begin.packetCount, 350);
    });

    test('NOTIFY_DONE decodes an OK status and the next cursor', () {
      final done = RingProtocol.parseDoneNotification(
        _hex('0400000000000000015e'),
      );
      expect(done, isNotNull);
      expect(done!.isOk, isTrue);
      expect(done.nextSeq, 350);
    });

    test('CMD_READ from seq 0 matches the bytes the official app sent', () {
      expect(RingProtocol.encodeReadCommand(0), _hex('110000000000000000'));
    });

    test('CMD_ADVANCE to the done cursor matches the official app', () {
      // After DONE reported nextSeq=350 the app advanced the read cursor to it.
      expect(RingProtocol.encodeAdvanceCommand(350), _hex('12000000000000015e'));
    });

    test('a real 444-byte ring record decodes into opus frames', () {
      final record = _hex(
        '6a6c887863b87f71a63a4936ba32d745a35fe69ee052fa8be4afc84b411b341f'
        'b6c578cc36c228031760a0ca6ebade146db7cdb7ff2f5c9a4ae8d11e5266b620'
        '87d5e2f4e7a66202ed126fb48ea1d62f45a8340056ad882fc5b5cb3b822ced46'
        'f40f126ddb3a60a24ab844200ef099c680054dcbf89e7dba6e0826aedfa17ad3'
        '4756bcc22c9a7897cdf3176df4aa00b402c6f4e36130f4111b1b6730a8a46774'
        'd84dff04834d3ddba5ec98c69d37fce2a253de5cb87395d57c7c4892fb6f1035'
        '2fd1c12279a6974bdb417d1e4b5cd5e313c955e510306a58a5466ac730f00bab'
        'e8d0d7bd227f41d06b10d8253ab1f6d14f68fe346f60d8f430cb17f03e1a1352'
        '4b7b55cb19258057e396a3f426cfeaf082b87df80b8a45eb2d753b140bc89c27'
        '0b1b0b78d8dc651259cf97a85f0787c0b38a4b827727cac8a561e5e9e9ee2df6'
        '02eab3f357fa8b7bf215341d112ddda862bad0e3f932207fe149802f3cb1afa7'
        'c12e6cd9c9e62e65775ac811f57f283df505620e8f53e599e2a76a50a1dbd370'
        '643a1fa1f9acc0fcd14758582f99a770c5544e6153aaa58b3bab104b32ce9344'
        '7a82311d732af241c19e75834744943082488041f2db3d6883e44e00',
      );
      expect(record.length, RingProtocol.recordSize);
      // 4-byte RTC timestamp prefix (a valid 2026 epoch second).
      expect(RingProtocol.readRecordTimestamp(record), 0x6a6c8878);
      final audio = record.sublist(RingProtocol.timestampBytes);
      final frames = RingProtocol.parseAudioPayload(audio);
      expect(frames.map((f) => f.length).toList(), <int>[99, 74, 92, 130]);
    });

    test('reassembler realigns an unaligned notify stream into records', () {
      // On the wire each NOTIFY_DATA carried 494 payload bytes (after the 0x03
      // type byte), which does not divide the 444-byte record size, so records
      // straddle notify boundaries and the reassembler must realign them.
      final reassembler = RingRecordReassembler();
      reassembler.append(List<int>.filled(494, 1));
      reassembler.append(List<int>.filled(494, 2));
      final records = reassembler.drainRecords();
      expect(records.length, 2); // floor(988 / 444)
      expect(records.first.length, RingProtocol.recordSize);
      expect(reassembler.pendingBytes, 988 - 2 * RingProtocol.recordSize);
    });
  });
}
