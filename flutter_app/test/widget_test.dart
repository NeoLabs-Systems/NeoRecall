import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neorecall/main.dart';
import 'package:neorecall/main_auth.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_memories.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_shell.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/main_timeline.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/models/memory.dart';
import 'package:neorecall/src/models/timeline_moment.dart';
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

  test('same-origin web backend restores its persisted session', () {
    expect(canRestoreSessionForBackend(web: true, baseUrl: ''), isTrue);
    expect(canRestoreSessionForBackend(web: false, baseUrl: ''), isFalse);
    expect(
      canRestoreSessionForBackend(
        web: false,
        baseUrl: 'https://recall.example',
      ),
      isTrue,
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

  testWidgets('desktop exposes Bluetooth in the shared capture flow', (
    tester,
  ) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: Scaffold(body: RecordScreen(controller: controller)),
      ),
    );

    expect(find.text('Wearable'), findsOneWidget);
    await tester.ensureVisible(find.text('Wearable'));
    await tester.tap(find.text('Wearable'));
    await tester.pump();
    expect(find.text('Scan for wearables'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile without a saved device exposes Bluetooth setup and microphone fallback',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final controller = NeoRecallController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildNeoRecallTheme(Brightness.light),
            home: Scaffold(body: RecordScreen(controller: controller)),
          ),
        );

        expect(find.text('Wearable'), findsOneWidget);
        expect(find.text('Phone microphone'), findsOneWidget);

        // The page opens on the phone, which needs nothing set up, so the
        // wearable's controls are behind its own option rather than shown to
        // everybody who has no wearable.
        expect(find.text('Scan for wearables'), findsNothing);

        final Finder wearable = find.text('Wearable');
        await tester.ensureVisible(wearable);
        await tester.pumpAndSettle();
        await tester.tap(wearable);
        await tester.pumpAndSettle();

        expect(find.text('Scan for wearables'), findsOneWidget);
        expect(
          find.text(
            'Connect a supported streaming wearable before starting this source.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

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

  // 320 is the narrowest phone the app supports; the bin was the first icon
  // to spill off the end of the row this toolbar used to be.
  for (final width in <double>[320, 360, 390, 430]) {
    testWidgets(
      'memory selection actions wrap without hiding the delete button at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = NeoRecallController()
          ..memories = <RecallMemory>[
            RecallMemory(
              id: 'memory-1',
              type: 'conversation',
              title: 'First memory',
              summary: 'First summary',
              emoji: '💬',
              importance: 5,
              startedAt: DateTime.utc(2026, 8, 25, 10),
            ),
          ];
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildNeoRecallTheme(Brightness.light),
            home: Scaffold(body: MemoriesScreen(controller: controller)),
          ),
        );
        await tester.tap(find.text('Select'));
        await tester.pump();
        await tester.tap(find.text('First memory'));
        await tester.pump();

        expect(find.byTooltip('Delete'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
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
    expect(find.text('Account devices'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.text('Settings areas'), findsOneWidget);
    expect(find.text('Account devices'), findsOneWidget);

    await tester.tap(find.text('Account devices'));
    await tester.pump();
    expect(find.text('No devices yet'), findsOneWidget);
    // An empty list has to offer the way out of being empty. Pointing at another
    // screen instead is how somebody ends up unable to find their own hardware.
    expect(find.text('Add a NeoRecall Desk'), findsOneWidget);
    expect(find.textContaining('Backend URL'), findsNothing);
    expect(find.text('Client'), findsNothing);
  });

  testWidgets('shared shell keeps the canonical web section structure', (
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
        home: NeoRecallShell(controller: controller),
      ),
    );

    for (final label in <String>[
      'Record',
      'Timeline',
      'Memories',
      'Search',
      'Speakers',
      'Sources',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('New recording'), findsNothing);
  });

  testWidgets('a timeline moment compacts, expands and offers a rewrite', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 7, 29, 12);
    TranscriptSegment line(String id, String text, int minutesAgo) =>
        TranscriptSegment(
          id: id,
          text: text,
          startedAt: now.subtract(Duration(minutes: minutesAgo)),
          endedAt: now.subtract(Duration(minutes: minutesAgo - 1)),
          speaker: 'Alex',
          conversationId: 'conversation-a',
        );
    final controller = NeoRecallController()
      ..moments = <TimelineMoment>[
        TimelineMoment(
          id: 'conversation-a',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(minutes: 12)),
          endedAt: now.subtract(const Duration(minutes: 8)),
          state: 'consolidated',
          titleEn: 'Irrigation planning',
          summaryEn: 'The team agreed the next milestone.',
          topics: const <String>['Project'],
          segmentCount: 3,
          segments: <TranscriptSegment>[
            line('a1', 'First compact line', 12),
            line('a2', 'Second compact line', 10),
            line('a3', 'Hidden until expanded', 9),
          ],
        ),
        TimelineMoment(
          id: 'conversation-b',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(minutes: 6)),
          endedAt: now.subtract(const Duration(minutes: 5)),
          state: 'closed',
          topics: const <String>[],
          segmentCount: 1,
          segments: <TranscriptSegment>[
            TranscriptSegment(
              id: 'b1',
              text: 'A separate recent moment',
              startedAt: now.subtract(const Duration(minutes: 6)),
              endedAt: now.subtract(const Duration(minutes: 5)),
              speaker: 'Morgan',
              conversationId: 'conversation-b',
            ),
          ],
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: TimelineScreen(controller: controller),
      ),
    );

    expect(find.text('2 moments · 4 segments'), findsOneWidget);
    expect(find.text('1 more line'), findsOneWidget);
    expect(find.textContaining('Hidden until expanded'), findsNothing);
    // A conversation with no write-up yet says so rather than looking finished.
    expect(find.text('Summary on the way'), findsOneWidget);
    // The rewrite is an action on an open moment, not clutter on a closed one.
    expect(find.text('Write up again'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1 more line'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hidden until expanded'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    expect(find.text('Write up again'), findsOneWidget);
  });

  testWidgets('account registration remains reachable in a short viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController(
      api: NeoRecallApiClient(baseUrl: 'http://localhost:4500'),
    );
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

  testWidgets('Android opens backend setup when no URL was built in', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: NeoRecallAuthScreen(controller: controller),
      ),
    );

    expect(find.text('WELCOME TO NEORECALL'), findsOneWidget);
    expect(find.text('Connect NeoRecall'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Connect to this server'), findsOneWidget);
    expect(find.text('Back to sign in'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android app leaves the loader for backend setup', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'accountId': 'cached-account',
      'username': 'cached-user',
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'sessionToken': 'cached-token',
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(const NeoRecallApp());
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Connect NeoRecall').evaluate().isNotEmpty) break;
    }

    expect(find.text('Loading NeoRecall'), findsNothing);
    expect(find.text('Connect NeoRecall'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
}
