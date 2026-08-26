import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/recording/audio_frame.dart';
import 'package:neorecall/src/recording/recorder.dart';
import 'package:neorecall/src/sync/processing_status.dart';
import 'package:neorecall/src/sync/pending_audio_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The record screen animates and samples audio levels only while recording, so
/// the live state needs its own coverage: the idle screen must settle, the live
/// screen must show elapsed time driven by its own clock (not by audio
/// callbacks), and leaving the screen must stop the ticker.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  NeoRecallController recordingController() {
    final controller = _PlaybackController(recorder: _FakeRecorder())
      ..recordingStartedAt = DateTime.now().toUtc().subtract(
        const Duration(minutes: 3, seconds: 5),
      )
      ..audioLevel = 0.7
      ..pendingAudioBytes = 3 * 1048576
      ..processingLedgerStatus = const ProcessingStatusSnapshot(
        pendingBytes: 3 * 1048576,
        pendingAudioDuration: Duration(hours: 1, minutes: 12),
        phoneQueued: 2,
        uploading: 1,
        totalPending: 3,
        eta: Duration(minutes: 2),
      );
    return controller;
  }

  testWidgets('the live stage shows elapsed time and the stop control', (
    tester,
  ) async {
    final controller = recordingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('Recording is visible and active'), findsOneWidget);
    expect(find.text('00:03:05'), findsOneWidget);
    expect(find.text('Stop and finalize'), findsOneWidget);
    expect(find.text('Start recording'), findsNothing);
    expect(find.text('CAPTURE SOURCE'), findsNothing);
    expect(find.text('CAPTURE SOURCES'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('recording-context-highlight')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('recording-context-note')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('recording-context-photo')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('recording-context-file')),
      findsOneWidget,
    );
    expect(find.text('Uploading to server'), findsOneWidget);
    expect(find.textContaining('3.0 MB protected'), findsOneWidget);
    expect(find.textContaining('1h 12m audio'), findsOneWidget);
    expect(find.textContaining('ETA about 2 min'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tearing the screen down must cancel the sampler; a leaked periodic timer
    // fails the test binding at the end of the test.
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('processing status expands into the full interactive pipeline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = recordingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No watch backlog'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showFirst,
    );

    await tester.ensureVisible(find.text('Uploading to server'));
    await tester.tap(find.text('Uploading to server'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showSecond,
    );
    expect(find.text('Watch transfer'), findsOneWidget);
    expect(find.text('Stored on phone'), findsOneWidget);
    expect(find.text('Server upload'), findsOneWidget);
    expect(find.text('Server transcription'), findsOneWidget);
    expect(find.text('Safe completion'), findsOneWidget);
    expect(find.text('Review queued audio'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final reviewButton = find.byKey(
      const ValueKey<String>('pending-audio-review'),
    );
    tester.widget<OutlinedButton>(reviewButton).onPressed!.call();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      find.text('Local playback only · upload continues normally'),
      findsOneWidget,
    );
    expect(find.text('On this device'), findsOneWidget);
    expect(find.textContaining('part'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('Wi-Fi wait exposes a one-time mobile-data upload action', (
    tester,
  ) async {
    final controller = recordingController()
      ..processingLedgerStatus = const ProcessingStatusSnapshot(
        pendingBytes: 1048576,
        phoneQueued: 1,
        totalPending: 1,
        waitingForUnmeteredNetwork: true,
        issues: <ProcessingIssue>[
          ProcessingIssue(
            message:
                'Waiting for Wi-Fi because mobile-data uploads are disabled.',
          ),
        ],
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 100));

    final action = find.byKey(
      const ValueKey<String>('upload-with-mobile-data'),
    );
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();

    expect(
      (controller as _PlaybackController).mobileDataUploadRequested,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a silent source still reads as live for hours', (tester) async {
    // The fake recorder emits no level events at all, so nothing here depends
    // on audio callbacks arriving — the stage drives itself.
    final controller = NeoRecallController(recorder: _FakeRecorder())
      ..recordingStartedAt = DateTime.now().toUtc().subtract(
        const Duration(hours: 2, minutes: 7, seconds: 9),
      )
      ..audioLevel = 0;
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('02:07:09'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
  });

  testWidgets('the idle screen settles instead of animating forever', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    // Would time out if the orb kept a repeating animation running while idle.
    await tester.pumpAndSettle();

    expect(find.text('STANDBY'), findsOneWidget);
    expect(find.text('Ready to record'), findsOneWidget);
    expect(find.text('Start recording'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone microphone hides the offline wearable sync card', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = NeoRecallController();
    await controller.audioDeviceSessions.bindAccount('account-1');
    controller.audioDeviceSessions.preferredDevice =
        const AudioDeviceDescriptor(
          adapterId: 'omi_family',
          deviceKey: 'pocket-1',
          displayName: 'Pocket recorder',
          transport: 'bluetooth_le',
          metadata: <String, Object?>{'type': 'heyPocket'},
        );
    controller.preferBluetoothCapture = true;
    controller.preferredDeviceLabel = 'Pocket recorder';
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Pocket recorder records on its own'), findsOneWidget);

    final phoneMicrophone = find.text('Phone microphone');
    await tester.ensureVisible(phoneMicrophone);
    await tester.tap(phoneMicrophone);
    await tester.pumpAndSettle();
    expect(find.text('Pocket recorder records on its own'), findsNothing);
    expect(controller.preferBluetoothCapture, isFalse);
    expect(tester.takeException(), isNull);
  });

  // flutter_test reports Android by default, so every other test here exercises
  // the two-option mobile picker. Desktop gets a third source and, once wide
  // enough, a two-column layout — neither of which mobile ever renders.
  testWidgets('desktop offers all three sources side by side', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1180, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      final controller = NeoRecallController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
      await tester.pumpAndSettle();

      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Device audio'), findsOneWidget);
      expect(find.text('Bluetooth device'), findsOneWidget);
      expect(find.text('Phone microphone'), findsNothing);
      expect(find.text('CAPTURE SOURCES'), findsOneWidget);
      expect(
        find.byIcon(Icons.check_circle_rounded),
        findsNWidgets(2),
        reason: 'microphone and device audio should both start selected',
      );

      // Bluetooth is not selected until asked for, and selecting it reveals the
      // device setup affordances.
      await tester.tap(find.text('Bluetooth device'));
      await tester.pumpAndSettle();
      expect(find.text('Scan for wearables'), findsOneWidget);
      expect(
        find.text(
          'Connect a supported Bluetooth device before starting this source.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final size in <Size>[const Size(390, 844), const Size(1180, 780)]) {
    testWidgets('the live record screen lays out at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = recordingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.takeException(),
        isNull,
        reason: 'the live record screen overflowed at ${size.width}px',
      );

      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      await tester.pump();
    });
  }
}

class _PlaybackController extends NeoRecallController {
  _PlaybackController({required super.recorder});

  bool mobileDataUploadRequested = false;

  @override
  Future<void> uploadQueuedAudioOnMobileDataOnce() async {
    mobileDataUploadRequested = true;
  }

  @override
  Future<List<PendingAudioRecording>> loadPendingAudioRecordings() async =>
      <PendingAudioRecording>[
        PendingAudioRecording(
          id: 'session:source',
          startedAt: DateTime.utc(2026, 8, 25, 7, 30),
          duration: const Duration(minutes: 1, seconds: 12),
          byteSize: 3 * 1048576,
          stage: PendingAudioPlaybackStage.onDevice,
          parts: const <PendingAudioPart>[
            PendingAudioPart(
              id: 'part-1',
              duration: Duration(minutes: 1, seconds: 12),
              mimeType: 'audio/wav',
            ),
          ],
        ),
      ];

  @override
  Future<Uint8List> readPendingAudioPart(String partId) async => Uint8List(44);
}

/// Reports an active recording without touching any platform channel.
class _FakeRecorder implements RecallRecorder {
  @override
  Stream<RecordedAudioChunk> get chunks =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<RecordedAudioChunk> get partials =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<String> get warnings => const Stream<String>.empty();
  @override
  Stream<double> get levels => const Stream<double>.empty();

  @override
  bool get isRecording => true;

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) async => const RecorderCapability(
    microphone: true,
    systemAudio: false,
    persistentStorage: false,
    sampleRate: 16000,
    sourceKind: 'microphone',
  );

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
