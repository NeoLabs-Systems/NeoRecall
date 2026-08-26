import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_floating.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/desktop/meeting_detector.dart';
import 'package:neorecall/src/desktop/window_coordinator.dart';

void main() {
  test('native floating geometry stays compact', () {
    expect(DesktopWindowCoordinator.floatingSize, const Size(360, 84));
    expect(
      DesktopWindowCoordinator.floatingMinimumSize,
      DesktopWindowCoordinator.floatingSize,
    );
    expect(
      DesktopWindowCoordinator.floatingSize.width,
      lessThan(DesktopWindowCoordinator.librarySize.width / 3),
    );
  });

  testWidgets('floating capture surfaces a detected meeting without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 84);
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
          onConsentVisibilityChanged: (visible) async {
            tester.view.physicalSize = visible
                ? const Size(380, 280)
                : const Size(360, 84);
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Zoom detected'), findsOneWidget);
    expect(find.byTooltip('Record'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Record'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Before you record'), findsOneWidget);
    expect(find.text('I understand'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
