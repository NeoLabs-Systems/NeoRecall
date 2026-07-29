import 'dart:math' as math;

/// Maps linear RMS audio amplitudes to a stable, perceptual UI meter.
class AudioLevelScale {
  const AudioLevelScale({
    this.floorDb = -55,
    this.ceilingDb = -6,
    this.attack = 0.68,
    this.release = 0.2,
  }) : assert(floorDb < ceilingDb),
       assert(attack > 0 && attack <= 1),
       assert(release > 0 && release <= 1);

  final double floorDb;
  final double ceilingDb;
  final double attack;
  final double release;

  double normalizeRms(double rms) {
    if (!rms.isFinite || rms <= 0) return 0;
    final db = 20 * math.log(rms.clamp(0, 1)) / math.ln10;
    return ((db - floorDb) / (ceilingDb - floorDb)).clamp(0, 1);
  }

  double smooth(double previous, double next) {
    final factor = next >= previous ? attack : release;
    return (previous + (next - previous) * factor).clamp(0, 1);
  }
}
