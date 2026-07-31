import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/ring_protocol.dart';

/// `ByteData.getUint64`/`setUint64` are unimplemented on dart2js — JavaScript has
/// no 64-bit integers, so they throw UnsupportedError in a browser build. The ring
/// protocol reads and writes 64-bit sequence numbers everywhere, so it must build
/// them from 32-bit halves instead. These tests pin the byte-level results (which
/// a native run verifies) and are the contract the web build depends on.
void main() {
  Uint8List hex(String s) => Uint8List.fromList(<int>[
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);

  test('64-bit sequence numbers decode without 64-bit ByteData accessors', () {
    final info = RingProtocol.parseInfoNotification(
      hex('020000000000000000000000000000015e0010f1b8000000000000000001bc'),
    );
    expect(info!.readSeq, 0);
    expect(info.writeSeq, 350);
    expect(info.droppedPackets, 0);

    final done = RingProtocol.parseDoneNotification(hex('0400000000000000015e'));
    expect(done!.nextSeq, 350);

    final begin = RingProtocol.parseReadBeginNotification(
      hex('0500000000000000000000015e'),
    );
    expect(begin!.transferStartSeq, 0);
  });

  test('64-bit sequence numbers encode without 64-bit ByteData accessors', () {
    expect(RingProtocol.encodeReadCommand(0), hex('110000000000000000'));
    expect(RingProtocol.encodeAdvanceCommand(350), hex('12000000000000015e'));
  });

  test('a sequence number above 32 bits still round-trips', () {
    // The ring runs for a long time; the cursor must survive crossing 2^32.
    const big = 0x1_2345_6789; // 4886718345
    final encoded = RingProtocol.encodeAdvanceCommand(big);
    expect(encoded.sublist(1), hex('0000000123456789'));

    final done = RingProtocol.parseDoneNotification(
      Uint8List.fromList(<int>[0x04, 0x00, ...encoded.sublist(1)]),
    );
    expect(done!.nextSeq, big);
  });

  test('a read command with an explicit packet count keeps its layout', () {
    final cmd = RingProtocol.encodeReadCommand(350, packetCount: 12);
    expect(cmd.length, 13);
    expect(cmd.sublist(0, 9), hex('11000000000000015e'));
    expect(cmd.sublist(9), hex('0000000c'));
  });
}
