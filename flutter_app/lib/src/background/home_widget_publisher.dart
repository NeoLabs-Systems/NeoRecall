import 'dart:math' as math;

import '../models/memory.dart';
import 'background_live_status.dart';
import 'home_widget_snapshot.dart';

/// Turns app state into the snapshot the Android home-screen widgets render.
///
/// Kept apart from the controller so the shaping rules — what counts as today,
/// what a widget is allowed to see, how commitments are ordered — can be read
/// and tested without a running app.
class HomeWidgetPublisher {
  const HomeWidgetPublisher();

  /// Memories are already limited server-side; this is the widget's own cap.
  static const int _memoryLimit = HomeWidgetSnapshot.listLimit;
  static const int _highlightLimit = HomeWidgetSnapshot.listLimit;

  HomeWidgetSnapshot build({
    required bool signedIn,
    required BackgroundLiveStatus status,
    required bool recording,
    required DateTime? recordingStartedAt,
    required List<RecallMemory> memories,
    required List<MiniMemory> miniMemories,
    required DateTime now,
    String? deviceLabel,
    bool deviceConnected = false,
    int? deviceBatteryPercent,
    int devicePendingSeconds = 0,
    String? dayInReview,
  }) {
    if (!signedIn) return HomeWidgetSnapshot.signedOut;
    final visible = memories.where((memory) => !memory.archived).toList()
      ..sort((left, right) => right.startedAt.compareTo(left.startedAt));
    final open = _openCommitments(miniMemories, now);
    return HomeWidgetSnapshot(
      signedIn: true,
      capture: _capture(status, recording, recordingStartedAt),
      today: _today(visible, miniMemories, open, now),
      device: deviceLabel == null || deviceLabel.trim().isEmpty
          ? null
          : HomeWidgetDevice(
              label: deviceLabel.trim(),
              connected: deviceConnected,
              batteryPercent: deviceBatteryPercent,
              pendingSeconds: devicePendingSeconds,
            ),
      dayInReview: dayInReview,
      memories: visible
          .take(_memoryLimit)
          .map(
            (memory) => HomeWidgetMemory(
              id: memory.id,
              emoji: memory.emoji,
              title: memory.title,
              summary: memory.summary,
              type: memory.type,
              typeLabel: memory.typeLabel,
              atMillis: memory.startedAt.millisecondsSinceEpoch,
              pinned: memory.pinned,
              highlightCount: memory.miniCount,
            ),
          )
          .toList(growable: false),
      highlights: open
          .take(_highlightLimit)
          .map(
            (mini) => HomeWidgetHighlight(
              id: mini.id,
              kind: mini.kind,
              emoji: mini.memoryEmoji?.trim().isNotEmpty == true
                  ? mini.memoryEmoji!.trim()
                  : mini.kindEmoji,
              text: mini.text,
              importance: mini.importance,
              dueMillis: mini.dueAt?.millisecondsSinceEpoch,
              overdue: _isOverdue(mini, now),
              dueToday: _isDueToday(mini, now),
              memoryTitle: mini.memoryTitle,
              memoryId: mini.memoryId,
            ),
          )
          .toList(growable: false),
    );
  }

  HomeWidgetCapture _capture(
    BackgroundLiveStatus status,
    bool recording,
    DateTime? startedAt,
  ) => HomeWidgetCapture(
    phase: status.phase.wireName,
    title: status.title,
    detail: status.detail,
    recording: recording,
    startedAtMillis: recording
        ? (startedAt ?? status.recordingStartedAt)?.millisecondsSinceEpoch
        : null,
    progress: status.progress,
    pendingBytes: status.pendingBytes,
    pendingSeconds: status.pendingAudioSeconds,
    etaSeconds: status.etaSeconds,
    issue: status.issue,
  );

