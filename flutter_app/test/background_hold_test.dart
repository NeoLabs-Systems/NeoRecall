import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/background/background_hold.dart';
import 'package:neorecall/src/background/background_live_status.dart';

void main() {
  test('live status serializes one cross-platform notification contract', () {
    final startedAt = DateTime.utc(2026, 8, 25, 8);
    final status = BackgroundLiveStatus(
      phase: BackgroundLivePhase.recording,
      title: 'Recording from Phone microphone',
      detail: 'Recording safely',
      recordingStartedAt: startedAt,
      progress: 0.5,
      pendingBytes: 2048,
      pendingAudioSeconds: 12,
      etaSeconds: 30,
    );

    expect(status.toMap(), <String, Object?>{
      'phase': 'recording',
      'shortLabel': 'REC',
      'title': 'Recording from Phone microphone',
      'detail': 'Recording safely',
      'recordingStartedAtMs': startedAt.millisecondsSinceEpoch,
      'progress': 0.5,
      'pendingBytes': 2048,
      'pendingAudioSeconds': 12,
      'etaSeconds': 30,
      'issue': null,
    });
  });

  test('a request maps holds onto the platform capabilities they need', () {
    const microphoneOnly = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.microphoneCapture},
    );
    expect(microphoneOnly.needsMicrophone, isTrue);
    expect(microphoneOnly.needsConnectedDevice, isFalse);
    expect(microphoneOnly.isCapturing, isTrue);

    const linkOnly = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.wearableLink},
      deviceLabel: 'HeyPocket',
    );
    // An idle link needs the connected-device capability but is not capturing,
    // so the host must not claim microphone access or hold a wake lock for it.
    expect(linkOnly.needsConnectedDevice, isTrue);
    expect(linkOnly.needsMicrophone, isFalse);
    expect(linkOnly.isCapturing, isFalse);

    const syncing = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{
        BackgroundHold.wearableLink,
        BackgroundHold.wearableSync,
      },
      deviceLabel: 'HeyPocket',
    );
    // A transfer is not "recording", but it must not be stretched across sleep.
    expect(syncing.isCapturing, isFalse);
    expect(syncing.needsWakeLock, isTrue);
    expect(syncing.needsConnectedDevice, isTrue);
    expect(linkOnly.needsWakeLock, isFalse);

    const uploading = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.audioUpload},
    );
    expect(uploading.isCapturing, isFalse);
    expect(uploading.needsConnectedDevice, isFalse);
    expect(uploading.needsWakeLock, isTrue);

    const combined = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{
        BackgroundHold.microphoneCapture,
        BackgroundHold.wearableCapture,
      },
    );
    expect(combined.needsMicrophone, isTrue);
    expect(combined.needsConnectedDevice, isTrue);
    expect(combined.isCapturing, isTrue);
  });

  test('wire holds are stable and sorted so an unchanged request is equal', () {
    const first = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{
        BackgroundHold.wearableLink,
        BackgroundHold.microphoneCapture,
      },
      deviceLabel: 'Omi',
    );
    const second = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{
        BackgroundHold.microphoneCapture,
        BackgroundHold.wearableLink,
      },
      deviceLabel: 'Omi',
    );
    expect(first.wireHolds, <String>['microphoneCapture', 'wearableLink']);
    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(
      first ==
          const BackgroundRuntimeRequest(
            holds: <BackgroundHold>{BackgroundHold.microphoneCapture},
            deviceLabel: 'Omi',
          ),
      isFalse,
    );
  });

  test('notification text names what is actually happening', () {
    const link = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.wearableLink},
      deviceLabel: 'HeyPocket',
      deviceConnected: true,
    );
    expect(link.notificationTitle, 'NeoRecall stays connected');
    expect(link.notificationText, contains('HeyPocket'));
    expect(link.notificationText, contains('sync'));

    const reconnecting = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.wearableLink},
      deviceLabel: 'PK01_BLUE',
    );
    expect(reconnecting.notificationTitle, 'NeoRecall is reconnecting');
    expect(reconnecting.notificationText, 'Waiting for PK01_BLUE to reconnect');
    expect(reconnecting.notificationText, isNot(contains('stays linked')));

    const wearable = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.wearableCapture},
      deviceLabel: 'Omi',
    );
    expect(wearable.notificationTitle, 'NeoRecall is recording');
    expect(wearable.notificationText, contains('Omi'));

    const microphone = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.microphoneCapture},
    );
    expect(microphone.notificationText, contains('microphone'));

    const syncing = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{
        BackgroundHold.wearableLink,
        BackgroundHold.wearableSync,
      },
      deviceLabel: 'HeyPocket',
    );
    expect(syncing.notificationTitle, 'NeoRecall stays connected');
    expect(syncing.notificationText, 'Syncing recordings from HeyPocket');

    const uploading = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.audioUpload},
    );
    expect(uploading.notificationText, 'Uploading protected recordings');

    // Without a device name the text stays truthful instead of showing "null".
    const unnamed = BackgroundRuntimeRequest(
      holds: <BackgroundHold>{BackgroundHold.wearableLink},
    );
    expect(unnamed.notificationText, isNot(contains('null')));
  });

  test('platform state parses holds and ignores unknown identifiers', () {
    final state = BackgroundRuntimeState.fromMap(<Object?, Object?>{
      'running': true,
      'holds': <Object?>['wearableLink', 'somethingNewer', 42],
      'foreground': false,
      'microphoneUnavailable': true,
    });
    expect(state.running, isTrue);
    expect(state.holds, <BackgroundHold>{BackgroundHold.wearableLink});
    expect(state.foreground, isFalse);
    expect(state.microphoneUnavailable, isTrue);

    final empty = BackgroundRuntimeState.fromMap(const <Object?, Object?>{});
    expect(empty.running, isFalse);
    expect(empty.holds, isEmpty);
  });
}
