import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/memories/transcript_excerpts.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

Widget wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Map<String, dynamic> source(String startedAt, String endedAt, String text) =>
    <String, dynamic>{
      'started_at': startedAt,
      'ended_at': endedAt,
      'text': text,
    };

void main() {
  testWidgets('speech that runs on is one passage, not one card per sentence', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        TranscriptExcerpts(
          sources: <Map<String, dynamic>>[
            source(
              '2026-08-01T10:00:00.000Z',
              '2026-08-01T10:00:05.000Z',
              'Wir fangen mit dem Zeitplan an.',
            ),
            source(
              '2026-08-01T10:00:06.000Z',
              '2026-08-01T10:00:12.000Z',
              'Der Termin bleibt im September.',
            ),
            // Four minutes later: a real break, so a new passage and a
            // timestamp that tells the reader something.
            source(
              '2026-08-01T10:04:00.000Z',
              '2026-08-01T10:04:08.000Z',
              'Danach die Aufgaben im Team.',
            ),
          ],
        ),
      ),
    );

    expect(
      find.text(
        'Wir fangen mit dem Zeitplan an. Der Termin bleibt im September.',
      ),
      findsOneWidget,
    );
    expect(find.text('Danach die Aufgaben im Team.'), findsOneWidget);
    // Two passages fit under the cap, so there is nothing to expand.
    expect(
      find.byKey(const ValueKey<String>('transcript-excerpts-toggle')),
      findsNothing,
    );
  });

  testWidgets(
    'only the first passages are shown until the reader asks for the rest',
    (tester) async {
      final sources = <Map<String, dynamic>>[
        for (var minute = 0; minute < 6; minute += 1)
          source(
            '2026-08-01T10:${(minute * 5).toString().padLeft(2, '0')}:00.000Z',
            '2026-08-01T10:${(minute * 5).toString().padLeft(2, '0')}:10.000Z',
            'Abschnitt $minute.',
          ),
      ];
      await tester.pumpWidget(wrap(TranscriptExcerpts(sources: sources)));

      expect(find.text('Abschnitt 0.'), findsOneWidget);
      expect(find.text('Abschnitt 2.'), findsOneWidget);
      expect(find.text('Abschnitt 3.'), findsNothing);
      expect(find.text('3 more passages'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('transcript-excerpts-toggle')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Abschnitt 5.'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    },
  );

  testWidgets('a memory with no linked transcript says so', (tester) async {
    await tester.pumpWidget(
      wrap(const TranscriptExcerpts(sources: <Map<String, dynamic>>[])),
    );
    expect(
      find.text('No transcript excerpts are linked to this memory.'),
      findsOneWidget,
    );
  });

  testWidgets('rows without usable text or timestamps do not break the list', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        TranscriptExcerpts(
          sources: <Map<String, dynamic>>[
            <String, dynamic>{
              'started_at': null,
              'ended_at': null,
              'text': 'Ohne Zeitstempel.',
            },
            <String, dynamic>{'started_at': 'not a date', 'text': '   '},
            source(
              '2026-08-01T10:30:00.000Z',
              '2026-08-01T10:30:05.000Z',
              'Mit Zeitstempel.',
            ),
          ],
        ),
      ),
    );
    expect(find.text('Ohne Zeitstempel.'), findsOneWidget);
    expect(find.text('Mit Zeitstempel.'), findsOneWidget);
  });
}
