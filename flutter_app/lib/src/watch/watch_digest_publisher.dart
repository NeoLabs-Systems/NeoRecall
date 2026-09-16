import '../background/home_widget_snapshot.dart';
import '../models/timeline_moment.dart';
import '../models/transcript.dart';
import 'watch_digest.dart';

/// Turns what the phone already publishes into what the watch shows.
///
/// Built on top of [HomeWidgetSnapshot] rather than beside it: the rules for
/// what counts as today, which commitments are open and how they are ordered
/// are decided once, in `HomeWidgetPublisher`, and both accessory surfaces
/// inherit them. The only thing the watch needs that no widget does is the
/// transcript, which is added here and nowhere else.
class WatchDigestPublisher {
  const WatchDigestPublisher();

  WatchDigest build({
    required HomeWidgetSnapshot snapshot,
    required DateTime now,
    TimelineMoment? moment,
    List<TranscriptSegment>? fullTranscript,
  }) {
    if (!snapshot.signedIn) return WatchDigest.signedOut(now);
    return WatchDigest(
      signedIn: true,
      generatedAt: now,
      capture: WatchDigestCapture(
        recording: snapshot.capture.recording,
        title: snapshot.capture.title,
        detail: snapshot.capture.detail,
        pendingSeconds: snapshot.capture.pendingSeconds,
        issue: snapshot.capture.issue,
      ),
      today: WatchDigestToday(
        talkSeconds: snapshot.today.talkSeconds,
        memories: snapshot.today.memories,
        highlights: snapshot.today.highlights,
        openTasks: snapshot.today.openTasks,
        dueToday: snapshot.today.dueToday,
        overdue: snapshot.today.overdue,
      ),
      dayInReview: _clip(
        snapshot.dayInReview,
        WatchDigest.maxSummaryCharacters,
      ),
      moment: moment == null ? null : _moment(moment, fullTranscript),
      memories: snapshot.memories
          .take(WatchDigest.maxMemories)
          .map(
            (memory) => WatchDigestMemory(
              id: memory.id,
              emoji: memory.emoji,
              title: memory.title,
              summary: _clip(memory.summary, 160) ?? '',
              typeLabel: memory.typeLabel,
              at: DateTime.fromMillisecondsSinceEpoch(memory.atMillis),
              highlightCount: memory.highlightCount,
            ),
          )
          .toList(growable: false),
      highlights: snapshot.highlights
          .take(WatchDigest.maxHighlights)
          .map(
            (highlight) => WatchDigestHighlight(
              id: highlight.id,
              emoji: highlight.emoji,
              text: _clip(highlight.text, 200) ?? '',
              dueAt: highlight.dueMillis == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(highlight.dueMillis!),
              overdue: highlight.overdue,
              dueToday: highlight.dueToday,
              memoryTitle: highlight.memoryTitle,
            ),
          )
          .toList(growable: false),
    );
  }

  WatchDigestMoment _moment(
    TimelineMoment moment,
    List<TranscriptSegment>? fullTranscript,
  ) {
    // The timeline carries a preview of each conversation; a moment the reader
    // has already opened on the phone has the whole thing loaded. Prefer
    // whichever is longer, then keep only the end of it.
    final available =
        (fullTranscript != null &&
            fullTranscript.length > moment.segments.length)
        ? fullTranscript
        : moment.segments;
    final ordered = available.toList()
      ..sort((left, right) => left.startedAt.compareTo(right.startedAt));
    final kept = ordered.length > WatchDigest.maxTranscriptLines
        ? ordered.sublist(ordered.length - WatchDigest.maxTranscriptLines)
        : ordered;
    return WatchDigestMoment(
      id: moment.id,
      title: _clip(moment.titleEn, 120),
      summary: _clip(moment.summaryEn, WatchDigest.maxSummaryCharacters),
      startedAt: moment.startedAt,
      endedAt: moment.endedAt,
      live: moment.isLive || moment.isPending,
      awaitingWriteUp: moment.awaitsWriteUp && !moment.hasWriteUp,
      topics: moment.topics.take(3).toList(growable: false),
      lines: kept
          .map(
            (segment) => WatchDigestLine(
              speaker: segment.speaker,
              text: _clip(segment.text, WatchDigest.maxLineCharacters) ?? '',
              at: segment.startedAt,
            ),
          )
          .where((line) => line.text.isNotEmpty)
          .toList(growable: false),
      // Counted from the whole conversation, not from what fits, so the watch
      // can say how much of it is still on the phone.
      totalLines: moment.segmentCount > ordered.length
          ? moment.segmentCount
          : ordered.length,
    );
  }

  /// Cuts on a word boundary where there is one, so a clipped line still reads
  /// as a sentence that was interrupted rather than as a corrupted one.
  static String? _clip(String? value, int limit) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length <= limit) return trimmed;
    final cut = trimmed.substring(0, limit);
    final space = cut.lastIndexOf(' ');
    final body = space > limit ~/ 2 ? cut.substring(0, space) : cut;
    return '${body.trimRight()}…';
  }
}
