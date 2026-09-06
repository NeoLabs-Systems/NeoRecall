import 'dart:convert';
import 'dart:typed_data';

import 'wearable_capture_time.dart';

/// Wire frames captured from a Memoket Gem (firmware 01.42.01.10) while the
/// official app remotely started/stopped recording and later drained a file
/// that was recorded offline. Opcodes and layouts below are exactly what
/// crossed the air.
class MemoketProtocol {
  static const int opPing = 0x00;
  static const int opRecordStart = 0x01;
  static const int opRecordStop = 0x02;
  static const int opListFiles = 0x03;
  static const int opDownload = 0x04;
  static const int opDelete = 0x05;
  static const int opBattery = 0xe1;
  static const int opFirmware = 0xe3;
  static const int opSetTime = 0xe5;
  static const int opStorage = 0xe8;
  static const int opTimeQuery = 0xff;

  /// Phone → Gem: start on-device recording (and the live Opus stream).
  static final Uint8List recordStart = Uint8List.fromList(const <int>[
    opRecordStart,
    0x00,
    0x00,
  ]);

  /// Phone → Gem: stop the current recording.
  static final Uint8List recordStop = Uint8List.fromList(const <int>[
    opRecordStop,
    0x00,
  ]);

  static final Uint8List ping = Uint8List.fromList(const <int>[opPing]);

  /// Phone → Gem on the control write characteristic. Reply is
  /// `e1 <percent> <status>` (`e14e02` = 78%, status 0x02 charging/full).
  /// The Gem also exposes standard Battery (180F / 2A19); prefer that read
  /// when the characteristic is present — it does not need a control write.
  static final Uint8List batteryQuery = Uint8List.fromList(const <int>[
    opBattery,
  ]);
  static final Uint8List firmwareQuery = Uint8List.fromList(const <int>[
    opFirmware,
    0x01,
  ]);
  static final Uint8List timeQuery = Uint8List.fromList(const <int>[
    opTimeQuery,
    0x68,
  ]);
  static final Uint8List storageQuery = Uint8List.fromList(const <int>[
    opStorage,
  ]);
  static final Uint8List listFiles = Uint8List.fromList(const <int>[
    opListFiles,
  ]);

  static Uint8List setTime(DateTime when) {
    final unix = when.toUtc().millisecondsSinceEpoch ~/ 1000;
    return Uint8List.fromList(<int>[
      opSetTime,
      (unix >> 24) & 0xff,
      (unix >> 16) & 0xff,
      (unix >> 8) & 0xff,
      unix & 0xff,
    ]);
  }

  static Uint8List fileCommand(int opcode, String filename) {
    final name = ascii.encode(filename);
    return Uint8List.fromList(<int>[opcode, name.length, ...name]);
  }

  /// Live notify packets are `00 00 00 00 <seq> <opus…>` (HCI: 485 bytes
  /// every 120 ms). Stored-file notifies are the same 480-byte Opus payload
  /// without that header. Both pack six 20 ms CELT frames, not one.
  static const int packedNotifyBytes = 480;
  static const int packedFrameBytes = 80;
  static const int packedFramesPerNotify = 6;

  /// Live notify packets are `00 00 00 00 <seq> <opus-payload>`; stored-file
  /// chunks are the 480-byte payload alone (they start with TOC `0xbc`).
  static Uint8List? liveOpusFrame(List<int> packet) {
    if (packet.length >= 6 &&
        packet[0] == 0 &&
        packet[1] == 0 &&
        packet[2] == 0 &&
        packet[3] == 0) {
      return Uint8List.fromList(packet.sublist(5));
    }
    if (packet.isNotEmpty && packet.first == 0xbc) {
      return Uint8List.fromList(packet);
    }
    return null;
  }

