import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/recording/recording_schedule.dart';

void main() {
  test('disabled and equal-boundary schedules allow 24/7 recording', () {
    expect(
      const RecordingSchedule(
        enabled: false,
        startMinute: 480,
        endMinute: 1380,
      ).allows(DateTime(2026, 1, 1, 2)),
      isTrue,
    );
    expect(
      const RecordingSchedule(
        enabled: true,
        startMinute: 0,
        endMinute: 0,
      ).allows(DateTime(2026, 1, 1, 2)),
      isTrue,
    );
  });

  test('day schedule excludes its end boundary', () {
    const schedule = RecordingSchedule(
      enabled: true,
      startMinute: 8 * 60,
      endMinute: 23 * 60,
    );
    expect(schedule.allows(DateTime(2026, 1, 1, 7, 59)), isFalse);
    expect(schedule.allows(DateTime(2026, 1, 1, 8)), isTrue);
    expect(schedule.allows(DateTime(2026, 1, 1, 22, 59)), isTrue);
    expect(schedule.allows(DateTime(2026, 1, 1, 23)), isFalse);
    expect(
      schedule.nextBoundary(DateTime(2026, 1, 1, 9)),
      DateTime(2026, 1, 1, 23),
    );
  });

  test('overnight schedule crosses midnight and finds both boundaries', () {
    const schedule = RecordingSchedule(
      enabled: true,
      startMinute: 22 * 60,
      endMinute: 6 * 60,
    );
    expect(schedule.allows(DateTime(2026, 1, 1, 23)), isTrue);
    expect(schedule.allows(DateTime(2026, 1, 2, 5, 59)), isTrue);
    expect(schedule.allows(DateTime(2026, 1, 2, 12)), isFalse);
    expect(
      schedule.nextBoundary(DateTime(2026, 1, 1, 23)),
      DateTime(2026, 1, 2, 6),
    );
    expect(
      schedule.nextBoundary(DateTime(2026, 1, 2, 12)),
      DateTime(2026, 1, 2, 22),
    );
  });
}
