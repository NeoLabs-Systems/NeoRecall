import 'dart:typed_data';

import '../audio_codec_decoder.dart';
import 'device_models.dart';

/// Accumulates raw device audio frames pulled from on-board storage, decodes
/// them to 16 kHz mono PCM16 via [WearableAudioDecoder], and produces a
/// self-contained WAV.
///
/// This is what lets frame-based wearables (Omi, Limitless) feed their offline
/// recordings into the exact same server import pipeline as any uploaded file:
/// the connector drains raw Opus/PCM frames, this assembles a decodable WAV, and
/// the import path (ffmpeg-backed) handles the rest.
class OfflineWavAssembler {
  OfflineWavAssembler({
    required WearableAudioCodec codec,
    bool stripBleHeader = false,
    this.sampleRate = 16000,
  }) : _decoder = WearableAudioDecoder(
         codec: codec,
         sampleRate: sampleRate,
         stripBleHeader: stripBleHeader,
       );

  final WearableAudioDecoder _decoder;
  final int sampleRate;
  final BytesBuilder _pcm = BytesBuilder();

  /// Ensures the codec's decoder is ready (e.g. native Opus). Returns false when
  /// the platform cannot decode this codec, so the caller can skip the drain.
  Future<bool> ensureSupported() => _decoder.ensureSupported();

  /// Decodes one stored frame and appends its PCM16 to the buffer.
  void addFrame(List<int> frame) {
    final pcm = _decoder.decodePacket(frame);
    if (pcm != null && pcm.isNotEmpty) _pcm.add(pcm);
  }

  /// Number of decoded PCM bytes accumulated so far.
  int get pcmByteLength => _pcm.length;

  /// Wraps the accumulated PCM16 mono as a WAV container.
  Uint8List toWav() => wrapPcm16Wav(_pcm.toBytes(), sampleRate: sampleRate);

  void dispose() => _decoder.dispose();

  /// Wraps mono 16-bit little-endian PCM in a canonical 44-byte WAV header.
  static Uint8List wrapPcm16Wav(Uint8List pcm, {int sampleRate = 16000}) {
    const channels = 1;
    const bitsPerSample = 16;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final byteRate = sampleRate * blockAlign;
    final out = BytesBuilder();
    void ascii(String value) => out.add(value.codeUnits);
    void u32(int v) =>
        out.add(<int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
    void u16(int v) => out.add(<int>[v & 0xFF, (v >> 8) & 0xFF]);

    ascii('RIFF');
    u32(36 + pcm.length);
    ascii('WAVE');
    ascii('fmt ');
    u32(16);
    u16(1); // PCM
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bitsPerSample);
    ascii('data');
    u32(pcm.length);
    out.add(pcm);
    return out.toBytes();
  }
}
