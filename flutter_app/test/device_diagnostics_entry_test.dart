import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_settings.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/record/record_sheets.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

/// Diagnostics are out of Settings. They sit behind an unadvertised long-press
/// on the device chip, and as an explicit row inside the device sheet once a
/// device exists: reachable for support, invisible in normal use.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    theme: buildNeoRecallTheme(Brightness.light),
    home: Scaffold(body: child),
  );

  testWidgets('a long-press on the device chip opens diagnostics', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pumpAndSettle();

    final chip = find.byKey(DeviceChip.chipKey);
    expect(chip, findsOneWidget);
    expect(find.text('Add device'), findsOneWidget);
    // Nothing on screen advertises diagnostics before the gesture.
    expect(find.text('Device & sync diagnostics'), findsNothing);

    await tester.longPress(chip);
    await tester.pumpAndSettle();

    expect(find.text('Device & sync diagnostics'), findsOneWidget);
    expect(find.text('Copy full report'), findsOneWidget);
    expect(find.text('Clear log'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a plain tap on the device chip opens the device sheet, not '
      'diagnostics', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(DeviceChip.chipKey));
    await tester.pumpAndSettle();

    expect(find.text('Device & sync diagnostics'), findsNothing);
    expect(find.text('No device yet'), findsOneWidget);
  });

  testWidgets('the device sheet still offers diagnostics for support', (
    tester,
  ) async {
    final controller = NeoRecallController()
      ..preferredDeviceLabel = 'Pocket recorder';
    addTearDown(controller.dispose);
    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pumpAndSettle();

    // The chip, not the source line under the button — both name the device.
    await tester.tap(find.byKey(DeviceChip.chipKey));
    await tester.pumpAndSettle();

    final entry = find.text('Device and sync diagnostics');
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Device & sync diagnostics'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
