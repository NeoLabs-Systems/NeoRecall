import 'dart:typed_data';

/// Omi on-board ring-buffer storage protocol (firmware 3.0.20+), ported verbatim
/// from the pinned reference (`services/devices/ring_protocol.dart`). The pendant
/// records audio to a flash ring buffer while the phone is away; this decodes the
/// control/notify framing so [OmiConnector] can drain it after reconnect.
class RingProtocol {
  static const int recordSize = 444;
  static const int timestampBytes = 4;
  static const int audioPayloadBytes = recordSize - timestampBytes;

  static const int notifyAck = 0x01;
  static const int notifyInfo = 0x02;
  static const int notifyData = 0x03;
  static const int notifyDone = 0x04;
  static const int notifyReadBegin = 0x05;

  static const int cmdInfo = 0x10;
  static const int cmdRead = 0x11;
  static const int cmdAdvance = 0x12;
  static const int cmdClear = 0x13;
  static const int cmdStop = 0x03;

  /// Reads a big-endian unsigned 64-bit sequence number as two 32-bit halves.
  ///
  /// `ByteData.getUint64` is **unimplemented on dart2js** — JavaScript has no
  /// 64-bit integer type, so it throws UnsupportedError in a browser build and
  /// would take the entire ring protocol down on web while working natively.
  /// Ring cursors are packet counters, far below 2^53, so composing them from
  /// two 32-bit reads is exact on every platform.
  static int _readUint64BE(ByteData data, int offset) =>
      data.getUint32(offset, Endian.big) * 0x100000000 +
      data.getUint32(offset + 4, Endian.big);

  /// Writes a big-endian unsigned 64-bit sequence number as two 32-bit halves,
  /// for the same reason as [_readUint64BE] (`setUint64` throws on dart2js).
  static void _writeUint64BE(ByteData data, int offset, int value) {
    data.setUint32(offset, value ~/ 0x100000000, Endian.big);
    data.setUint32(offset + 4, value % 0x100000000, Endian.big);
  }

  static RingStatus? parseStatus(List<int> value) {
    if (value.length < 16) return null;
    final bd = ByteData.sublistView(Uint8List.fromList(value));
    return RingStatus(
      usedBytes: bd.getUint32(0, Endian.little),
      unreadPackets: bd.getUint32(4, Endian.little),
      freeBytes: bd.getUint32(8, Endian.little),
      rtcValid: bd.getUint32(12, Endian.little),
    );
  }

  /// Parse a NOTIFY_INFO (0x02) notification into read/write sequence cursors.
  static RingInfo? parseInfoNotification(List<int> value) {
    if (value.isEmpty || value[0] != notifyInfo || value.length < 31) {
      return null;
    }
    final bd = ByteData.sublistView(Uint8List.fromList(value));
    return RingInfo(
      readSeq: _readUint64BE(bd, 1),
      writeSeq: _readUint64BE(bd, 9),
      capacityPackets: bd.getUint32(17, Endian.big),
      droppedPackets: _readUint64BE(bd, 21),
      packetSize: bd.getUint16(29, Endian.big),
    );
  }

  static DoneNotification? parseDoneNotification(List<int> value) {
    if (value.isEmpty || value[0] != notifyDone || value.length < 10) {
      return null;
    }
    final bd = ByteData.sublistView(Uint8List.fromList(value));
    return DoneNotification(
      status: bd.getUint8(1),
      nextSeq: _readUint64BE(bd, 2),
    );
  }

  static ReadBeginNotification? parseReadBeginNotification(List<int> value) {
    if (value.isEmpty || value[0] != notifyReadBegin || value.length < 13) {
      return null;
    }
    final bd = ByteData.sublistView(Uint8List.fromList(value));
    return ReadBeginNotification(
      transferStartSeq: _readUint64BE(bd, 1),
      packetCount: bd.getUint32(9, Endian.big),
    );
  }

  /// CMD_RING_READ payload: [0x11][start_seq:u64 BE](+optional [count:u32 BE]).
  static Uint8List encodeReadCommand(int startSeq, {int? packetCount}) {
    final hasCount = packetCount != null && packetCount > 0;
    final cmd = ByteData(hasCount ? 13 : 9);
    cmd.setUint8(0, cmdRead);
    _writeUint64BE(cmd, 1, startSeq);
    if (hasCount) cmd.setUint32(9, packetCount, Endian.big);
    return cmd.buffer.asUint8List();
  }

  /// CMD_RING_ADVANCE payload: [0x12][new_read_seq:u64 BE].
  static Uint8List encodeAdvanceCommand(int newReadSeq) {
    final cmd = ByteData(9);
    cmd.setUint8(0, cmdAdvance);
    _writeUint64BE(cmd, 1, newReadSeq);
    return cmd.buffer.asUint8List();
  }

  static int readRecordTimestamp(List<int> record) =>
      (record[0] << 24) | (record[1] << 16) | (record[2] << 8) | record[3];

  /// Parse the 440-byte audio payload of a ring record into opus frames:
  /// `[size:1][frame:size]…` with 0 bytes as padding. The `>=` boundary matches
  /// the firmware's overflow rule (a trailing size byte without its frame at the
  /// block boundary; bytes after it are stale and must not be parsed).
  static List<List<int>> parseAudioPayload(List<int> audio) {
    final frames = <List<int>>[];
    var offset = 0;
    while (offset < audio.length - 1) {
      final size = audio[offset];
      if (size == 0) {
        offset += 1;
        continue;
      }
      if (offset + 1 + size >= audio.length) break;
      frames.add(audio.sublist(offset + 1, offset + 1 + size));
      offset += size + 1;
    }
    return frames;
  }
}

class RingStatus {
  const RingStatus({
    required this.usedBytes,
    required this.unreadPackets,
    required this.freeBytes,
    required this.rtcValid,
  });
  final int usedBytes;
  final int unreadPackets;
  final int freeBytes;
  final int rtcValid;
}

class RingInfo {
  const RingInfo({
    required this.readSeq,
    required this.writeSeq,
    required this.capacityPackets,
    required this.droppedPackets,
    required this.packetSize,
  });
  final int readSeq;
  final int writeSeq;
  final int capacityPackets;
  final int droppedPackets;
  final int packetSize;
}

class DoneNotification {
  const DoneNotification({required this.status, required this.nextSeq});
  final int status;
  final int nextSeq;
  bool get isOk => status == 0;
}

class ReadBeginNotification {
  const ReadBeginNotification({
    required this.transferStartSeq,
    required this.packetCount,
  });
  final int transferStartSeq;
  final int packetCount;
}

/// Reassembles unaligned NOTIFY_DATA byte chunks into 444-byte ring records.
class RingRecordReassembler {
  final List<int> _buffer = <int>[];

  void append(List<int> bytes) => _buffer.addAll(bytes);

  List<Uint8List> drainRecords() {
    final out = <Uint8List>[];
    while (_buffer.length >= RingProtocol.recordSize) {
      out.add(Uint8List.fromList(_buffer.sublist(0, RingProtocol.recordSize)));
      _buffer.removeRange(0, RingProtocol.recordSize);
    }
    return out;
  }

  int get pendingBytes => _buffer.length;
}
