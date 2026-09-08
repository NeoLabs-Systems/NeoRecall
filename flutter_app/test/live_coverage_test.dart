import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/live_coverage.dart';

/// This measurement decides whether a wearable's own copy of a recording may be
/// deleted, so every way of overstating it is a way of destroying audio that
/// exists nowhere else.
void main() {
  final start = DateTime.utc(2026, 9, 8, 7);

  test('continuous frames accumulate the time they cover', () {
    final coverage = LiveCoverage();
    for (var second = 0; second <= 30; second++) {
      coverage.frame('take.opus', start.add(Duration(seconds: second)));
    }

    expect(coverage.seconds, 30);
  });

  // The failure that cost a morning of recordings: the stream delivered half a
  // minute, died, and a single late frame made the silence look like audio.
  test('a hole in the stream is not counted as covered', () {
    final coverage = LiveCoverage();
    for (var second = 0; second <= 30; second++) {
      coverage.frame('take.opus', start.add(Duration(seconds: second)));
    }
    coverage.frame('take.opus', start.add(const Duration(minutes: 19)));

    expect(coverage.seconds, 30);
  });

  test('a brief stutter stays continuous', () {
    final coverage = LiveCoverage();
    coverage.frame('take.opus', start);
    coverage.frame('take.opus', start.add(const Duration(seconds: 2)));

    expect(coverage.seconds, 2);
  });

  test('a new take is measured from nothing', () {
    final coverage = LiveCoverage();
    coverage.frame('first.opus', start);
    coverage.frame('first.opus', start.add(const Duration(seconds: 3)));
    coverage.frame('second.opus', start.add(const Duration(seconds: 4)));

    expect(coverage.fileId, 'second.opus');
    expect(coverage.seconds, 0);
  });

  test('a single frame covers nothing', () {
    final coverage = LiveCoverage();
    coverage.frame('take.opus', start);

    expect(coverage.seconds, 0);
  });

  test('frames arriving out of order never add time', () {
    final coverage = LiveCoverage();
    coverage.frame('take.opus', start.add(const Duration(seconds: 5)));
    coverage.frame('take.opus', start);

    expect(coverage.seconds, 0);
  });

  test('reset forgets the take', () {
    final coverage = LiveCoverage();
    coverage.frame('take.opus', start);
    coverage.frame('take.opus', start.add(const Duration(seconds: 2)));
    coverage.reset();

    expect(coverage.fileId, isNull);
    expect(coverage.seconds, 0);
  });
}
