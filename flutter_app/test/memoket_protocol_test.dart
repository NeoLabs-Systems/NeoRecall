import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/memoket_protocol.dart';
import 'package:neorecall/src/devices/wearable_ingested_files.dart';

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
    final battery = MemoketProtocol.parseBattery(_hex('e14e02'));
    expect(battery, isNotNull);
    expect(battery!.percent, 78);
    expect(battery.status, 0x02);
    expect(battery.charging, isTrue);
    expect(MemoketProtocol.parseBattery(_hex('e14e00'))!.charging, isFalse);
    expect(MemoketProtocol.parseBattery(_hex('e1c8')), isNull);
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
    expect(file.listedDurationSeconds, 10);
    // Rounded up from the announced size, never below what the bytes hold.
    expect(file.durationSeconds, 11);
    expect(file.byteLength, 41760);
    expect(file.capturedAt, DateTime.utc(2026, 9, 5, 22, 28, 17));
    expect(file.capturedAt!.isUtc, isTrue);
    expect(MemoketProtocol.isListEnd(_hex('03ff')), isTrue);
  });

  test('a repeated list entry is kept once, preferring the larger size', () {
    const first = MemoketStoredFile(
      filename: '20260906_172959_2.opus',
      durationSeconds: 16,
      byteLength: 0,
    );
    const fuller = MemoketStoredFile(
      filename: '20260906_172959_2.opus',
      durationSeconds: 16,
      byteLength: 384000,
    );
    final files = MemoketProtocol.uniqueStoredFiles(<MemoketStoredFile>[
      first,
      fuller,
      first,
    ]);
    expect(files, hasLength(1));
    expect(files.single.byteLength, 384000);
    expect(
      MemoketProtocol.expectedAudioBytes(
        durationSeconds: 16,
        announcedBytes: 384000,
      ),
      384000,
    );
    expect(
      MemoketProtocol.expectedAudioBytes(
        durationSeconds: 16,
        announcedBytes: 0,
      ),
      64000,
    );
  });

  test('a long Gem file is given minutes to copy, not 90 seconds', () {
    expect(
      MemoketProtocol.downloadBudget(10 * 1000),
      const Duration(minutes: 2),
    );
    expect(
      MemoketProtocol.downloadBudget(20 * 1024 * 1024).inMinutes,
      greaterThanOrEqualTo(80),
    );
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

  test('a 480-byte notify is six 20 ms frames, not one', () {
    final chunk = Uint8List.fromList(<int>[
      for (var i = 0; i < 6; i += 1) ...<int>[
        0xbc,
        i,
        ...List<int>.filled(78, i),
      ],
    ]);
    expect(chunk.length, MemoketProtocol.packedNotifyBytes);
    final frames = MemoketProtocol.splitPackedOpusFrames(chunk);
    expect(frames, hasLength(6));
    expect(frames[0].length, 80);
    expect(frames[3].first, 0xbc);
    expect(frames[3][1], 3);
    expect(MemoketProtocol.opusFramesDurationMs(frames), 120);
    expect(_lastOggGranule(MemoketProtocol.wrapOpusFramesAsOgg(frames)), 5760);
    final live = Uint8List.fromList(<int>[0, 0, 0, 0, 7, ...chunk]);
    expect(
      MemoketProtocol.splitPackedOpusFrames(
        MemoketProtocol.liveOpusFrame(live)!,
      ),
      hasLength(6),
    );
    // Seq is one byte and wraps. The decoder must keep the packed payload.
    for (final seq in <int>[0, 1, 255]) {
      final wrapped = Uint8List.fromList(<int>[0, 0, 0, 0, seq, ...chunk]);
      expect(
        MemoketProtocol.liveOpusFrame(wrapped),
        chunk,
        reason: 'seq $seq is skipped, not a gate',
      );
      expect(
        MemoketProtocol.splitPackedOpusFrames(
          MemoketProtocol.liveOpusFrame(wrapped)!,
        ),
        hasLength(6),
      );
    }
    expect(
      MemoketProtocol.opusFramesDurationMs(
        MemoketProtocol.splitPackedOpusFrames(_hex('bc6a59d892db3aac')),
      ),
      20,
    );
    // After 255 the Gem may increment a wider header. That still carries the
    // same 480-byte packed payload; requiring `00 00 00 00` would look like
    // the live stream died at 30.72 s.
    for (final header in <List<int>>[
      <int>[0, 0, 0, 1, 0],
      <int>[1, 0, 0, 0, 0],
      <int>[0, 0, 0, 0, 1, 0],
    ]) {
      final rolled = Uint8List.fromList(<int>[...header, ...chunk]);
      expect(
        MemoketProtocol.liveOpusFrame(rolled),
        chunk,
        reason: 'header $header still yields the packed payload',
      );
      expect(MemoketProtocol.liveSeq(rolled), header.last);
      expect(
        MemoketProtocol.splitPackedOpusFrames(
          MemoketProtocol.liveOpusFrame(rolled)!,
        ),
        hasLength(6),
      );
    }
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
    // 0xbc is CELT wideband stereo, 20 ms. OpusHead rate is informational;
    // the granule must be 48 kHz samples (RFC 7845), 960 per frame.
    expect(MemoketProtocol.opusConfig(0xbc), 23);
    expect(MemoketProtocol.opusInputSampleRate(0xbc), 16000);
    expect(MemoketProtocol.opusPacketDurationUs(0xbc), 20000);
    expect(MemoketProtocol.opusGranuleIncrement(0xbc), 960);
    expect(MemoketProtocol.opusFramesDurationMs(frames), 40);
    expect(ogg[headAt + 12], 16000 & 0xff);
    expect(ogg[headAt + 13], (16000 >> 8) & 0xff);
    expect(_lastOggGranule(ogg), 1920);
  });

  test('Ogg wrapping packs many Opus frames onto each page', () {
    final frames = List<Uint8List>.generate(
      200,
      (_) => Uint8List.fromList(<int>[0xbc, ...List<int>.filled(79, 0)]),
    );
    final ogg = MemoketProtocol.wrapOpusFramesAsOgg(frames);
    const payload = 200 * 80;
    // One Ogg page per 80-byte frame is ~35% overhead. Packed pages stay
    // close to the Opus payload so a 1.5 h take fits the 32 MB ingest cap.
    expect(ogg.length, lessThan(payload + 2500));
    expect(ogg.length, greaterThan(payload));
    expect(_lastOggGranule(ogg), 200 * 960);
    expect(ogg, containsAllInOrder(<int>[0xbc, ...List<int>.filled(79, 0)]));
  });

  test('a take longer than 255 s keeps its real length', () {
    // 30 minutes (1800 s) of packed Opus: 0x000708 seconds, 7 200 000 bytes.
    // Read as a single byte the duration wrapped to 8 s, and a take the live
    // stream had barely touched then looked fully covered — and was deleted.
    final file = MemoketProtocol.parseListEntry(<int>[
      0x03,
      0x01,
      0x00,
      0x07,
      0x08,
      0x16,
      ...'20260908_121500_2.opus'.codeUnits,
      0x00,
      0x6d,
      0xdd,
      0x00,
    ]);
    expect(file, isNotNull);
    expect(file!.listedDurationSeconds, 1800);
    expect(file.durationSeconds, 1800);
    expect(
      WearableIngestedFiles.coversSpan(
        liveSeconds: 20,
        takeSeconds: file.durationSeconds,
      ),
      isFalse,
    );
  });
}

int _lastOggGranule(Uint8List ogg) {
  var last = 0;
  var offset = 0;
  while (offset + 27 <= ogg.length) {
    if (ascii.decode(ogg.sublist(offset, offset + 4), allowInvalid: true) !=
        'OggS') {
      offset += 1;
      continue;
    }
    last =
        ogg[offset + 6] |
        (ogg[offset + 7] << 8) |
        (ogg[offset + 8] << 16) |
        (ogg[offset + 9] << 24);
    final segments = ogg[offset + 26];
    var body = 0;
    for (var i = 0; i < segments && offset + 27 + i < ogg.length; i += 1) {
      body += ogg[offset + 27 + i];
    }
    offset += 27 + segments + body;
  }
  return last;
}
