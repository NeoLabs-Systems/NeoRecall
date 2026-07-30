import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/device_models.dart';
import 'package:neorecall/src/devices/omi/offline_audio.dart';

void main() {
  test('OfflineWavAssembler wraps decoded PCM16 frames in a valid WAV', () {
    final assembler = OfflineWavAssembler(
      codec: WearableAudioCodec.pcm16,
      stripBleHeader: false,
      sampleRate: 16000,
    );
    // pcm16 frames are passed through as little-endian PCM16 samples.
    assembler.addFrame(<int>[0x10, 0x00, 0x20, 0x00]); // 2 samples
    assembler.addFrame(<int>[0x30, 0x00, 0x40, 0x00]); // 2 samples
    expect(assembler.pcmByteLength, 8);

    final wav = assembler.toWav();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');

    int u32(int at) =>
        wav[at] | (wav[at + 1] << 8) | (wav[at + 2] << 16) | (wav[at + 3] << 24);
    int u16(int at) => wav[at] | (wav[at + 1] << 8);
    expect(u16(20), 1, reason: 'PCM format tag');
    expect(u16(22), 1, reason: 'mono');
    expect(u32(24), 16000, reason: 'sample rate');
    expect(u16(34), 16, reason: 'bits per sample');
    expect(u32(40), 8, reason: 'data chunk size = PCM byte length');
    expect(wav.length, 44 + 8);
    // Payload survived round-trip.
    expect(wav.sublist(44), <int>[0x10, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40, 0x00]);
    assembler.dispose();
  });

  test('OfflineWavAssembler yields a header-only WAV when no audio decoded', () {
    final assembler = OfflineWavAssembler(codec: WearableAudioCodec.pcm16);
    final wav = assembler.toWav();
    expect(wav.length, 44);
    expect(
      wav[40] | (wav[41] << 8) | (wav[42] << 16) | (wav[43] << 24),
      0,
    );
    assembler.dispose();
  });
}
