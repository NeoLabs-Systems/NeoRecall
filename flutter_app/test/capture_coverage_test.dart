import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/capture/capture_coverage.dart';

/// A recording device that stops delivering audio mid-conversation leaves a
/// session that ran for twenty minutes and a transcript made of thirty
/// seconds. Nothing else in the pipeline can tell those apart from a genuinely
/// short conversation, so this comparison is the last line of defence.
void main() {
  test('a take that captured what it ran for is not flagged', () {
    expect(
      captureShortfall(elapsedMs: 600000, capturedMs: 588000),
      isNull,
    );
  });

  test('a wearable that died after 32 seconds of a 19-minute take is', () {
    // The exact shape of the recording that prompted this: the live stream
    // stalled shortly after the start and the session stayed open regardless.
    final missing = captureShortfall(elapsedMs: 1140000, capturedMs: 32720);
    expect(missing, isNotNull);
    expect(missing!.inMinutes, 18);
  });

  test('short takes are never judged, so brief notes stay quiet', () {
    // Start-up and flush timing dominate here; flagging it would train the
    // user to ignore the warning that matters.
    expect(captureShortfall(elapsedMs: 45000, capturedMs: 0), isNull);
  });

  test('a take that captured nothing at all is reported in full', () {
    expect(
      captureShortfall(elapsedMs: 300000, capturedMs: 0),
      const Duration(minutes: 5),
    );
  });

  test('coverage just above the bar passes, just below does not', () {
    expect(captureShortfall(elapsedMs: 100000, capturedMs: 60000), isNull);
    expect(captureShortfall(elapsedMs: 100000, capturedMs: 59000), isNotNull);
  });
}
