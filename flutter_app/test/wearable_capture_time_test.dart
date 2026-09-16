import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/wearable_capture_time.dart';

void main() {
  test('device wall-clock stamps are UTC, not the phone zone', () {
    expect(
      WearableCaptureTime.parseUtcStamp('20260906_184302_2.opus'),
      DateTime.utc(2026, 9, 6, 18, 43, 2),
    );
    expect(
      WearableCaptureTime.parseUtcStamp('20260731180000'),
      DateTime.utc(2026, 7, 31, 18),
    );
    expect(WearableCaptureTime.parseUtcStamp('20260906_184302')!.isUtc, isTrue);
  });

  test(
    'a naive device ISO string is UTC, a Z/offset string keeps its instant',
    () {
      expect(
        WearableCaptureTime.parseDeviceInstant('2026-09-06T18:43:02'),
        DateTime.utc(2026, 9, 6, 18, 43, 2),
      );
      expect(
        WearableCaptureTime.parseDeviceInstant('2026-09-06T18:43:02Z'),
        DateTime.utc(2026, 9, 6, 18, 43, 2),
      );
      expect(
        WearableCaptureTime.parseDeviceInstant('2026-09-06T20:43:02+02:00'),
        DateTime.utc(2026, 9, 6, 18, 43, 2),
      );
    },
  );

  test(
    'unix seconds and millis reject a clock that is not a recording era',
    () {
      final stamp = DateTime.utc(2026, 9, 6, 18, 43, 2);
      expect(
        WearableCaptureTime.fromUnixSeconds(
          stamp.millisecondsSinceEpoch ~/ 1000,
        ),
        stamp,
      );
      expect(WearableCaptureTime.fromUnixSeconds(1), isNull);
      expect(
        WearableCaptureTime.fromUnixMillis(stamp.millisecondsSinceEpoch),
        stamp,
      );
    },
  );

  test('clock writes use UTC digits', () {
    expect(
      WearableCaptureTime.formatUtcStamp(DateTime.utc(2026, 9, 6, 18, 43, 2)),
      '20260906184302',
    );
    expect(
      WearableCaptureTime.formatUtcDate(DateTime.utc(2026, 9, 6, 18, 43, 2)),
      '2026-09-06',
    );
  });
}
