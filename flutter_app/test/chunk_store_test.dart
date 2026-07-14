import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/models/recording.dart';

void main() {
  test('interrupted offline session survives serialization', () {
    final session = LocalRecordingDeclaration(
      id: 'session',
      sourceId: 'source',
      deviceId: 'device',
      deviceClientUuid: 'device-client',
      deviceName: 'Desktop',
      platform: 'macos',
      startedAt: DateTime.utc(2026, 7, 13, 10),
      timezone: 'Europe/Berlin',
      consentAttestedAt: DateTime.utc(2026, 7, 13, 9, 59),
      sourceKind: 'combined',
      channelLayout: 'microphone_left_system_right',
      endedAt: DateTime.utc(2026, 7, 13, 11),
      finalSequence: 4,
      interrupted: true,
    );
    final recovered = LocalRecordingDeclaration.fromMap(session.toMap());
    expect(recovered.interrupted, isTrue);
    expect(recovered.finalSequence, 4);
    expect(recovered.synced, isFalse);
  });
}
