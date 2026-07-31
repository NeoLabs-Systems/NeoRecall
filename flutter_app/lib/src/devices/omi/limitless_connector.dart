import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';
import 'offline_audio.dart';
import 'offline_sync.dart';

/// Capture-critical Limitless Pendant protocol.
///
/// Commands and notifications use protobuf wire encoding inside a fragmented
/// BLE wrapper. This implementation follows the pinned Omi protocol source;
/// it does not use guessed one-byte start/stop commands. Offline recordings held
/// in the pendant's flash are pulled via batch mode (see [drainStoredAudio]).
class LimitlessConnector extends WearableConnector with WearableOfflineSync {
  LimitlessConnector({required super.device, required super.transport});

  static const int _maximumFragmentsPerMessage = 128;
  static const int _maximumPendingMessages = 256;
  static const int _minimumOpusFrameBytes = 10;
  static const int _maximumOpusFrameBytes = 200;
  static const Duration _gattReadyDelay = Duration(seconds: 1);
  // Offline drain: end the batch dump after this long with no new flash page,
  // and never wait longer than the overall cap.
  static const Duration _drainQuietGap = Duration(seconds: 3);
  static const Duration _drainOverallTimeout = Duration(minutes: 8);
  static const Set<int> _validOpusToc = <int>{
    0xb8,
    0x78,
    0xf8,
    0xb0,
    0x70,
    0xf0,
  };

  final Map<int, Map<int, List<int>>> _fragments = <int, Map<int, List<int>>>{};
  int _messageIndex = 0;
  int _requestId = 0;

  // Offline batch-drain state. While _drainSink is non-null, reassembled
  // payloads are parsed as flash-page storage buffers instead of live audio.
  OfflineWavAssembler? _drainSink;
  Completer<void>? _drainDone;
  Timer? _drainQuietTimer;
  int _drainMaxIndex = -1;
  int _drainFrameCount = 0;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opusFs320;

