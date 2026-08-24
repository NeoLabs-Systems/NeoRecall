import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_floating.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/desktop/meeting_detector.dart';

void main() {
  testWidgets('floating capture surfaces a detected meeting without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(470, 238);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: FloatingCaptureWindow(
          controller: controller,
          meetingActivity: MeetingActivity(
            type: MeetingActivityType.started,
            application: 'Zoom',
            detectedAt: DateTime(2026, 8, 24),
          ),
          onOpenLibrary: () {},
          onHide: () {},
          onDismissMeeting: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Zoom meeting detected'), findsOneWidget);
    expect(find.text('Record meeting'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Record meeting'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Before you record'), findsOneWidget);
    expect(find.text('I understand'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
