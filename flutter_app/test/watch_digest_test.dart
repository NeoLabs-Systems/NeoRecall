import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/background/home_widget_snapshot.dart';
import 'package:neorecall/src/models/timeline_moment.dart';
import 'package:neorecall/src/models/transcript.dart';
import 'package:neorecall/src/watch/watch_digest.dart';
import 'package:neorecall/src/watch/watch_digest_publisher.dart';
import 'dart:ui';
import 'package:neorecall/l10n/gen/app_l10n.dart';

// The English translations, for the parts of the app that produce user-facing
// text away from any widget tree.
final AppL10n testStrings = lookupAppL10n(const Locale('en'));

void main() {
  const publisher = WatchDigestPublisher();
  final now = DateTime(2026, 9, 6, 15, 20);

  HomeWidgetSnapshot snapshot({
    int memories = 2,
    int highlights = 1,
    String? dayInReview,
  }) => HomeWidgetSnapshot(
    signedIn: true,
    capture: const HomeWidgetCapture(
      phase: 'recording',
      title: 'Recording',
      detail: 'Microphone is open',
      recording: true,
      pendingSeconds: 42,
    ),
    today: const HomeWidgetToday(
      talkSeconds: 3720,
      memories: 4,
      highlights: 6,
      openTasks: 3,
      dueToday: 1,
      overdue: 2,
    ),
    dayInReview: dayInReview,
    memories: <HomeWidgetMemory>[
      for (var index = 0; index < memories; index += 1)
        HomeWidgetMemory(
          id: 'memory-$index',
          emoji: '💬',
          title: 'Memory $index',
          summary: 'Summary $index',
          type: 'conversation',
          typeLabel: 'Conversation',
          atMillis: now.millisecondsSinceEpoch - index * 60000,
          highlightCount: index,
        ),
    ],
    highlights: <HomeWidgetHighlight>[
      for (var index = 0; index < highlights; index += 1)
        HomeWidgetHighlight(
          id: 'highlight-$index',
          kind: 'task',
          emoji: '✨',
          text: 'Do the thing $index',
          importance: 7,
          dueMillis: now.millisecondsSinceEpoch,
          dueToday: true,
        ),
    ],
  );

  TranscriptSegment segment(int index, {String text = 'Line'}) =>
      TranscriptSegment(
        id: 'segment-$index',
        text: '$text $index',
        startedAt: now.subtract(Duration(minutes: 120 - index)),
        endedAt: now.subtract(Duration(minutes: 119 - index)),
        speaker: index.isEven ? 'Frank' : 'Ada',
      );

  TimelineMoment moment({
    int segments = 4,
    int? segmentCount,
    String state = 'closed',
    String? title = 'Sprint review',
    String? summary = 'The team agreed to ship on Thursday.',
  }) => TimelineMoment(
    id: 'conversation-1',
    kind: 'conversation',
    startedAt: now.subtract(const Duration(hours: 2)),
    endedAt: now.subtract(const Duration(hours: 1)),
    state: state,
    segmentCount: segmentCount ?? segments,
    segments: <TranscriptSegment>[
      for (var index = 0; index < segments; index += 1) segment(index),
    ],
    topics: const <String>['release', 'staffing', 'budget', 'travel'],
    titleEn: title,
    summaryEn: summary,
  );

  test('signed-out phones send a digest that says so and nothing else', () {
    final digest = publisher.build(
      snapshot: HomeWidgetSnapshot.signedOut(testStrings),
      now: now,
    );
    expect(digest.signedIn, isFalse);
    expect(digest.moment, isNull);
    expect(digest.memories, isEmpty);
    final decoded = jsonDecode(digest.encode()) as Map<String, dynamic>;
    expect(decoded['signedIn'], isFalse);
  });

  test('the digest inherits the widget snapshot rather than reshaping it', () {
    final digest = publisher.build(
      snapshot: snapshot(dayInReview: 'A long day of interviews.'),
      now: now,
    );
    expect(digest.today.talkSeconds, 3720);
    expect(digest.today.overdue, 2);
    expect(digest.dayInReview, 'A long day of interviews.');
    expect(digest.capture.recording, isTrue);
    expect(digest.memories.first.title, 'Memory 0');
    expect(digest.highlights.first.dueToday, isTrue);
  });

  test('a transcript is kept from its most recent end', () {
    final digest = publisher.build(
      snapshot: snapshot(),
      now: now,
      moment: moment(segments: WatchDigest.maxTranscriptLines + 12),
    );
    final lines = digest.moment!.lines;
    expect(lines, hasLength(WatchDigest.maxTranscriptLines));
    expect(lines.last.text, endsWith('${WatchDigest.maxTranscriptLines + 11}'));
    expect(lines.first.text, endsWith('12'));
    expect(lines.first.speaker, isNotNull);
  });

  test(
    'the count of what was left behind comes from the whole conversation',
    () {
      final digest = publisher.build(
        snapshot: snapshot(),
        now: now,
        moment: moment(segments: 4, segmentCount: 130),
      );
      expect(digest.moment!.totalLines, 130);
      expect(digest.moment!.lines, hasLength(4));
    },
  );

  test(
    'an already-opened transcript is preferred over the timeline preview',
    () {
      final digest = publisher.build(
        snapshot: snapshot(),
        now: now,
        moment: moment(segments: 2, segmentCount: 9),
        fullTranscript: <TranscriptSegment>[
          for (var index = 0; index < 9; index += 1)
            segment(index, text: 'Full'),
        ],
      );
      expect(digest.moment!.lines, hasLength(9));
      expect(digest.moment!.lines.first.text, startsWith('Full'));
    },
  );

  test('an open conversation is marked live', () {
    final digest = publisher.build(
      snapshot: snapshot(),
      now: now,
      moment: moment(state: 'open'),
    );
    expect(digest.moment!.live, isTrue);
  });

  test(
    'a conversation with no write-up yet says it is still being written',
    () {
      final digest = publisher.build(
        snapshot: snapshot(),
        now: now,
        moment: moment(title: null, summary: null),
      );
      expect(digest.moment!.awaitingWriteUp, isTrue);
      expect(digest.moment!.title, isNull);
    },
  );

  test('only three topics survive, because that is what one row holds', () {
    final digest = publisher.build(
      snapshot: snapshot(),
      now: now,
      moment: moment(),
    );
    expect(digest.moment!.topics, hasLength(3));
  });

  test('long text is clipped on a word boundary with an ellipsis', () {
    final digest = publisher.build(
      snapshot: snapshot(),
      now: now,
      moment: moment(summary: 'word ' * 400),
    );
    final summary = digest.moment!.summary!;
    expect(summary.length, lessThanOrEqualTo(WatchDigest.maxSummaryCharacters));
    expect(summary, endsWith('…'));
  });

  test(
    'an oversized digest is trimmed until it fits the Data Layer budget',
    () {
      final digest = publisher.build(
        snapshot: snapshot(memories: 8, highlights: 8),
        now: now,
        moment: TimelineMoment(
          id: 'conversation-2',
          kind: 'conversation',
          startedAt: now.subtract(const Duration(hours: 3)),
          endedAt: now,
          state: 'closed',
          segmentCount: 400,
          segments: <TranscriptSegment>[
            for (var index = 0; index < 400; index += 1)
              TranscriptSegment(
                id: 'long-$index',
                // Every line is at its own cap, so 40 of them alone exceed the
                // payload budget and trimming has to actually happen.
                text: 'x' * WatchDigest.maxLineCharacters,
                startedAt: now.subtract(Duration(seconds: 400 - index)),
                endedAt: now.subtract(Duration(seconds: 399 - index)),
                speaker: 'Someone with a fairly long display name',
              ),
          ],
          topics: const <String>[],
          titleEn: 'Long one',
          summaryEn: 'x' * WatchDigest.maxSummaryCharacters,
        ),
      );
      final payload = digest.encode();
      expect(
        utf8.encode(payload).length,
        lessThanOrEqualTo(WatchDigest.maxPayloadBytes),
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      // Trimming gives up transcript lines before it gives up the write-up.
      expect(decoded['moment']['title'], 'Long one');
      expect(decoded['moment']['totalLines'], 400);
    },
  );
}
