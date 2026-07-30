import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/mp3_stream_decoder.dart';

void main() {
  test('downmixToMono averages stereo and passes mono through', () {
    expect(
      downmixToMono(Int16List.fromList(<int>[10, 20, 30, 40]), 2).toList(),
      <int>[15, 35],
    );
    expect(
      downmixToMono(Int16List.fromList(<int>[7, 8, 9]), 1).toList(),
      <int>[7, 8, 9],
    );
  });

  test('int16ToBytesLE packs little-endian signed samples', () {
    expect(
      int16ToBytesLE(Int16List.fromList(<int>[1, -1, 256])).toList(),
      <int>[0x01, 0x00, 0xFF, 0xFF, 0x00, 0x01],
    );
  });

  test('LinearResampler passes through when rates match', () {
    final resampler = LinearResampler(inputRate: 16000, outputRate: 16000);
    expect(
      resampler.process(Int16List.fromList(<int>[1, 2, 3])).toList(),
      <int>[1, 2, 3],
    );
  });

  test('LinearResampler downsamples 2:1', () {
    final resampler = LinearResampler(inputRate: 32000, outputRate: 16000);
    expect(
      resampler.process(Int16List.fromList(<int>[0, 100, 200, 300])).toList(),
      <int>[0, 200],
    );
    expect(
      resampler.process(Int16List.fromList(<int>[400, 500, 600, 700])).toList(),
      <int>[400, 600],
    );
  });

  test('LinearResampler interpolates across buffer boundaries at 1:2', () {
    final resampler = LinearResampler(inputRate: 16000, outputRate: 32000);
    // First buffer emits samples up to its last usable pair.
    expect(
      resampler.process(Int16List.fromList(<int>[0, 100])).toList(),
      <int>[0, 50],
    );
    // The next buffer's first outputs interpolate against the retained tail,
    // proving there is no discontinuity at the BLE-chunk seam.
    expect(
      resampler.process(Int16List.fromList(<int>[200])).toList(),
      <int>[100, 150],
    );
  });
}
