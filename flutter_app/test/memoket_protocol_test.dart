import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/memoket_protocol.dart';

/// Ground-truth frames from a Memoket Gem HCI snoop (firmware 01.42.01.10)
/// while the official app remotely started/stopped recording and later drained
/// an offline file. These bytes are what crossed the air.
Uint8List _hex(String s) => Uint8List.fromList(<int>[
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  test('remote start/stop commands match the official app', () {
    expect(MemoketProtocol.recordStart, <int>[0x01, 0x00, 0x00]);
    expect(MemoketProtocol.recordStop, <int>[0x02, 0x00]);
  });

  test('battery and firmware replies decode the captured payloads', () {
    expect(MemoketProtocol.batteryLevel(_hex('e14e02')), 78);
    expect(
      MemoketProtocol.firmwareVersion(_hex('e330312e34322e30312e3130')),
      '01.42.01.10',
    );
  });

  test('a list entry carries duration, name, and byte length', () {
    // 10-second offline file 20260905_222817_2.opus, 41760 bytes (87×480).
    final file = MemoketProtocol.parseListEntry(
      _hex('030100000a1632303236303930355f3232323831375f322e6f7075730000a320'),
    );
    expect(file, isNotNull);
    expect(file!.filename, '20260905_222817_2.opus');
    expect(file.durationSeconds, 10);
    expect(file.byteLength, 41760);
    expect(file.capturedAt, DateTime(2026, 9, 5, 22, 28, 17).toUtc());
    expect(MemoketProtocol.isListEnd(_hex('03ff')), isTrue);
  });

  test('two recordings from one day keep distinct capture times', () {
    const morning = MemoketStoredFile(
      filename: '20260905_222309_2.opus',
      durationSeconds: 28,
      byteLength: 113760,
    );
    const later = MemoketStoredFile(
      filename: '20260905_222343_2.opus',
      durationSeconds: 2,
      byteLength: 8160,
    );
    expect(morning.capturedAt, isNot(later.capturedAt));
    expect(
      later.capturedAt!.difference(morning.capturedAt!),
      const Duration(seconds: 34),
    );
  });

  test('live packets drop the 5-byte header; file chunks stay intact', () {
    final live = _hex('0000000003bc62133e788d88b7');
    expect(MemoketProtocol.liveOpusFrame(live), _hex('bc62133e788d88b7'));
    final stored = _hex('bc6a59d892db3aac');
    expect(MemoketProtocol.liveOpusFrame(stored), stored);
  });

  test('start/stop notifies expose the on-device filename', () {
    expect(
      MemoketProtocol.recordingFilename(
        _hex('01010132303236303930355f3232323330395f322e6f707573'),
      ),
      '20260905_222309_2.opus',
    );
    expect(
      MemoketProtocol.recordingFilename(
        _hex(
          '020001001c32303236303930355f3232323330395f322e6f7075730001bc60f3ce4e4b',
        ),
      ),
      '20260905_222309_2.opus',
    );
  });

  test('Ogg wrapping produces a container the import path can name', () {
    final frames = <Uint8List>[_hex('bc0011'), _hex('bc2233')];
    final ogg = MemoketProtocol.wrapOpusFramesAsOgg(frames);
    expect(ascii.decode(ogg.sublist(0, 4)), 'OggS');
    expect(ogg, containsAllInOrder(ascii.encode('OpusHead')));
    expect(ogg, containsAllInOrder(ascii.encode('OpusTags')));
    expect(ogg, containsAllInOrder(<int>[0xbc, 0x00, 0x11]));
    expect(ogg, containsAllInOrder(<int>[0xbc, 0x22, 0x33]));
    expect(MemoketProtocol.opusChannelCount(_hex('bc0011')), 2);
    final head = ascii.encode('OpusHead');
    var headAt = -1;
    for (var i = 0; i <= ogg.length - head.length; i += 1) {
      if (ogg.sublist(i, i + head.length).toString() == head.toString()) {
        headAt = i;
        break;
      }
    }
    expect(headAt, isNonNegative);
    expect(ogg[headAt + 8], 1);
    expect(ogg[headAt + 9], 2);
  });
}
