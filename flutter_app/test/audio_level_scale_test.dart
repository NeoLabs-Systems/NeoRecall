import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/recording/audio_level_scale.dart';

void main() {
  const scale = AudioLevelScale();

  test('perceptual level scale makes normal speech visible', () {
    expect(scale.normalizeRms(0), 0);
    expect(scale.normalizeRms(0.01), greaterThan(0.3));
    expect(scale.normalizeRms(0.03), greaterThan(0.5));
    expect(scale.normalizeRms(0.1), greaterThan(0.65));
    expect(scale.normalizeRms(1), 1);
  });

  test('level smoothing reacts faster to attack than release', () {
    expect(scale.smooth(0, 1), closeTo(0.68, 0.001));
    expect(scale.smooth(1, 0), closeTo(0.8, 0.001));
  });
}