  /// One BLE notify is 120 ms of audio: six 20 ms frames of [packedFrameBytes].
  /// Treating the 480-byte blob as a single TOC `0xbc` packet made a 10 s take
  /// decode as 1.8 s and play about 6× too fast.
  static List<Uint8List> splitPackedOpusFrames(List<int> payload) {
    if (payload.isEmpty) return const <Uint8List>[];
    if (payload.length >= packedFrameBytes * 2 &&
        payload.length % packedFrameBytes == 0) {
      final count = payload.length ~/ packedFrameBytes;
      final frames = <Uint8List>[];
      final expectedConfig = opusConfig(payload.first);
      for (var i = 0; i < count; i += 1) {
        final slice = Uint8List.fromList(
          payload.sublist(i * packedFrameBytes, (i + 1) * packedFrameBytes),
        );
        if (opusConfig(slice.first) != expectedConfig) {
          return <Uint8List>[Uint8List.fromList(payload)];
        }
        frames.add(slice);
      }
      return frames;
    }
    return <Uint8List>[Uint8List.fromList(payload)];
  }

  static int? batteryLevel(List<int> frame) => parseBattery(frame)?.percent;

  /// Vendor battery notify/reply captured on the control channel.
  /// Status 0x01 = charging, 0x02 = charging or full (HCI: `e14e02`).
  static MemoketBattery? parseBattery(List<int> frame) {
    if (frame.length < 2 || frame.first != opBattery) return null;
    final percent = frame[1];
    if (percent > 100) return null;
    final status = frame.length > 2 ? frame[2] : null;
    return MemoketBattery(percent: percent, status: status);
  }

  static String? firmwareVersion(List<int> frame) {
    if (frame.length < 2 || frame.first != opFirmware) return null;
    return ascii.decode(frame.sublist(1), allowInvalid: true).trim();
  }

  /// `03 ff` ends a listing. `03 01 00 00 <dur8> <namelen> <name> <size32be>`
  /// is one stored file. A notify that is only `03 ff` is the terminator.
  static bool isListEnd(List<int> frame) =>
      frame.length >= 2 && frame[0] == opListFiles && frame[1] == 0xff;

  static MemoketStoredFile? parseListEntry(List<int> frame) {
    if (frame.length < 10 || frame.first != opListFiles || frame[1] == 0xff) {
      return null;
    }
    final duration = frame[4];
    final nameLen = frame[5];
    if (nameLen <= 0 || frame.length < 6 + nameLen + 4) return null;
    final name = ascii.decode(
      frame.sublist(6, 6 + nameLen),
      allowInvalid: true,
    );
    if (name.isEmpty) return null;
    final sizeOff = 6 + nameLen;
    final size =
        (frame[sizeOff] << 24) |
        (frame[sizeOff + 1] << 16) |
        (frame[sizeOff + 2] << 8) |
        frame[sizeOff + 3];
    return MemoketStoredFile(
      filename: name,
      durationSeconds: duration,
      byteLength: size,
    );
  }

  /// The Gem sometimes repeats the same list entry. Keep the fattest copy.
  static List<MemoketStoredFile> uniqueStoredFiles(
    Iterable<MemoketStoredFile> files,
  ) {
    final byId = <String, MemoketStoredFile>{};
    for (final file in files) {
      final existing = byId[file.id];
      if (existing == null ||
          file.byteLength > existing.byteLength ||
          (file.byteLength == existing.byteLength &&
              file.durationSeconds > existing.durationSeconds)) {
        byId[file.id] = file;
      }
    }
    return byId.values.toList(growable: false);
  }

  /// How many payload bytes a listed take should still produce.
  ///
  /// Prefer the device's announced size. Duration is only a floor when the
  /// size is missing — firmware duration is not a 20 ms frame count.
  static int expectedAudioBytes({
    required int durationSeconds,
    required int announcedBytes,
  }) {
    if (announcedBytes > 0) return announcedBytes;
    if (durationSeconds <= 0) return 0;
    return durationSeconds * 4000;
  }

  static String? recordingFilename(List<int> frame) {
    if (frame.isEmpty ||
        (frame.first != opRecordStart && frame.first != opRecordStop)) {
      return null;
    }
    final match = RegExp(
      r'(\d{8}_\d{6}_\d+\.opus)',
    ).firstMatch(ascii.decode(frame, allowInvalid: true));
    return match?.group(1);
  }

