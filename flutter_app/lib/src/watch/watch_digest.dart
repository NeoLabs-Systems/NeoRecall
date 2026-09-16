import 'dart:convert';

/// Everything a paired Wear OS watch is allowed to show about the day.
///
/// A watch is a display for what the phone already knows: it never queries the
/// server, and nothing it shows can change what the phone does. Keeping the
/// contract in one immutable value means the watch can never render a
/// half-updated mix of two publishes, and keeping it apart from the home-screen
/// widget contract means a field can be added for one surface without paying
/// for it on the other — a Data Layer item is a far tighter budget than a
/// preferences string.
class WatchDigest {
  const WatchDigest({
    required this.signedIn,
    required this.generatedAt,
    required this.capture,
    required this.today,
    this.dayInReview,
    this.moment,
    this.memories = const <WatchDigestMemory>[],
    this.highlights = const <WatchDigestHighlight>[],
  });

  factory WatchDigest.signedOut(DateTime now) => WatchDigest(
    signedIn: false,
    generatedAt: now,
    capture: const WatchDigestCapture(
      recording: false,
      title: '',
      detail: '',
      pendingSeconds: 0,
    ),
    today: const WatchDigestToday(),
  );

  /// Mirrors `WearDigestProtocol` on the Android side. A Data Layer item is
  /// capped near 100 KB and an oversized put fails the whole transfer, so the
  /// payload is trimmed to fit rather than risked.
  static const int maxPayloadBytes = 60000;
  static const int maxTranscriptLines = 40;
  static const int maxLineCharacters = 280;
  static const int maxMemories = 8;
  static const int maxHighlights = 8;
  static const int maxSummaryCharacters = 420;

  final bool signedIn;
  final DateTime generatedAt;
  final WatchDigestCapture capture;
  final WatchDigestToday today;
  final String? dayInReview;
  final WatchDigestMoment? moment;
  final List<WatchDigestMemory> memories;
  final List<WatchDigestHighlight> highlights;

  Map<String, Object?> toJson() => <String, Object?>{
    'signedIn': signedIn,
    'generatedAtMs': generatedAt.millisecondsSinceEpoch,
    'capture': capture.toJson(),
    'today': today.toJson(),
    if (dayInReview != null && dayInReview!.trim().isNotEmpty)
      'dayInReview': dayInReview!.trim(),
    if (moment != null) 'moment': moment!.toJson(),
    'memories': memories.map((memory) => memory.toJson()).toList(),
    'highlights': highlights.map((highlight) => highlight.toJson()).toList(),
  };

  /// The payload as it goes over the Data Layer, guaranteed to fit.
  ///
  /// Trimming drops whole transcript lines from the oldest end first, because a
  /// conversation read on a wrist is read backwards from its most recent line,
  /// and only then gives up list rows. A digest that is refused for being one
  /// byte too large would leave the watch showing yesterday.
  String encode() {
    var candidate = this;
    var payload = jsonEncode(candidate.toJson());
    while (utf8.encode(payload).length > maxPayloadBytes) {
      final reduced = candidate._shrink();
      if (reduced == null) return payload;
      candidate = reduced;
      payload = jsonEncode(candidate.toJson());
    }
    return payload;
  }

  /// One step smaller, or null when there is nothing left to give up.
  WatchDigest? _shrink() {
    final currentMoment = moment;
    if (currentMoment != null && currentMoment.lines.length > 4) {
      final keep = (currentMoment.lines.length * 3) ~/ 4;
      return _copyWith(
        moment: currentMoment.copyWith(
          lines: currentMoment.lines
              .sublist(currentMoment.lines.length - keep)
              .toList(growable: false),
        ),
      );
    }
    if (memories.length > 2) {
      return _copyWith(memories: memories.sublist(0, memories.length - 1));
    }
    if (highlights.length > 2) {
      return _copyWith(
        highlights: highlights.sublist(0, highlights.length - 1),
      );
    }
    if (currentMoment != null && currentMoment.lines.isNotEmpty) {
      return _copyWith(moment: currentMoment.copyWith(lines: const []));
    }
    return null;
  }

  WatchDigest _copyWith({
    WatchDigestMoment? moment,
    List<WatchDigestMemory>? memories,
    List<WatchDigestHighlight>? highlights,
  }) => WatchDigest(
    signedIn: signedIn,
    generatedAt: generatedAt,
    capture: capture,
    today: today,
    dayInReview: dayInReview,
    moment: moment ?? this.moment,
    memories: memories ?? this.memories,
    highlights: highlights ?? this.highlights,
  );
}

