import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/devices/appliance/ui/appliance_capture_section.dart';

import 'support/appliance_test_support.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('explains Desk without presenting it as another live source', (
    tester,
  ) async {
    final rig = ApplianceRig();
    addTearDown(rig.controller.dispose);
    var setupRequested = false;

    await tester.pumpWidget(
      wrap(
        ApplianceCaptureSection(
          controller: rig.controller,
          devices: const <Map<String, dynamic>>[],
          onAdd: () async {
            setupRequested = true;
          },
        ),
      ),
    );

    expect(find.text('Set up a Desk recorder'), findsOneWidget);
    expect(
      find.textContaining('No server address or access key to copy'),
      findsOneWidget,
    );

    // The section no longer carries a heading, a strapline or a footnote of its
    // own. It sits inside the "where to record" card, and repeating that frame
    // is what made the Desk read as a second product bolted onto the page.
    expect(find.text('NEORECALL DESK'), findsNothing);
    expect(
      find.textContaining('Bluetooth is used only to set up and control'),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('neorecall-desk-introduction')),
    );
    expect(setupRequested, isTrue);
  });

  testWidgets('shows the same live Desk status used by device management', (
    tester,
  ) async {
    final rig = ApplianceRig();
    addTearDown(rig.controller.dispose);
    rig.transport.statusOnRead = cborEncodeStatus(
      applianceStatusPayload(const <String, Object?>{
        'did': 'device-1',
        'st': 'recording',
        'el': 843000,
      }),
    );
    await rig.connect();

    await tester.pumpWidget(
      wrap(
        ApplianceCaptureSection(
          controller: rig.controller,
          devices: const <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'device-1',
              'name': 'Desk in the study',
              'kind': 'appliance',
              'revoked_at': null,
            },
          ],
          onAdd: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Desk in the study'), findsOneWidget);
    expect(find.text('Recording · 14:03'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}
