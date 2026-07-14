import 'dart:typed_data';

class AudioMixer {
  static Uint8List stereoPcm16(Uint8List microphone, Uint8List system) {
    final frames =
        (microphone.length > system.length
            ? microphone.length
            : system.length) ~/
        2;
    final output = Uint8List(frames * 4);
    final data = ByteData.sublistView(output);
    final mic = ByteData.sublistView(microphone);
    final sys = ByteData.sublistView(system);
    for (var frame = 0; frame < frames; frame += 1) {
      data.setInt16(
        frame * 4,
        frame * 2 + 1 < microphone.length
            ? mic.getInt16(frame * 2, Endian.little)
            : 0,
        Endian.little,
      );
      data.setInt16(
        frame * 4 + 2,
        frame * 2 + 1 < system.length
            ? sys.getInt16(frame * 2, Endian.little)
            : 0,
        Endian.little,
      );
    }
    return output;
  }

  static Uint8List wav(
    Uint8List pcm, {
    required int channels,
    int sampleRate = 16000,
    int bitsPerSample = 16,
  }) {
    final output = Uint8List(44 + pcm.length);
    final data = ByteData.sublistView(output);
    void ascii(int offset, String value) {
      for (var index = 0; index < value.length; index += 1) {
        output[offset + index] = value.codeUnitAt(index);
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(
      28,
      sampleRate * channels * bitsPerSample ~/ 8,
      Endian.little,
    );
    data.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    data.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcm.length, Endian.little);
    output.setRange(44, output.length, pcm);
    return output;
  }
}
