import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';

/// Capture-critical Limitless Pendant protocol.
///
/// Commands and notifications use protobuf wire encoding inside a fragmented
/// BLE wrapper. This implementation follows the pinned Omi protocol source;
/// it does not use guessed one-byte start/stop commands.
class LimitlessConnector extends WearableConnector {
  LimitlessConnector({required super.device, required super.transport});

  static const int _maximumFragmentsPerMessage = 128;
  static const int _maximumPendingMessages = 256;
  static const int _minimumOpusFrameBytes = 10;
  static const int _maximumOpusFrameBytes = 200;
  static const Duration _gattReadyDelay = Duration(seconds: 1);
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
    final message = <int>[
      ..._encodeField(1, 0, const <int>[1]),
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
