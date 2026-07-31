import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';

/// Diagnostics moved out of Settings and behind an unadvertised long-press in
/// the Bluetooth setup area: reachable for support, invisible in normal use.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: buildNeoRecallTheme(Brightness.light),
    home: Scaffold(body: child),
  );

  testWidgets('a long-press on the device status line opens diagnostics', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));

    await tester.tap(find.text('Bluetooth device'));
    await tester.pump();

    final statusLine = find.text(
      'Connect a supported Bluetooth device before starting this source.',
    );
    expect(statusLine, findsOneWidget);
    // Nothing on screen advertises diagnostics before the gesture.
    expect(find.text('Device & sync diagnostics'), findsNothing);

    await tester.longPress(statusLine);
    await tester.pumpAndSettle();

    expect(find.text('Device & sync diagnostics'), findsOneWidget);
    expect(find.text('Copy full report'), findsOneWidget);
    expect(find.text('Clear log'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a plain tap on the status line does not open diagnostics', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));

    await tester.tap(find.text('Bluetooth device'));
    await tester.pump();
    await tester.tap(
      find.text(
        'Connect a supported Bluetooth device before starting this source.',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Device & sync diagnostics'), findsNothing);
  });

  testWidgets('settings no longer carries a diagnostics/log section', (
    tester,
  ) async {
    final controller = NeoRecallController()..username = 'Neo';
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(SettingsScreen(controller: controller)));
    await tester.pump();

    expect(find.text('SUPPORT'), findsNothing);
    expect(find.text('Device & sync diagnostics'), findsNothing);
    expect(find.text('Copy full report'), findsNothing);
    expect(find.text('Clear log'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
