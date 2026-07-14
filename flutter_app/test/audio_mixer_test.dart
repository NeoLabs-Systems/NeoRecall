import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/recording/audio_mixer.dart';

void main() {
  test('stereo mixer preserves microphone left and system right', () {
    final microphone = Uint8List.fromList(<int>[1, 0, 2, 0]);
    final system = Uint8List.fromList(<int>[3, 0, 4, 0]);
    expect(
      AudioMixer.stereoPcm16(microphone, system),
      Uint8List.fromList(<int>[1, 0, 3, 0, 2, 0, 4, 0]),
    );
  });

  test('WAV output is independently decodable PCM', () {
    final output = AudioMixer.wav(Uint8List(32000), channels: 1);
    final view = ByteData.sublistView(output);
    expect(String.fromCharCodes(output.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(output.sublist(8, 12)), 'WAVE');
    expect(view.getUint16(22, Endian.little), 1);
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint32(40, Endian.little), 32000);
  });
}
