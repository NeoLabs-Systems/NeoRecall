import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/wearable_ingested_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The record that decides whether a wearable's own copy of a recording may be
/// deleted. Getting it wrong in the permissive direction destroys audio that
/// exists nowhere else, so every rule here is stated as a test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WearableIngestedFiles.resetForTest();
  });

  test('a file this phone never saw is never treated as captured', () {
    expect(WearableIngestedFiles.covers('dev', 'take.opus', 600), isFalse);
  });

  test('a moment of live audio does not account for a long take', () {
    // The exact failure: thirty seconds of live stream, a take of nineteen
    // minutes, and the device's copy deleted as redundant.
    expect(
      WearableIngestedFiles.coversSpan(liveSeconds: 32, takeSeconds: 1140),
      isFalse,
    );
  });

  // The Gem's own button starts takes the phone never sees begin. Claiming
  // coverage there would delete whatever was recorded before the phone joined.
  test('a take this phone did not see start is never covered', () {
    expect(
      WearableIngestedFiles.coversSpan(liveSeconds: 600, takeSeconds: null),
      isFalse,
    );
  });

  test('a take carried live end to end is covered', () {
    expect(
      WearableIngestedFiles.coversSpan(liveSeconds: 1136, takeSeconds: 1140),
      isTrue,
    );
  });

  test('the seconds a healthy take misses at each end are tolerated', () {
    // Frames begin after the start command and stop before the stop command.
    expect(
      WearableIngestedFiles.coversSpan(liveSeconds: 0, takeSeconds: 1),
      isTrue,
    );
    expect(
      WearableIngestedFiles.coversSpan(liveSeconds: 26, takeSeconds: 30),
      isTrue,
    );
  });

  test(
    'a stalled live stream is never treated as covering the device file',
    () async {
      await WearableIngestedFiles.remember('dev', 'take.opus', 30);
      await WearableIngestedFiles.markIncomplete('dev', 'take.opus');

      expect(
        WearableIngestedFiles.coversSpan(liveSeconds: 30, takeSeconds: 34),
        isTrue,
      );
      expect(WearableIngestedFiles.covers('dev', 'take.opus', 34), isFalse);

      WearableIngestedFiles.resetForTest();
      await WearableIngestedFiles.hydrate('dev');
      expect(WearableIngestedFiles.covers('dev', 'take.opus', 34), isFalse);
    },
  );

  test('a reconnect that restarts the measurement cannot shrink it', () async {
    await WearableIngestedFiles.remember('dev', 'take.opus', 900);
    await WearableIngestedFiles.remember('dev', 'take.opus', 12);

    expect(WearableIngestedFiles.seconds('dev', 'take.opus'), 900);
  });

  test('what was captured survives a restart of the app', () async {
    await WearableIngestedFiles.remember('dev', 'take.opus', 300);
    WearableIngestedFiles.resetForTest();
    await WearableIngestedFiles.hydrate('dev');

    expect(WearableIngestedFiles.seconds('dev', 'take.opus'), 300);
    expect(WearableIngestedFiles.covers('dev', 'take.opus', 300), isTrue);
    expect(WearableIngestedFiles.covers('dev', 'take.opus', 3000), isFalse);
  });
}
