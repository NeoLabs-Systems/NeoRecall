import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';
import 'package:neorecall/src/devices/appliance/ui/appliance_sheet.dart';
import 'package:neorecall/src/record/capture_orb.dart';
import 'package:neorecall/src/record/record_controls.dart';

import 'support/appliance_test_support.dart';

/// The device page has to answer one question before any other: is this thing
/// recording right now? These tests hold it to that.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  Future<ApplianceRig> open(WidgetTester tester, Map<String, Object?> status) async {
    final rig = ApplianceRig();
    addTearDown(rig.controller.dispose);
    rig.transport.statusOnRead = cborEncodeStatus(status);
    await rig.connect();
    await tester.pumpWidget(wrap(ApplianceSheet(controller: rig.controller)));
    await tester.pump();
    return rig;
  }

  testWidgets('the device page reports state without a second record control', (
    tester,
  ) async {
    // This page used to carry a full recording stage of its own — orb, clock
    // and record button — which the Record screen already owns. Two controls
    // meant two readings of the same state, and they drifted apart: one said
    // recording while the other said ready. Recording lives in one place now.
    await open(tester, applianceStatusPayload());

    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(RecordButton), findsNothing);
    expect(find.byType(CaptureOrb), findsNothing);
  });

  testWidgets('a recording device says so, and for how long', (tester) async {
    await open(
      tester,
      applianceStatusPayload(const <String, Object?>{'st': 'recording', 'el': 843000}),
    );

    expect(find.text('RECORDING'), findsOneWidget);
    // The elapsed time reads as a clock, not as a field.
    expect(find.text('14:03'), findsOneWidget);
    expect(find.byType(RecordButton), findsNothing);
  });

  testWidgets('the current output and microphone are named in plain words', (tester) async {
    await open(
      tester,
      applianceStatusPayload(const <String, Object?>{
        'out': 'headphones',
        'hc': true,
        'hn': 'Sony WH-1000XM5',
        'mic': 'headset',
      }),
    );

    // Output and microphone are two labelled choices now, not a row of pills
    // above one chooser that repeated "Speaker" twice.
    expect(find.text('Plays out of'), findsOneWidget);
    expect(find.text('Records with'), findsOneWidget);
    expect(find.text('Sony WH-1000XM5'), findsWidgets);
    expect(find.text('Headset'), findsOneWidget);
  });

  testWidgets('with no headphones the speaker is the only choice offered', (tester) async {
    await open(tester, applianceStatusPayload());

    expect(find.text('Its own microphones'), findsOneWidget);

    // Both choices refuse the headset when there is none, rather than offering
    // an option that can only fail.
    final microphone = tester.widget<SegmentedButton<ApplianceMicSource>>(
      find.byType(SegmentedButton<ApplianceMicSource>),
    );
    expect(
      microphone.segments
          .firstWhere((s) => s.value == ApplianceMicSource.headset)
          .enabled,
      isFalse,
    );

    final segmented = tester.widget<SegmentedButton<ApplianceOutput>>(
      find.byType(SegmentedButton<ApplianceOutput>),
    );
    final headphones = segmented.segments.firstWhere(
      (ButtonSegment<ApplianceOutput> s) => s.value == ApplianceOutput.headphones,
    );
    expect(headphones.enabled, isFalse);
  });

  testWidgets('out of range, the device page still says what it last knew', (tester) async {
    final rig = await open(
      tester,
      applianceStatusPayload(const <String, Object?>{'st': 'recording', 'el': 60000}),
    );

    rig.transport.dropConnection();
    await tester.pump();
    await tester.pump();

    expect(find.text('OUT OF RANGE'), findsOneWidget);
    expect(find.text('RECORDING'), findsOneWidget);
    expect(
      find.textContaining('A recording already running is not affected'),
      findsOneWidget,
    );
  });

  testWidgets('an error from the appliance is shown as a sentence', (tester) async {
    final rig = await open(tester, applianceStatusPayload());

    rig.transport.pushStatus(
      applianceStatusPayload(const <String, Object?>{
        'pc': 12,
        'net': false,
        'err': 'No network yet — 12 recordings are waiting.',
      }),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No network yet — 12 recordings are waiting.'), findsOneWidget);
  });

  testWidgets('a connected headset is listed even when no scan has run', (tester) async {
    await open(
      tester,
      applianceStatusPayload(const <String, Object?>{
        'hc': true,
        'hn': 'Sony WH-1000XM5',
        'hb': 72,
      }),
    );

    // The sheet is a ListView, so anything below the fold is not built until it
    // is scrolled to. Scrolling here asserts what the section contains, not
    // where it happens to sit on an 800x600 test surface.
    await tester.scrollUntilVisible(find.text('HEADPHONES'), 200);
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });
}