  static bool isDownloadComplete(List<int> frame) =>
      frame.length >= 2 && frame[0] == opDownload && frame[1] == 0x02;

  static bool isDeleteAck(List<int> frame) =>
      frame.length >= 2 && frame[0] == opDelete && frame[1] == 0x01;

  /// Concatenated raw Opus frames are not a file. The import pipeline needs a
  /// container; Ogg Opus is what the server already accepts as `audio/ogg`.
  /// Opus TOC bit 2 is the stereo flag (RFC 6716). Captured Gem frames are
  /// `0xbc` — stereo CELT wideband, 20 ms.
  static int opusChannelCount(List<int> frame) {
    if (frame.isEmpty) return 1;
    return ((frame.first >> 2) & 1) == 1 ? 2 : 1;
  }

  /// RFC 6716 configuration number (TOC bits 7–3).
  static int opusConfig(int toc) => (toc >> 3) & 31;

  /// How many Opus frames one packet contains (TOC code, bits 1–0).
  static int opusFrameCount(int toc) {
    switch (toc & 3) {
      case 1:
      case 2:
        return 2;
      default:
        return 1;
    }
  }

  /// Duration of one coded frame inside the packet, in microseconds.
  static int opusFrameDurationUs(int toc) {
    final config = opusConfig(toc);
    if (config <= 11) {
      return const <int>[10000, 20000, 40000, 60000][config % 4];
    }
    if (config <= 15) return config.isEven ? 10000 : 20000;
    return const <int>[2500, 5000, 10000, 20000][(config - 16) % 4];
  }

  static int opusPacketDurationUs(int toc) =>
      opusFrameDurationUs(toc) * opusFrameCount(toc);

  /// Informational input rate for OpusHead. The decoder still works at 48 kHz;
  /// this is the bandwidth the TOC advertised (RFC 6716 Table 2).
  static int opusInputSampleRate(int toc) {
    final config = opusConfig(toc);
    if (config <= 3) return 8000;
    if (config <= 7) return 12000;
    if (config <= 11) return 16000;
    if (config <= 13) return 24000;
    if (config <= 15) return 48000;
    if (config <= 19) return 8000;
    if (config <= 23) return 16000;
    if (config <= 27) return 24000;
    return 48000;
  }

  /// RFC 7845: an Ogg Opus granule is PCM samples at 48 kHz, not the
  /// input-rate sample count. Labeling a 20 ms `0xbc` frame as 1920 samples
  /// at 16 kHz made a 1.6 s take look like 9 s and stretched Whisper's input.
  static int opusGranuleIncrement(int toc) =>
      (48000 * opusPacketDurationUs(toc)) ~/ 1000000;

  static int opusFramesDurationMs(Iterable<List<int>> frames) {
    var microseconds = 0;
    for (final frame in frames) {
      if (frame.isEmpty) continue;
      microseconds += opusPacketDurationUs(frame.first);
    }
    return (microseconds + 500) ~/ 1000;
  }

  static Uint8List wrapOpusFramesAsOgg(List<Uint8List> frames) {
    final serial = 0x4d4b4731; // 'MKG1'
    final toc = frames.isEmpty ? 0 : frames.first.first;
    final channels = frames.isEmpty ? 1 : opusChannelCount(frames.first);
    final sampleRate = frames.isEmpty ? 16000 : opusInputSampleRate(toc);
    final pages = <Uint8List>[];
    pages.add(
      _oggPage(
        headerType: 0x02,
        granule: 0,
        serial: serial,
        sequence: 0,
        body: _opusHead(sampleRate, channels),
      ),
    );
    pages.add(
      _oggPage(
        headerType: 0x00,
        granule: 0,
        serial: serial,
        sequence: 1,
        body: _opusTags(),
      ),
    );
    var granule = 0;
    for (var i = 0; i < frames.length; i += 1) {
      final frame = frames[i];
      if (frame.isNotEmpty) granule += opusGranuleIncrement(frame.first);
      pages.add(
        _oggPage(
          headerType: i == frames.length - 1 ? 0x04 : 0x00,
          granule: granule,
          serial: serial,
          sequence: i + 2,
          body: frame,
        ),
      );
    }
    final out = BytesBuilder();
    for (final page in pages) {
      out.add(page);
    }
    return out.toBytes();
  }

