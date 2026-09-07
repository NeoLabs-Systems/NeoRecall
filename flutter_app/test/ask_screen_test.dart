import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:neorecall/main_ask.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/models/ask.dart';

Future<void> pumpAsk(
  WidgetTester tester,
  NeoRecallController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      theme: buildNeoRecallTheme(Brightness.dark),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (BuildContext context, _) =>
              AskScreen(controller: controller),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'an unanswered question shows the question and the thinking indicator',
    (tester) async {
      final controller = NeoRecallController();
      addTearDown(controller.dispose);
      controller.askTurns = <AskTurn>[
        AskTurn(question: 'What did I do today?'),
      ];
      await pumpAsk(tester, controller);
      await tester.pump();

      expect(find.text('What did I do today?'), findsOneWidget);
      expect(find.byType(AskThinkingIndicator), findsOneWidget);
      // Live animation: the frame must keep being scheduled, not settle.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AskThinkingIndicator), findsOneWidget);
    },
  );

  testWidgets('an answer replaces the indicator and ranks its sources', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    final turn = AskTurn(question: 'What did I promise Anna?')
      ..answer = 'You said you would send the corrected invoice before Friday.'
      ..considered = 2
      ..weakCount = 12
      ..sources = <AskSource>[
        const AskSource(
          kind: 'memory',
          title: 'Invoice correction for Anna',
          excerpt: 'Send it before Friday.',
          relevance: 0.91,
        ),
        const AskSource(
          kind: 'segment',
          excerpt: 'Anna, warte kurz.',
          relevance: 0.31,
        ),
      ];
    controller.askTurns = <AskTurn>[turn];
    await pumpAsk(tester, controller);
    await tester.pumpAndSettle();

    expect(find.byType(AskThinkingIndicator), findsNothing);
    expect(find.textContaining('corrected invoice'), findsOneWidget);
    expect(find.textContaining('12 weaker matches'), findsOneWidget);

    // The evidence is folded away until it is asked for; the count is not.
    expect(find.text('SHOW SOURCES'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Invoice correction for Anna'), findsNothing);

    await tester.tap(find.text('SHOW SOURCES'));
    await tester.pumpAndSettle();
    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('Invoice correction for Anna'), findsOneWidget);
    // Every source states how strong a match it was, so a weak one is not
    // dressed as evidence.
    expect(find.text('0.91'), findsOneWidget);
    expect(find.text('0.31'), findsOneWidget);

    await tester.tap(find.text('SOURCES'));
    await tester.pumpAndSettle();
    expect(find.text('Invoice correction for Anna'), findsNothing);
  });

  testWidgets(
    'a failed question keeps the conversation and says what happened',
    (tester) async {
      final controller = NeoRecallController();
      addTearDown(controller.dispose);
      controller.askTurns = <AskTurn>[
        AskTurn(question: 'Who was at the standup?')
          ..error = 'That question could not be answered just now.',
      ];
      await pumpAsk(tester, controller);
      await tester.pumpAndSettle();

      expect(find.text('Who was at the standup?'), findsOneWidget);
      expect(find.textContaining('could not be answered'), findsOneWidget);
    },
  );

  testWidgets(
    'a question read as a period says which period, and in whose clock',
    (tester) async {
      final controller = NeoRecallController();
      addTearDown(controller.dispose);
      controller.askTurns = <AskTurn>[
        AskTurn(question: 'What did I do today?')
          ..answer = 'Nothing is recorded for today.'
          ..considered = 0
          ..timezone = 'UTC'
          ..periodFrom = DateTime(2026, 7, 13)
          ..periodTo = DateTime(2026, 7, 14),
      ];
      await pumpAsk(tester, controller);
      await tester.pumpAndSettle();

      // A whole day reads as one date, and the account timezone is on screen so a
      // day read in the wrong clock is visible rather than merely wrong.
      expect(find.textContaining('UTC'), findsOneWidget);
      expect(find.textContaining('NOTHING RECORDED'), findsOneWidget);
    },
  );
}