  /// Open tasks and promises, most pressing first: overdue, then by due date,
  /// then by how important the write-up judged them.
  List<MiniMemory> _openCommitments(List<MiniMemory> minis, DateTime now) {
    final open = minis
        .where((mini) => mini.isActionable && mini.isOpen)
        .toList();
    open.sort((left, right) {
      final leftOverdue = _isOverdue(left, now);
      final rightOverdue = _isOverdue(right, now);
      if (leftOverdue != rightOverdue) return leftOverdue ? -1 : 1;
      final leftDue = left.dueAt;
      final rightDue = right.dueAt;
      if (leftDue != null && rightDue != null && leftDue != rightDue) {
        return leftDue.compareTo(rightDue);
      }
      if (leftDue != null && rightDue == null) return -1;
      if (leftDue == null && rightDue != null) return 1;
      final importance = right.importance.compareTo(left.importance);
      if (importance != 0) return importance;
      return (right.timelineAt ?? right.createdAt ?? now).compareTo(
        left.timelineAt ?? left.createdAt ?? now,
      );
    });
    return open;
  }

  HomeWidgetToday _today(
    List<RecallMemory> memories,
    List<MiniMemory> minis,
    List<MiniMemory> open,
    DateTime now,
  ) {
    final days = <HomeWidgetDay>[];
    for (
      var offset = HomeWidgetToday.trailingDays - 1;
      offset >= 0;
      offset -= 1
    ) {
      final day = _floor(now).subtract(Duration(days: offset));
      final next = day.add(const Duration(days: 1));
      days.add(
        HomeWidgetDay(
          label: _weekdayInitial(day),
          talkSeconds: _talkSeconds(memories, day, next),
          memories: memories
              .where(
                (memory) =>
                    !memory.startedAt.isBefore(day) &&
                    memory.startedAt.isBefore(next),
              )
              .length,
          highlights: minis.where((mini) {
            final at = mini.timelineAt ?? mini.createdAt;
            return at != null && !at.isBefore(day) && at.isBefore(next);
          }).length,
          today: offset == 0,
        ),
      );
    }
    // The week ahead, so "commitments open" can be read as when they land
    // rather than as a bare number.
    final dueDays = <HomeWidgetDay>[];
    for (var offset = 0; offset < HomeWidgetToday.trailingDays; offset += 1) {
      final day = _floor(now).add(Duration(days: offset));
      final next = day.add(const Duration(days: 1));
      dueDays.add(
        HomeWidgetDay(
          label: _weekdayInitial(day),
          talkSeconds: 0,
          memories: 0,
          highlights: 0,
          due: open.where((mini) {
            final due = mini.dueAt;
            if (due == null) return false;
            // Anything already late counts against today, which is when it
            // actually needs dealing with.
            if (offset == 0) return due.isBefore(next);
            return !due.isBefore(day) && due.isBefore(next);
          }).length,
          today: offset == 0,
        ),
      );
    }
    final today = days.isEmpty ? null : days.last;
    return HomeWidgetToday(
      talkSeconds: today?.talkSeconds ?? 0,
      memories: today?.memories ?? 0,
      highlights: today?.highlights ?? 0,
      openTasks: open.length,
      dueToday: open.where((mini) => _isDueToday(mini, now)).length,
      overdue: open.where((mini) => _isOverdue(mini, now)).length,
      days: days,
      dueDays: dueDays,
    );
  }

  /// Time inside conversations that became memories. A memory still being
  /// written up has no end yet, so it contributes nothing rather than a guess.
  int _talkSeconds(List<RecallMemory> memories, DateTime from, DateTime to) {
    var seconds = 0;
    for (final memory in memories) {
      final ended = memory.endedAt;
      if (ended == null) continue;
      if (memory.startedAt.isBefore(from) || !memory.startedAt.isBefore(to)) {
        continue;
      }
      seconds += math.max(0, ended.difference(memory.startedAt).inSeconds);
    }
    return seconds;
  }

  bool _isOverdue(MiniMemory mini, DateTime now) {
    final due = mini.dueAt;
    return due != null && due.isBefore(now);
  }

  bool _isDueToday(MiniMemory mini, DateTime now) {
    final due = mini.dueAt;
    if (due == null) return false;
    final start = _floor(now);
    return !due.isBefore(start) && due.isBefore(start.add(const Duration(days: 1)));
  }

  DateTime _floor(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// Resolved app-side so the widget never has to know the user's locale.
  String _weekdayInitial(DateTime day) =>
      const <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'][day.weekday - 1];
}
