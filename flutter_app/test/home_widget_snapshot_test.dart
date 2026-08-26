import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/background/background_live_status.dart';
import 'package:neorecall/src/background/home_widget_publisher.dart';
import 'package:neorecall/src/background/home_widget_snapshot.dart';
import 'package:neorecall/src/models/memory.dart';

void main() {
  const publisher = HomeWidgetPublisher();
  final now = DateTime(2026, 8, 26, 14, 30);

  const idle = BackgroundLiveStatus(
    phase: BackgroundLivePhase.idle,
    title: 'NeoRecall is ready',
    detail: 'No recording or processing is active',
  );

  RecallMemory memory(
    String id, {
    required DateTime startedAt,
    Duration length = const Duration(minutes: 30),
    bool archived = false,
    bool pinned = false,
    String type = 'conversation',
  }) => RecallMemory(
    id: id,
    type: type,
    title: 'Memory $id',
    summary: 'Summary $id',
    emoji: '💬',
    importance: 5,
    startedAt: startedAt,
    endedAt: startedAt.add(length),
    archived: archived,
    pinned: pinned,
  );

  MiniMemory mini(
    String id, {
    String kind = 'task',
    String status = 'open',
    DateTime? dueAt,
    double importance = 5,
  }) => MiniMemory(
    id: id,
    kind: kind,
    text: 'Commitment $id',
    importance: importance,
    status: status,
    dueAt: dueAt,
    createdAt: now,
    timelineAt: now,
  );

  HomeWidgetSnapshot build({
    List<RecallMemory> memories = const <RecallMemory>[],
    List<MiniMemory> minis = const <MiniMemory>[],
    BackgroundLiveStatus status = idle,
    bool recording = false,
    DateTime? startedAt,
  }) => publisher.build(
    signedIn: true,
    status: status,
    recording: recording,
    recordingStartedAt: startedAt,
    memories: memories,
    miniMemories: minis,
    now: now,
  );

  test('a signed-out app publishes nothing about its owner', () {
    final snapshot = publisher.build(
      signedIn: false,
      status: idle,
      recording: false,
      recordingStartedAt: null,
      memories: <RecallMemory>[memory('a', startedAt: now)],
      miniMemories: <MiniMemory>[mini('t')],
      now: now,
    );

    expect(snapshot.signedIn, isFalse);
    expect(snapshot.memories, isEmpty);
    expect(snapshot.highlights, isEmpty);
    expect(snapshot.today.openTasks, 0);
  });

  test('today counts only what happened today, and only what finished', () {
    final snapshot = build(
      memories: <RecallMemory>[
        memory('today-1', startedAt: now.subtract(const Duration(hours: 2))),
        memory('today-2', startedAt: now.subtract(const Duration(hours: 1))),
        memory('yesterday', startedAt: now.subtract(const Duration(days: 1))),
        // Still open: it has no end, so it cannot contribute a duration.
        RecallMemory(
          id: 'live',
          type: 'conversation',
          title: 'Live',
          summary: '',
          emoji: '💬',
          importance: 5,
          startedAt: now.subtract(const Duration(minutes: 10)),
        ),
      ],
    );

    expect(snapshot.today.memories, 3);
    expect(snapshot.today.talkSeconds, const Duration(minutes: 60).inSeconds);
  });

  test('archived memories never reach a widget', () {
    final snapshot = build(
      memories: <RecallMemory>[
        memory('kept', startedAt: now),
        memory('gone', startedAt: now, archived: true),
      ],
    );

    expect(snapshot.memories.map((memory) => memory.id), <String>['kept']);
    expect(snapshot.today.memories, 1);
  });

  test('commitments are ordered overdue, then by due date, then importance', () {
    final snapshot = build(
      minis: <MiniMemory>[
        mini('later', dueAt: now.add(const Duration(days: 3))),
        mini('important', importance: 9),
        mini('soon', dueAt: now.add(const Duration(hours: 2))),
        mini('late', dueAt: now.subtract(const Duration(days: 1))),
        mini('unimportant', importance: 2),
        mini('done', status: 'completed'),
        mini('not-actionable', kind: 'fact'),
      ],
    );

    expect(
      snapshot.highlights.map((highlight) => highlight.id),
      <String>['late', 'soon', 'later', 'important', 'unimportant'],
    );
    expect(snapshot.highlights.first.overdue, isTrue);
    expect(snapshot.highlights[1].dueToday, isTrue);
    expect(snapshot.today.openTasks, 5);
    expect(snapshot.today.overdue, 1);
    expect(snapshot.today.dueToday, 1);
  });

  test('the trailing week ends on today and the week ahead starts on it', () {
    final snapshot = build(
      minis: <MiniMemory>[
        mini('late', dueAt: now.subtract(const Duration(days: 4))),
        mini('today', dueAt: now.add(const Duration(hours: 1))),
        mini('friday', dueAt: now.add(const Duration(days: 2))),
        mini('far', dueAt: now.add(const Duration(days: 40))),
      ],
    );

    expect(snapshot.today.days, hasLength(HomeWidgetToday.trailingDays));
    expect(snapshot.today.days.last.today, isTrue);
    expect(snapshot.today.days.where((day) => day.today), hasLength(1));

    final due = snapshot.today.dueDays;
    expect(due, hasLength(HomeWidgetToday.trailingDays));
    expect(due.first.today, isTrue);
    // Anything already late is counted against today, which is when it needs
    // dealing with — not against the day it was originally due.
    expect(due.first.due, 2);
    expect(due[2].due, 1);
    // A commitment due beyond the charted week is counted nowhere in it.
    expect(due.fold<int>(0, (sum, day) => sum + day.due), 3);
  });

  test('a recording publishes the start the elapsed timer counts from', () {
    final startedAt = now.subtract(const Duration(minutes: 12));
    final snapshot = build(
      recording: true,
      startedAt: startedAt,
      status: BackgroundLiveStatus(
        phase: BackgroundLivePhase.recording,
        title: 'Recording from Phone microphone',
        detail: 'Recording safely to this device',
        recordingStartedAt: startedAt,
        pendingAudioSeconds: 90,
      ),
    );

    expect(snapshot.capture.recording, isTrue);
    expect(snapshot.capture.phase, 'recording');
    expect(snapshot.capture.startedAtMillis, startedAt.millisecondsSinceEpoch);
    expect(snapshot.capture.pendingSeconds, 90);
  });

  test('an idle app publishes no start time to count from', () {
    final snapshot = build();

    expect(snapshot.capture.recording, isFalse);
    expect(snapshot.capture.startedAtMillis, isNull);
  });

  test('the encoded payload carries exactly what the widgets parse', () {
    final snapshot = build(
      memories: <RecallMemory>[memory('m', startedAt: now, pinned: true)],
      minis: <MiniMemory>[mini('t', dueAt: now.add(const Duration(hours: 1)))],
    );
    final decoded = jsonDecode(snapshot.encode()) as Map<String, dynamic>;

    expect(decoded['signedIn'], isTrue);
    expect((decoded['capture'] as Map)['phase'], 'idle');
    expect((decoded['today'] as Map)['days'], hasLength(7));
    expect((decoded['today'] as Map)['dueDays'], hasLength(7));
    expect((decoded['memories'] as List).single['pinned'], isTrue);
    expect((decoded['highlights'] as List).single['dueToday'], isTrue);
    // Nothing optional is emitted as null: the widget parser treats a missing
    // key and a null one the same way, so only one of them needs to exist.
    expect(decoded.values.any((value) => value == null), isFalse);
  });
}