  @override
  Future<void> onConnected() async {
    await Future<void>.delayed(_gattReadyDelay);
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.limitlessService,
        WearableDeviceUuids.limitlessRx,
      )).listen(_handleNotification),
    );
    await Future<void>.delayed(_gattReadyDelay);
    try {
      final level = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (level.isNotEmpty) batteryLevels.add(level.first);
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.batteryService,
          WearableDeviceUuids.batteryLevel,
        )).listen((value) {
          if (value.isNotEmpty) batteryLevels.add(value.first);
        }),
      );
    } catch (_) {
      // Battery is optional and must never block audio capture.
    }
    // Only the clock is synced at connect time. The audio data stream is
    // enabled on startRecording and disabled on stopRecording so the pendant
    // does not stream (and drain battery) while the app is merely paired.
    await transport.writeCharacteristic(
      WearableDeviceUuids.limitlessService,
      WearableDeviceUuids.limitlessTx,
      _encodeSetCurrentTime(DateTime.now().millisecondsSinceEpoch),
    );
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    _parseButtonStatus(data);
    final packet = _parseBlePacket(data);
    if (packet == null) return;
    final index = packet.index;
    if (_fragments.length >= _maximumPendingMessages &&
        !_fragments.containsKey(index)) {
      _fragments.remove(_fragments.keys.first);
    }
    final parts = _fragments.putIfAbsent(index, () => <int, List<int>>{});
    parts[packet.sequence] = packet.payload;
    if (parts.length != packet.fragmentCount) return;

    final payload = <int>[];
    for (var sequence = 0; sequence < packet.fragmentCount; sequence += 1) {
      final fragment = parts[sequence];
      if (fragment == null) return;
      payload.addAll(fragment);
    }
    _fragments.remove(index);

    if (_drainSink != null) {
      // In batch mode the payload carries flash-page storage buffers, not live
      // audio: route it to the offline drain instead of the capture stream.
      _handleBatchPayload(payload);
      return;
    }

    final frames = _extractFlashPageFrames(payload);
    if (frames.isEmpty) {
      frames.addAll(_extractMarkerFrames(payload));
    }
    for (final frame in frames) {
      audioBytes.add(frame);
    }
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    recording = true;
    await transport.writeCharacteristic(
      WearableDeviceUuids.limitlessService,
      WearableDeviceUuids.limitlessTx,
      _encodeEnableDataStream(enable: true),
    );
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    recording = false;
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.limitlessService,
        WearableDeviceUuids.limitlessTx,
        _encodeEnableDataStream(enable: false),
      );
    } catch (_) {
      // Best-effort stop; the pendant stops streaming on disconnect anyway.
    }
    _fragments.clear();
  }

  // --- Offline batch drain (WearableOfflineSync) ---

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    // Live capture and the offline batch drain share the pendant's TX/RX
    // channel, so they must never run at the same time.
    if (recording) return 0;
    final assembler = OfflineWavAssembler(
      codec: WearableAudioCodec.opusFs320,
      stripBleHeader: false,
    );
    if (!await assembler.ensureSupported()) {
      assembler.dispose();
      return 0;
    }
    _drainSink = assembler;
    _drainMaxIndex = -1;
    _drainFrameCount = 0;
    final done = Completer<void>();
    _drainDone = done;
    _resetDrainQuiet();
    try {
      // Ask the pendant to dump its stored flash pages over the notify channel.
      await _writeTx(_encodeDownloadFlashPages(batchMode: true, realTime: false));
      await done.future.timeout(_drainOverallTimeout, onTimeout: () {});
    } finally {
      _drainQuietTimer?.cancel();
      _drainQuietTimer = null;
      _drainSink = null;
      _drainDone = null;
    }

    // Return the pendant to live/idle streaming. This is a mode change only —
    // it does not free any stored pages — so it is safe to do before ingest.
    try {
      await _writeTx(
        _encodeDownloadFlashPages(batchMode: false, realTime: recording),
      );
    } catch (_) {}

    final pcmBytes = assembler.pcmByteLength;
    final wav = assembler.toWav();
    assembler.dispose();
    if (_drainFrameCount == 0 || pcmBytes < minBytes) return 0;
    // Durability invariant: ingest BEFORE acknowledging the flash pages. The
    // ACK is what advances the pendant's read cursor past them, so it must run
    // only after the recording is durably stored. If the ingest throws, the
    // pages are left un-acked and re-downloaded next sync (idempotent import),
    // never skipped/lost.
    await onRecording(
      WearableRecording(
        id: 'limitless-flash-$_drainMaxIndex',
        bytes: wav,
        contentType: 'audio/wav',
        filename: 'limitless-offline.wav',
      ),
    );
    // We only ack indexes actually received, so the worst case is a harmless
    // re-download, never skipped audio.
    if (_drainMaxIndex >= 0) {
      try {
        await _writeTx(_encodeAcknowledgeProcessedData(_drainMaxIndex));
      } catch (_) {}
    }
    return 1;
  }

  @override
  Future<void> cancelStoredSync() async {
    final done = _drainDone;
    _drainQuietTimer?.cancel();
    _drainQuietTimer = null;
    // Stop routing frames into the drain, but do not dispose the assembler here:
    // drainStoredAudio owns its lifecycle and disposes it once (disposing here
    // too would double-dispose).
    _drainSink = null;
    _drainDone = null;
    if (done != null && !done.isCompleted) done.complete();
    try {
      await _writeTx(
        _encodeDownloadFlashPages(batchMode: false, realTime: recording),
      );
    } catch (_) {}
  }

  void _resetDrainQuiet() {
    _drainQuietTimer?.cancel();
    _drainQuietTimer = Timer(_drainQuietGap, () {
      final done = _drainDone;
      if (done != null && !done.isCompleted) done.complete();
    });
  }

  Future<void> _writeTx(List<int> bytes) => transport.writeCharacteristic(
    WearableDeviceUuids.limitlessService,
    WearableDeviceUuids.limitlessTx,
    bytes,
  );

  /// Parses a batch payload: field 2 (length-delimited) carries each flash-page
  /// storage buffer.
  void _handleBatchPayload(List<int> payload) {
    var position = 0;
    try {
      while (position < payload.length) {
        final tag = payload[position++];
        final field = tag >> 3;
        final wireType = tag & 7;
        if (wireType == 2) {
          final length = _decodeVarint(payload, position);
          position = length.next;
          final end = position + length.value;
          if (end > payload.length) return;
          if (field == 2) _handleStorageBuffer(payload.sublist(position, end));
          position = end;
        } else if (wireType == 0) {
          position = _decodeVarint(payload, position).next;
        } else {
          return;
        }
      }
    } on FormatException {
      return;
    }
  }

  /// Parses one flash-page storage buffer: field 5 = page index (for ACK),
  /// field 6 = the flash-page whose Opus frames are decoded into the drain.
  void _handleStorageBuffer(List<int> data) {
    var position = 0;
    int? pageIndex;
    List<int>? flashPageData;
    try {
      while (position < data.length) {
        final tag = data[position++];
        final field = tag >> 3;
        final wireType = tag & 7;
        if (wireType == 0) {
          final value = _decodeVarint(data, position);
          position = value.next;
          if (field == 5) pageIndex = value.value;
        } else if (wireType == 2) {
          final length = _decodeVarint(data, position);
          position = length.next;
          final end = position + length.value;
          if (end > data.length) return;
          if (field == 6) flashPageData = data.sublist(position, end);
          position = end;
        } else {
          return;
        }
      }
    } on FormatException {
      return;
    }
    if (pageIndex != null && pageIndex > _drainMaxIndex) {
      _drainMaxIndex = pageIndex;
    }
    if (flashPageData != null) {
      for (final frame in _extractFlashPageFrames(flashPageData)) {
        _drainSink?.addFrame(frame);
        _drainFrameCount += 1;
      }
    }
    _resetDrainQuiet();
  }

  List<int> _encodeDownloadFlashPages({
    required bool batchMode,
    required bool realTime,
  }) {
    final message = <int>[
      ..._encodeField(1, 0, <int>[batchMode ? 1 : 0]),
      ..._encodeField(2, 0, <int>[realTime ? 1 : 0]),
    ];
    return _encodeBleWrapper(<int>[
      ..._encodeMessage(8, message),
      ..._encodeRequestData(),
    ]);
  }

  List<int> _encodeAcknowledgeProcessedData(int upToIndex) {
    return _encodeBleWrapper(<int>[
      ..._encodeMessage(7, _encodeField(1, 0, _encodeVarint(upToIndex))),
      ..._encodeRequestData(),
    ]);
  }

  _LimitlessBlePacket? _parseBlePacket(List<int> data) {
    var position = 0;
    int? index;
    var sequence = 0;
    int? fragmentCount;
    List<int>? payload;
    try {
      while (position < data.length) {
        final tag = data[position++];
        final field = tag >> 3;
        final wireType = tag & 7;
        if (wireType == 0) {
          final value = _decodeVarint(data, position);
          position = value.next;
          if (field == 1) index = value.value;
          if (field == 2) sequence = value.value;
          if (field == 3) fragmentCount = value.value;
        } else if (wireType == 2) {
          final length = _decodeVarint(data, position);
          position = length.next;
          final end = position + length.value;
          if (end > data.length) return null;
          if (field == 4) payload = data.sublist(position, end);
          position = end;
        } else {
          return null;
        }
      }
    } on FormatException {
      return null;
    }
    if (index == null ||
        payload == null ||
        fragmentCount == null ||
        fragmentCount <= 0 ||
        fragmentCount > _maximumFragmentsPerMessage ||
        sequence < 0 ||
        sequence >= fragmentCount) {
      return null;
    }
    return _LimitlessBlePacket(
      index: index,
      sequence: sequence,
      fragmentCount: fragmentCount,
      payload: payload,
    );
  }

  List<List<int>> _extractFlashPageFrames(List<int> data) {
    final frames = <List<int>>[];
    var position = 0;
    try {
      if (position < data.length && data[position] == 0x08) {
        position = _decodeVarint(data, position + 1).next;
      }
      if (position < data.length && data[position] == 0x10) {
        position = _decodeVarint(data, position + 1).next;
      }
      while (position < data.length - 1) {
        if (data[position++] != 0x1a) continue;
        final wrapperLength = _decodeVarint(data, position);
        position = wrapperLength.next;
        final wrapperEnd = position + wrapperLength.value;
        if (wrapperEnd > data.length) break;
        while (position < wrapperEnd - 1) {
          final marker = data[position++];
          if (marker == 0x08) {
            position = _decodeVarint(data, position).next;
            continue;
          }
          if (marker == 0x12) {
            final audioLength = _decodeVarint(data, position);
            position = audioLength.next;
            final audioEnd = position + audioLength.value;
            if (audioEnd > wrapperEnd) break;
            _extractLengthDelimitedFrames(data, position, audioEnd, frames);
            position = audioEnd;
            continue;
          }
          position = _skipWireValue(data, position, marker & 7, wrapperEnd);
        }
        position = wrapperEnd;
      }
    } on FormatException {
      return frames;
    }
    return frames;
  }

  void _extractLengthDelimitedFrames(
    List<int> data,
    int start,
    int end,
    List<List<int>> frames,
  ) {
    var position = start;
    while (position < end - 1) {
      final tag = data[position++];
      final wireType = tag & 7;
      if (wireType == 0) {
        position = _decodeVarint(data, position).next;
        continue;
      }
      if (wireType != 2) return;
      final length = _decodeVarint(data, position);
      position = length.next;
      final fieldEnd = position + length.value;
      if (fieldEnd > end) return;
      if (_looksLikeOpus(data, position, fieldEnd)) {
        frames.add(data.sublist(position, fieldEnd));
      } else if (length.value > _minimumOpusFrameBytes) {
        _extractLengthDelimitedFrames(data, position, fieldEnd, frames);
      }
      position = fieldEnd;
    }
  }

  List<List<int>> _extractMarkerFrames(List<int> data) {
    final frames = <List<int>>[];
    var position = 0;
    while (position < data.length - 2) {
      if (data[position++] != 0x22) continue;
      try {
        final length = _decodeVarint(data, position);
        position = length.next;
        final end = position + length.value;
        if (end > data.length) break;
        if (_looksLikeOpus(data, position, end)) {
          frames.add(data.sublist(position, end));
          position = end;
        }
      } on FormatException {
        break;
      }
    }
    return frames;
  }

  bool _looksLikeOpus(List<int> data, int start, int end) {
    final length = end - start;
    return length >= _minimumOpusFrameBytes &&
        length <= _maximumOpusFrameBytes &&
        start < data.length &&
        _validOpusToc.contains(data[start]);
  }

  int _skipWireValue(List<int> data, int position, int wireType, int end) {
    if (wireType == 0) return _decodeVarint(data, position).next;
    if (wireType == 1) return (position + 8).clamp(0, end);
    if (wireType == 5) return (position + 4).clamp(0, end);
    if (wireType == 2) {
      final length = _decodeVarint(data, position);
      return (length.next + length.value).clamp(0, end);
    }
    throw const FormatException('Unsupported protobuf wire type');
  }

  void _parseButtonStatus(List<int> data) {
    try {
      for (var position = 0; position < data.length - 5; position += 1) {
        if (data[position] != 0x22) continue;
        final outer = _decodeVarint(data, position + 1);
        final outerEnd = outer.next + outer.value;
        if (outerEnd > data.length || outer.next >= data.length) return;
        if (data[outer.next] != 0x42) continue;
        final button = _decodeVarint(data, outer.next + 1);
        final buttonEnd = button.next + button.value;
        if (buttonEnd > outerEnd) return;
        var inner = button.next;
        while (inner < buttonEnd - 1) {
          if (data[inner++] != 0x08) continue;
          final event = _decodeVarint(data, inner).value;
          if (event >= 1 && event <= 3) {
            buttonEvents.add(<int>[event]);
          }
          return;
        }
      }
    } on FormatException {
      return;
    }
  }

  List<int> _encodeSetCurrentTime(int timestampMs) {
    final time = _encodeField(1, 0, _encodeVarint(timestampMs));
    return _encodeBleWrapper(<int>[
      ..._encodeMessage(6, time),
      ..._encodeRequestData(),
    ]);
  }

  List<int> _encodeEnableDataStream({required bool enable}) {
    // Message 8 with field 1 = batch-mode flag (0 for the live stream) and
    // field 2 = enable. This matches the reference `_encodeEnableDataStream`
    // VERBATIM: field 1 is 0x00, not 1 — sending 1 here makes the pendant treat
    // it as a batch request and it never starts the live stream (the real cause
    // of "connected, LED off, no audio"). Verified against the pinned source.
    final message = <int>[
      ..._encodeField(1, 0, const <int>[0x00]),
      ..._encodeField(2, 0, <int>[enable ? 1 : 0]),
    ];
    return _encodeBleWrapper(<int>[
      ..._encodeMessage(8, message),
      ..._encodeRequestData(),
    ]);
  }

  List<int> _encodeRequestData() {
    _requestId += 1;
    return _encodeMessage(30, <int>[
      ..._encodeField(1, 0, _encodeVarint(_requestId)),
      ..._encodeField(2, 0, const <int>[0]),
    ]);
  }

  List<int> _encodeBleWrapper(List<int> payload) {
    final result = <int>[
      ..._encodeField(1, 0, _encodeVarint(_messageIndex)),
      ..._encodeField(2, 0, const <int>[0]),
      ..._encodeField(3, 0, const <int>[1]),
      ..._encodeField(4, 2, <int>[
        ..._encodeVarint(payload.length),
        ...payload,
      ]),
    ];
    _messageIndex += 1;
    return result;
  }

  List<int> _encodeMessage(int field, List<int> value) =>
      _encodeField(field, 2, <int>[..._encodeVarint(value.length), ...value]);

  List<int> _encodeField(int field, int wireType, List<int> value) => <int>[
    ..._encodeVarint((field << 3) | wireType),
    ...value,
  ];

  List<int> _encodeVarint(int value) {
    final result = <int>[];
    var remaining = value;
    while (remaining > 0x7f) {
      result.add((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    result.add(remaining & 0x7f);
    return result;
  }

  _DecodedVarint _decodeVarint(List<int> data, int position) {
    var result = 0;
    var shift = 0;
    var cursor = position;
    while (cursor < data.length && shift <= 63) {
      final byte = data[cursor++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return _DecodedVarint(result, cursor);
      }
      shift += 7;
    }
    throw const FormatException('Truncated protobuf varint');
  }
}

class _DecodedVarint {
  const _DecodedVarint(this.value, this.next);

  final int value;
  final int next;
}

class _LimitlessBlePacket {
  const _LimitlessBlePacket({
    required this.index,
    required this.sequence,
    required this.fragmentCount,
    required this.payload,
  });

  final int index;
  final int sequence;
  final int fragmentCount;
  final List<int> payload;
}
