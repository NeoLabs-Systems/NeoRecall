import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/main_timeline.dart';
import 'package:neorecall/src/models/timeline_moment.dart';
import 'package:neorecall/src/models/transcript.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/recording/audio_frame.dart';
import 'package:neorecall/src/recording/recorder.dart';
import 'package:neorecall/src/sync/processing_status.dart';

/// Opening and closing a transcript animates the moment's height. The rail that
/// runs down the side of a moment used to be a stretched column of the same
/// row, which fixed the row's height to what its children measured while the
/// transcript was still animating towards it — so every collapse overflowed
/// for the length of the animation.
void main() {
  TimelineMoment moment() {
    final start = DateTime.utc(2026, 3, 4, 9);
    return TimelineMoment(
      id: 'moment-1',
      kind: 'conversation',
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 12)),
      state: 'closed',
      titleEn: 'Kitchen rebuild',
      summaryEn: 'What the fitter needs before Monday.',
      topics: const <String>['kitchen', 'timings'],
      segmentCount: 12,
      segments: <TranscriptSegment>[
        for (var index = 0; index < 12; index++)
          TranscriptSegment(
            id: 'segment-$index',
            text:
                'Line $index of a transcript long enough to change the height of the moment when it is shown in full.',
            startedAt: start.add(Duration(minutes: index)),
            endedAt: start.add(Duration(minutes: index, seconds: 40)),
            speaker: index.isEven ? 'You' : 'Fitter',
          ),
      ],
    );
  }

  // The app rebuilds the screen from one listener at its root; the test
  // stands in for that so a change to the controller reaches the page.
  Widget wrap(NeoRecallController controller) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => TimelineScreen(controller: controller),
      ),
    ),
  );

  testWidgets('expanding and collapsing a transcript never overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = NeoRecallController(recorder: _FakeRecorder())
      ..moments = <TimelineMoment>[moment()];
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(controller));
    await tester.pump();
    expect(find.text('10 more lines'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('10 more lines'));
    // Every frame of the animation, not only where it ends up.
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull, reason: 'opening frame $frame');
    }
    expect(find.text('Show less'), findsOneWidget);

    // The open moment is taller than the phone; the control that closes it
    // sits below the fold.
    await tester.ensureVisible(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Show less'));
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull, reason: 'closing frame $frame');
    }
    await tester.pumpAndSettle();
    expect(find.text('10 more lines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the processing banner shows only while audio is moving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = NeoRecallController(recorder: _FakeRecorder())
      ..moments = <TimelineMoment>[moment()];
    addTearDown(controller.dispose);

    // Nothing in flight: no banner, because a spinner that is always there
    // stops saying anything.
    await tester.pumpWidget(wrap(controller));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Queued is not moving either.
    controller
      ..processingLedgerStatus = const ProcessingStatusSnapshot(
        phoneQueued: 1,
        totalPending: 1,
      )
      ..notifyListeners();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    controller
      ..processingLedgerStatus = const ProcessingStatusSnapshot(
        transcribing: 2,
        totalPending: 2,
        eta: Duration(minutes: 3),
      )
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Transcribing 2 recordings'), findsOneWidget);
    expect(find.text('about 3 min left'), findsOneWidget);

    controller
      ..processingLedgerStatus = const ProcessingStatusSnapshot(
        uploading: 1,
        totalPending: 1,
      )
      ..notifyListeners();
    await tester.pump();
    expect(find.text('Uploading a recording'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

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
  bool get isRecording => false;

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