/// What capture is doing, in the two lines a watch has room for.
class WatchDigestCapture {
  const WatchDigestCapture({
    required this.recording,
    required this.title,
    required this.detail,
    required this.pendingSeconds,
    this.issue,
  });

  final bool recording;
  final String title;
  final String detail;
  final int pendingSeconds;
  final String? issue;

  Map<String, Object?> toJson() => <String, Object?>{
    'recording': recording,
    'title': title,
    'detail': detail,
    'pendingSeconds': pendingSeconds,
    if (issue != null && issue!.trim().isNotEmpty) 'issue': issue!.trim(),
  };
}

/// The counts the digest's headline row and both complications read from.
class WatchDigestToday {
  const WatchDigestToday({
    this.talkSeconds = 0,
    this.memories = 0,
    this.highlights = 0,
    this.openTasks = 0,
    this.dueToday = 0,
    this.overdue = 0,
  });

  final int talkSeconds;
  final int memories;
  final int highlights;
  final int openTasks;
  final int dueToday;
  final int overdue;

  Map<String, Object?> toJson() => <String, Object?>{
    'talkSeconds': talkSeconds,
    'memories': memories,
    'highlights': highlights,
    'openTasks': openTasks,
    'dueToday': dueToday,
    'overdue': overdue,
  };
}

/// The newest conversation: how it was written up, and what was said in it.
class WatchDigestMoment {
  const WatchDigestMoment({
    this.id,
    this.title,
    this.summary,
    required this.startedAt,
    required this.endedAt,
    required this.live,
    required this.awaitingWriteUp,
    this.topics = const <String>[],
    this.lines = const <WatchDigestLine>[],
    required this.totalLines,
  });

  final String? id;
  final String? title;
  final String? summary;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool live;
  final bool awaitingWriteUp;
  final List<String> topics;
  final List<WatchDigestLine> lines;

  /// How long the conversation is in full, so the watch can say what it is not
  /// showing rather than implying the transcript ends where the payload does.
  final int totalLines;

  WatchDigestMoment copyWith({List<WatchDigestLine>? lines}) =>
      WatchDigestMoment(
        id: id,
        title: title,
        summary: summary,
        startedAt: startedAt,
        endedAt: endedAt,
        live: live,
        awaitingWriteUp: awaitingWriteUp,
        topics: topics,
        lines: lines ?? this.lines,
        totalLines: totalLines,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    if (id != null) 'id': id,
    if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
    if (summary != null && summary!.trim().isNotEmpty)
      'summary': summary!.trim(),
    'startedAtMs': startedAt.millisecondsSinceEpoch,
    'endedAtMs': endedAt.millisecondsSinceEpoch,
    'live': live,
    'awaitingWriteUp': awaitingWriteUp,
    'topics': topics,
    'lines': lines.map((line) => line.toJson()).toList(),
    'totalLines': totalLines,
  };
}

/// One thing that was said.
class WatchDigestLine {
  const WatchDigestLine({this.speaker, required this.text, required this.at});

  final String? speaker;
  final String text;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
    if (speaker != null && speaker!.trim().isNotEmpty)
      'speaker': speaker!.trim(),
    'text': text,
    'atMs': at.millisecondsSinceEpoch,
  };
}

class WatchDigestMemory {
  const WatchDigestMemory({
    required this.id,
    required this.emoji,
    required this.title,
    required this.summary,
    required this.typeLabel,
    required this.at,
    this.highlightCount = 0,
  });

  final String id;
  final String emoji;
  final String title;
  final String summary;
  final String typeLabel;
  final DateTime at;
  final int highlightCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'emoji': emoji,
    'title': title,
    'summary': summary,
    'typeLabel': typeLabel,
    'atMs': at.millisecondsSinceEpoch,
    'highlightCount': highlightCount,
  };
}

class WatchDigestHighlight {
  const WatchDigestHighlight({
    required this.id,
    required this.emoji,
    required this.text,
    this.dueAt,
    this.overdue = false,
    this.dueToday = false,
    this.memoryTitle,
  });

  final String id;
  final String emoji;
  final String text;
  final DateTime? dueAt;
  final bool overdue;
  final bool dueToday;
  final String? memoryTitle;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'emoji': emoji,
    'text': text,
    if (dueAt != null) 'dueMs': dueAt!.millisecondsSinceEpoch,
    'overdue': overdue,
    'dueToday': dueToday,
    if (memoryTitle != null && memoryTitle!.trim().isNotEmpty)
      'memoryTitle': memoryTitle!.trim(),
  };
}
