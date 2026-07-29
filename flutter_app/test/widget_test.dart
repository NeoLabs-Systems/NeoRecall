import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_auth.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_shell.dart';
import 'package:neorecall/main_theme.dart';

void main() {
  testWidgets('NeoRecall theme builds MaterialApp shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        darkTheme: buildNeoRecallTheme(Brightness.dark),
        home: const Scaffold(body: Text('NeoRecall')),
      ),
    );
    expect(find.text('NeoRecall'), findsOneWidget);
  });

  for (final size in <Size>[const Size(390, 844), const Size(1180, 780)]) {
    testWidgets('every app screen lays out at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = NeoRecallController()
        ..username = 'UI smoke test'
        ..error =
            "NoSuchMethodError: method not found: 'then' (a.then is not a function)";
      addTearDown(controller.dispose);

      for (final page in RecallPage.values) {
        controller.page = page;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNeoRecallTheme(Brightness.light),
            home: NeoRecallShell(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: '${page.name} overflowed or threw at ${size.width}px',
        );
      }
    });
  }

  testWidgets('account registration remains reachable in a short viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: NeoRecallAuthScreen(controller: controller),
      ),
    );

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create account'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
