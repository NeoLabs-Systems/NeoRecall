import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_auth.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_shell.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/main_timeline.dart';
import 'package:neorecall/src/models/transcript.dart';

void main() {
  test('web system-audio selection reaches the browser capture request', () {
    expect(
      shouldRequestSystemAudio(selected: true, web: true, desktop: false),
      isTrue,
    );
    expect(
      shouldRequestSystemAudio(selected: true, web: false, desktop: false),
      isFalse,
    );
  });

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

  testWidgets('desktop navigation keeps devices inside settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController()..username = 'Neo';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => NeoRecallShell(controller: controller),
        ),
      ),
    );

    expect(find.text('Connected'), findsNothing);
    expect(find.text('Devices'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.text('Settings areas'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);

    await tester.tap(find.text('Devices'));
    await tester.pump();
    expect(find.text('No registered devices'), findsOneWidget);
    expect(find.textContaining('Backend URL'), findsNothing);
    expect(find.text('Client'), findsNothing);
  });

  testWidgets(
    'timeline compacts and expands interleaved conversation segments',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final controller = NeoRecallController()
        ..transcript = <TranscriptSegment>[
          TranscriptSegment(
            id: 'a1',
            text: 'First compact line',
            startedAt: now.subtract(const Duration(minutes: 12)),
            endedAt: now.subtract(const Duration(minutes: 11)),
            speaker: 'Alex',
            conversationId: 'conversation-a',
          ),
          TranscriptSegment(
            id: 'b1',
            text: 'A separate recent moment',
            startedAt: now.subtract(const Duration(minutes: 8)),
            endedAt: now.subtract(const Duration(minutes: 7)),
            speaker: 'Morgan',
            conversationId: 'conversation-b',
          ),
          TranscriptSegment(
            id: 'a2',
            text: 'Second compact line',
            startedAt: now.subtract(const Duration(minutes: 10)),
            endedAt: now.subtract(const Duration(minutes: 9)),
            speaker: 'Alex',
            conversationId: 'conversation-a',
          ),
          TranscriptSegment(
            id: 'a3',
            text: 'Hidden until expanded',
            startedAt: now.subtract(const Duration(minutes: 9)),
            endedAt: now.subtract(const Duration(minutes: 8)),
            speaker: 'Sam',
            conversationId: 'conversation-a',
          ),
        ]
        ..conversations = <Map<String, dynamic>>[
          <String, dynamic>{'id': 'conversation-a', 'state': 'complete'},
          <String, dynamic>{'id': 'conversation-b', 'state': 'complete'},
        ];
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildNeoRecallTheme(Brightness.light),
          home: TimelineScreen(controller: controller),
        ),
      );

      expect(find.text('2 moments · 4 segments'), findsOneWidget);
      expect(find.text('1 more segment'), findsOneWidget);
      expect(find.textContaining('Hidden until expanded'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('1 more segment'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hidden until expanded'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    },
  );

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

    expect(
      find.text('Private audio memory that stays under your control.'),
      findsNothing,
    );
    expect(find.text('Sign in'), findsNWidgets(2));

    await tester.tap(find.text('Need a new account? Register'));
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
