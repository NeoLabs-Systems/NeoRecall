import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neorecall/main.dart';
import 'package:neorecall/main_auth.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_local_install.dart';
import 'package:neorecall/main_memories.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_shell.dart';
import 'package:neorecall/main_speakers.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/main_timeline.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/models/memory.dart';
import 'package:neorecall/src/models/speaker.dart';
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

  testWidgets('the source sheet is where a wearable is chosen', (tester) async {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: Scaffold(body: RecordScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    // The page itself says only what it is recording from; the picker is not
    // laid out on it.
    expect(find.text('Wearable'), findsNothing);
    expect(find.text('Scan for wearables'), findsNothing);

    await tester.tap(find.text('change'));
    await tester.pumpAndSettle();

    expect(find.text('Record from'), findsOneWidget);
    expect(find.text('Wearable'), findsOneWidget);
    expect(find.text('Import an audio file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a wearable with nothing paired offers a scan instead of a selection',
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
        await tester.pumpAndSettle();

        // The phone is what the page starts on, because it always works.
        expect(find.text('Phone microphone'), findsOneWidget);

        await tester.tap(find.text('change'));
        await tester.pumpAndSettle();

        // Unavailable sources stay visible and dimmed, carrying the action that
        // would make them available, rather than disappearing.
        expect(find.text('No wearable connected yet'), findsOneWidget);
        expect(find.text('Scan'), findsOneWidget);
        expect(find.text('Not set up'), findsOneWidget);
        expect(find.text('Set up'), findsOneWidget);
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

  testWidgets('speaker selection can select every visible speaker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController()
      ..speakers = const <RecallSpeaker>[
        RecallSpeaker(
          id: 'speaker-1',
          name: 'First speaker',
          occurrences: 3,
          matchingEnabled: true,
        ),
        RecallSpeaker(
          id: 'speaker-2',
          name: 'Second speaker',
          occurrences: 2,
          matchingEnabled: true,
        ),
        RecallSpeaker(
          id: 'speaker-3',
          name: 'Third speaker',
          occurrences: 1,
          matchingEnabled: true,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: Scaffold(body: SpeakersScreen(controller: controller)),
      ),
    );
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select all speakers'));
    await tester.pump();

    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byTooltip('All speakers selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    // Let the shell's page cross-fade finish: while it runs, the outgoing and
    // incoming screens are both mounted and a tap lands on neither reliably.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
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

  testWidgets('the phone tab bar navigates and lights the right tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = NeoRecallController()..username = 'Neo';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.dark),
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => NeoRecallShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // A bar, not a drawer: the whole product is visible without a hamburger.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );

    await tester.tap(find.text('Library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.page, RecallPage.library);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );

    // Library remembers which list it was on, so returning to the tab does not
    // snap back to Moments.
    controller.selectLibraryTab(LibraryTab.speakers);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Ask'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.page, RecallPage.search);
    await tester.tap(find.text('Library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.libraryTab, LibraryTab.speakers);

    // Sources has no tab of its own; it belongs to the tab it is reached from.
    controller.selectPage(RecallPage.sources);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(tester.takeException(), isNull);
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

    // Four groups, not six flat entries. Capture is open because Record is the
    // page on screen; the rest stay collapsed until asked for.
    for (final label in <String>['Capture', 'Library', 'Ask', 'Settings']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    // Library's children are behind its own group row.
    expect(find.text('Memories'), findsNothing);
    expect(find.text('Speakers'), findsNothing);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Memories'), findsWidgets);
    expect(find.text('Speakers'), findsWidgets);
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

  testWidgets('moment selection can select every visible moment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 7, 29, 12);
    final controller = NeoRecallController()
      ..moments = <TimelineMoment>[
        TimelineMoment(
          id: 'conversation-a',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(minutes: 12)),
          endedAt: now.subtract(const Duration(minutes: 8)),
          state: 'consolidated',
          titleEn: 'First moment',
          topics: const <String>[],
          segmentCount: 1,
          segments: const <TranscriptSegment>[],
        ),
        TimelineMoment(
          id: 'conversation-b',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(minutes: 6)),
          endedAt: now.subtract(const Duration(minutes: 5)),
          state: 'closed',
          titleEn: 'Second moment',
          topics: const <String>[],
          segmentCount: 1,
          segments: const <TranscriptSegment>[],
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: Scaffold(body: TimelineScreen(controller: controller)),
      ),
    );
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select all moments'));
    await tester.pump();

    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byTooltip('All moments selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiping a moment asks to delete it', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 7, 29, 12);
    final controller = NeoRecallController()
      ..moments = <TimelineMoment>[
        TimelineMoment(
          id: 'conversation-a',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(minutes: 12)),
          endedAt: now.subtract(const Duration(minutes: 8)),
          state: 'consolidated',
          titleEn: 'Irrigation planning',
          topics: const <String>[],
          segmentCount: 1,
          segments: const <TranscriptSegment>[],
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: Scaffold(body: TimelineScreen(controller: controller)),
      ),
    );
    await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('Delete this moment?'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('desktop backend setup offers the local installer', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = NeoRecallController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeoRecallTheme(Brightness.light),
        home: NeoRecallAuthScreen(controller: controller),
      ),
    );

    expect(find.text('Set up or connect NeoRecall'), findsOneWidget);
    final install = find.text('Set up NeoRecall on this computer');
    expect(install, findsOneWidget);

    // The install view probes for git/node/npm on the real host, so the tap and
    // the frame it schedules run outside the fake-async zone.
    await tester.runAsync(() async {
      await tester.tap(install);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });

    expect(find.byType(LocalInstallView), findsOneWidget);
    expect(find.text('LOCAL SETUP'), findsOneWidget);
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
