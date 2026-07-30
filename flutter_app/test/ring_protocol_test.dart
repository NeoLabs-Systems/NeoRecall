import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/ring_protocol.dart';

void main() {
  test('encodeReadCommand builds [0x11][start_seq u64 BE]', () {
    final cmd = RingProtocol.encodeReadCommand(0x0102030405060708);
    expect(cmd.length, 9);
    expect(cmd[0], RingProtocol.cmdRead);
    expect(cmd.sublist(1), <int>[1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('encodeReadCommand appends [count u32 BE] when provided', () {
    final cmd = RingProtocol.encodeReadCommand(1, packetCount: 0x01020304);
    expect(cmd.length, 13);
    expect(cmd.sublist(9), <int>[1, 2, 3, 4]);
  });

  test('encodeAdvanceCommand builds [0x12][new_read_seq u64 BE]', () {
    final cmd = RingProtocol.encodeAdvanceCommand(0x0A);
    expect(cmd.length, 9);
    expect(cmd[0], RingProtocol.cmdAdvance);
    expect(cmd[8], 0x0A);
  });

  test('parseInfoNotification reads read/write sequence cursors', () {
    final bytes = <int>[
      RingProtocol.notifyInfo,
      ...List<int>.filled(7, 0), 5, // readSeq = 5
      ...List<int>.filled(7, 0), 9, // writeSeq = 9
      0, 0, 0, 0, // capacity
      ...List<int>.filled(8, 0), // dropped
      0, 0, // packet size
    ];
    final info = RingProtocol.parseInfoNotification(bytes)!;
    expect(info.readSeq, 5);
    expect(info.writeSeq, 9);
  });

  test('parseInfoNotification rejects wrong opcode or short payload', () {
    expect(RingProtocol.parseInfoNotification(<int>[0x03, 1, 2]), isNull);
    expect(RingProtocol.parseInfoNotification(<int>[RingProtocol.notifyInfo]), isNull);
  });

  test('parseAudioPayload extracts [size][frame] opus frames and skips padding', () {
    final payload = <int>[0, 3, 0xb8, 0x11, 0x22, 2, 0x78, 0x33, 0, 0];
    final frames = RingProtocol.parseAudioPayload(payload);
    expect(frames.length, 2);
    expect(frames[0], <int>[0xb8, 0x11, 0x22]);
    expect(frames[1], <int>[0x78, 0x33]);
  });

  test('RingRecordReassembler yields whole 444-byte records only', () {
    final reassembler = RingRecordReassembler();
    reassembler.append(List<int>.filled(400, 1));
    expect(reassembler.drainRecords(), isEmpty);
    reassembler.append(List<int>.filled(50, 2));
    final records = reassembler.drainRecords();
    expect(records.length, 1);
    expect(records.first.length, RingProtocol.recordSize);
    expect(reassembler.pendingBytes, 6);
  });
}
