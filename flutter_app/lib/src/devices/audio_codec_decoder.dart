import 'dart:async';
import 'dart:typed_data';

import 'package:opus_codec/opus_codec.dart' as opus_codec;
import 'package:opus_codec_dart/opus_codec_dart.dart';

import 'omi/device_models.dart';

bool _opusInitialized = false;
Object? _opusInitializationError;
Future<bool>? _opusInitialization;
Future<Object>? _opusCodecLoadFuture;
const Duration wearableAudioCodecInitializationTimeout = Duration(seconds: 30);
const List<int> _opusSilenceProbe = <int>[0xf8, 0xff, 0xfe];

Future<bool> initializeWearableAudioCodecs({bool retry = false}) async {
  if (_opusInitialized) return true;
  final pending = _opusInitialization;
  if (pending != null) return pending;
  if (_opusInitializationError != null && !retry) return false;
  final initialization = _initializeOpus();
  _opusInitialization = initialization;
  try {
    return await initialization;
  } finally {
    if (identical(_opusInitialization, initialization)) {
      _opusInitialization = null;
    }
  }
}

Future<bool> _initializeOpus() async {
  try {
    _opusCodecLoadFuture ??= opus_codec.load();
    initOpus(
      await _opusCodecLoadFuture!.timeout(wearableAudioCodecInitializationTimeout),
    );
    final probe = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    try {
      probe.decode(input: Uint8List.fromList(_opusSilenceProbe));
    } finally {
      probe.destroy();
    }
    _opusInitializationError = null;
    _opusInitialized = true;
    return true;
  } catch (error) {
    _opusInitializationError = error;
    return false;
  }
}

String get wearableAudioCodecStatus => _opusInitialized
    ? 'ready'
    : _opusInitializationError == null
    ? 'not_initialized'
    : 'load_failed';

/// Decodes wearable audio frames to mono PCM16 @ 16 kHz.
///
/// Mirrors the Omi app approach:
/// - BLE packets often include a 3-byte firmware header
/// - Opus frames are decoded with the bundled cross-platform libopus runtime
/// - PCM8 is expanded to PCM16
/// - PCM16 is passed through
class WearableAudioDecoder {
  WearableAudioDecoder({
    required this.codec,
    this.sampleRate = 16000,
    this.stripBleHeader = true,
  });

  final WearableAudioCodec codec;
  final int sampleRate;
  final bool stripBleHeader;

  SimpleOpusDecoder? _opus;
  String? lastWarning;

  bool get isSupported {
    switch (codec) {
      case WearableAudioCodec.pcm8:
      case WearableAudioCodec.pcm16:
        return true;
      case WearableAudioCodec.opus:
      case WearableAudioCodec.opusFs320:
        return _opusInitialized;
      case WearableAudioCodec.aac:
      case WearableAudioCodec.lc3:
      case WearableAudioCodec.unknown:
        return false;
    }
  }

  Future<bool> ensureSupported() async {
    switch (codec) {
      case WearableAudioCodec.pcm8:
      case WearableAudioCodec.pcm16:
        return true;
      case WearableAudioCodec.opus:
      case WearableAudioCodec.opusFs320:
        return initializeWearableAudioCodecs(retry: true);
      case WearableAudioCodec.aac:
      case WearableAudioCodec.lc3:
      case WearableAudioCodec.unknown:
        return false;
    }
  }

  void _ensureOpus() {
    if (!_opusInitialized) {
      throw StateError(
        'The bundled Opus decoder could not be loaded'
        '${_opusInitializationError == null ? '.' : ': $_opusInitializationError'}',
      );
    }
    _opus ??= SimpleOpusDecoder(sampleRate: sampleRate, channels: 1);
  }

  /// Omi BLE packets: [packet_id_low, packet_id_high, packet_index, ...audio]
  static List<int> stripHeaderIfPresent(
    List<int> raw, {
    required bool enabled,
  }) {
    if (!enabled || raw.length <= 3) return raw;
    // Heuristic: multi-byte audio frames with tiny leading counters.
    return raw.sublist(3);
  }

  Uint8List? decodePacket(List<int> rawPacket) {
    lastWarning = null;
    final payload = stripHeaderIfPresent(rawPacket, enabled: stripBleHeader);
    if (payload.isEmpty) return null;

    switch (codec) {
      case WearableAudioCodec.pcm16:
        return Uint8List.fromList(payload);
      case WearableAudioCodec.pcm8:
        return _pcm8ToPcm16(payload);
      case WearableAudioCodec.opus:
      case WearableAudioCodec.opusFs320:
        return _decodeOpus(payload);
      case WearableAudioCodec.aac:
        lastWarning =
            'AAC wearable frames are received but not decoded in this build yet.';
        return null;
      case WearableAudioCodec.lc3:
        lastWarning =
            'LC3 wearable frames are received but not decoded in this build yet.';
        return null;
      case WearableAudioCodec.unknown:
        lastWarning = 'Unknown wearable audio codec; frames were dropped.';
        return null;
    }
  }

  Uint8List _pcm8ToPcm16(List<int> pcm8) {
    final out = Uint8List(pcm8.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < pcm8.length; i += 1) {
      // unsigned 8-bit PCM centered at 128 -> signed 16-bit
      final sample = ((pcm8[i] - 128) << 8).clamp(-32768, 32767);
      view.setInt16(i * 2, sample, Endian.little);
    }
    return out;
  }

  Uint8List? _decodeOpus(List<int> frame) {
    try {
      _ensureOpus();
      final samples = _opus!.decode(input: Uint8List.fromList(frame));
      final bytes = Uint8List(samples.length * 2);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < samples.length; i += 1) {
        view.setInt16(i * 2, samples[i], Endian.little);
      }
      return bytes;
    } catch (error) {
      lastWarning = 'Opus decode failed: $error';
      return null;
    }
  }

  void dispose() {
    try {
      _opus?.destroy();
    } catch (_) {}
    _opus = null;
  }
}

/// Reassembles Omi multi-packet frames using packet index/internal counters.
/// Based on Omi WavBytesUtil.storeFramePacket.
class OmiFrameAssembler {
  int _lastPacketIndex = -1;
  int _lastFrameId = -1;
  final List<int> _pending = <int>[];
  int lost = 0;

  List<int>? accept(List<int> value) {
    if (value.length < 4) return null;
    final index = value[0] + (value[1] << 8);
    final internal = value[2];
    final content = value.sublist(3);

    if (_lastPacketIndex == -1 && internal == 0) {
      _lastPacketIndex = index;
      _lastFrameId = internal;
      _pending
        ..clear()
        ..addAll(content);
      return null;
    }
    if (_lastPacketIndex == -1) return null;

    // Lost frame - reset
    if (index != _lastPacketIndex + 1 ||
        (internal != 0 && internal != _lastFrameId + 1)) {
      lost += 1;
      _lastPacketIndex = -1;
      _pending.clear();
      return null;
    }

    if (internal == 0) {
      final complete = List<int>.from(_pending);
      _pending
        ..clear()
        ..addAll(content);
      _lastFrameId = internal;
      _lastPacketIndex = index;
      return complete;
    }

    _pending.addAll(content);
    _lastFrameId = internal;
    _lastPacketIndex = index;
    return null;
  }

  void reset() {
    _lastPacketIndex = -1;
    _lastFrameId = -1;
    _pending.clear();
  }
}