  static Uint8List _opusHead(int sampleRate, int channels) {
    final out = BytesBuilder()
      ..add(ascii.encode('OpusHead'))
      ..add(<int>[
        1, // version
        channels.clamp(1, 2),
        0, 0, // pre-skip
        sampleRate & 0xff,
        (sampleRate >> 8) & 0xff,
        (sampleRate >> 16) & 0xff,
        (sampleRate >> 24) & 0xff,
        0, 0, // output gain
        0, // mapping family
      ]);
    return out.toBytes();
  }

  static Uint8List _opusTags() {
    const vendor = 'NeoRecall';
    final out = BytesBuilder()
      ..add(ascii.encode('OpusTags'))
      ..add(<int>[
        vendor.length,
        0,
        0,
        0,
        ...ascii.encode(vendor),
        0,
        0,
        0,
        0, // user comment count
      ]);
    return out.toBytes();
  }

  static Uint8List _oggPage({
    required int headerType,
    required int granule,
    required int serial,
    required int sequence,
    required List<int> body,
  }) {
    final lacing = <int>[];
    var remaining = body.length;
    while (remaining >= 255) {
      lacing.add(255);
      remaining -= 255;
    }
    lacing.add(remaining);
    final header = BytesBuilder()
      ..add(ascii.encode('OggS'))
      ..add(<int>[0, headerType])
      ..add(_u64le(granule))
      ..add(_u32le(serial))
      ..add(_u32le(sequence))
      ..add(const <int>[0, 0, 0, 0]) // CRC placeholder
      ..add(<int>[lacing.length, ...lacing]);
    final page = BytesBuilder()
      ..add(header.toBytes())
      ..add(body);
    final bytes = page.toBytes();
    final crc = _oggCrc(bytes);
    bytes[22] = crc & 0xff;
    bytes[23] = (crc >> 8) & 0xff;
    bytes[24] = (crc >> 16) & 0xff;
    bytes[25] = (crc >> 24) & 0xff;
    return bytes;
  }

  static List<int> _u32le(int value) => <int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  static List<int> _u64le(int value) => <int>[..._u32le(value), 0, 0, 0, 0];

  static int _oggCrc(List<int> data) {
    var crc = 0;
    final table = _crcTable;
    for (final byte in data) {
      crc = table[((crc >> 24) ^ byte) & 0xff] ^ ((crc << 8) & 0xffffffff);
    }
    return crc;
  }

  static final List<int> _crcTable = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i += 1) {
      var r = i << 24;
      for (var bit = 0; bit < 8; bit += 1) {
        r = (r & 0x80000000) != 0
            ? ((r << 1) ^ 0x04c11db7) & 0xffffffff
            : (r << 1) & 0xffffffff;
      }
      table[i] = r;
    }
    return table;
  }
}

class MemoketBattery {
  const MemoketBattery({required this.percent, this.status});

  final int percent;
  final int? status;

  bool get charging => status == 0x01 || status == 0x02;
}

class MemoketStoredFile {
  const MemoketStoredFile({
    required this.filename,
    required this.durationSeconds,
    required this.byteLength,
  });

  /// Device filename, e.g. `20260905_222817_2.opus`.
  final String filename;
  final int durationSeconds;
  final int byteLength;

  String get id => filename;
  String get contentType => 'audio/ogg';
  String get importFilename =>
      'memoket-${filename.replaceFirst(RegExp(r'\.opus$'), '.ogg')}';

  /// The handshake sets the Gem with unix UTC; the filename is that clock.
  DateTime? get capturedAt => WearableCaptureTime.parseUtcStamp(filename);
}
