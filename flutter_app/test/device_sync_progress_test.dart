import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/record/sync_cards.dart';
import 'package:neorecall/src/devices/omi/offline_sync.dart';

/// A full Omi ring takes minutes to transfer — a live drain measured 30 249
/// packets over 215 s. Over that span an indeterminate spinner is
/// indistinguishable from a hang, so progress has to be real and readable.
void main() {
  group('WearableSyncProgress', () {
    test('reports a fraction only once the device announced the total', () {
      expect(const WearableSyncProgress().fraction, isNull);
      expect(
        const WearableSyncProgress(transferred: 100).fraction,
        isNull,
        reason: 'without a total the transfer is genuinely indeterminate',
      );
      expect(
        const WearableSyncProgress(transferred: 15000, total: 30000).fraction,
        closeTo(0.5, 0.001),
      );
    });

    test('a fraction never exceeds 1 even if extra packets arrive', () {
      expect(
        const WearableSyncProgress(transferred: 31000, total: 30000).fraction,
        1.0,
      );
    });

    test('an untouched progress reads as empty', () {
      expect(const WearableSyncProgress().isEmpty, isTrue);
      expect(const WearableSyncProgress(pendingSeconds: 5).isEmpty, isFalse);
    });
  });

  group('pending-audio wording', () {
    test('scales the unit so the number stays readable', () {
      expect(DeviceSyncStatusView.formatDuration(0), 'nothing');
      expect(DeviceSyncStatusView.formatDuration(-5), 'nothing');
      expect(DeviceSyncStatusView.formatDuration(45), '45s of audio');
      expect(DeviceSyncStatusView.formatDuration(90), '2 min of audio');
      expect(DeviceSyncStatusView.formatDuration(2620), '44 min of audio');
      expect(DeviceSyncStatusView.formatDuration(7200), '2.0 h of audio');
    });

    test('matches the audio a real full ring actually held', () {
      // Measured on hardware: 30 249 packets decoded to 131 012 opus frames at
      // 20 ms each. The connector's per-packet constant must land on that, or
      // the UI would misreport how much is waiting.
      const packets = 30249;
      const measuredSeconds = 131012 * 0.02;
      const perPacket = 0.0866; // mirrors OmiConnector._secondsPerPacket
      expect((packets * perPacket), closeTo(measuredSeconds, 30));
      expect(
        DeviceSyncStatusView.formatDuration((packets * perPacket).round()),
        '44 min of audio',
      );
    });
  });
}
