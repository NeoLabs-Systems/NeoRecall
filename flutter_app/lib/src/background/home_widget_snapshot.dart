import 'dart:convert';

/// Everything the Android home-screen widgets are allowed to show.
///
/// The widgets run in the launcher's process and cannot reach the network or
/// the app database, so the app publishes one snapshot and the native side
/// renders it. Keeping the whole contract in a single immutable value means a
/// widget can never show a half-updated mix of two refreshes, and the payload
/// stays small enough to sit in SharedPreferences without a second store.
class HomeWidgetSnapshot {
  const HomeWidgetSnapshot({
    required this.signedIn,
    required this.capture,
    required this.today,
    this.device,
    this.dayInReview,
    this.memories = const <HomeWidgetMemory>[],
    this.highlights = const <HomeWidgetHighlight>[],
  });

  static const HomeWidgetSnapshot signedOut = HomeWidgetSnapshot(
    signedIn: false,
    capture: HomeWidgetCapture.idle,
    today: HomeWidgetToday.empty,
  );

  /// How many rows each collection widget can ever need. A widget shows fewer
  /// than this; publishing more would only cost payload size.
  static const int listLimit = 30;

  final bool signedIn;
  final HomeWidgetCapture capture;
  final HomeWidgetToday today;
  final HomeWidgetDevice? device;

  /// The newest server-written day summary, shown as the one narrative line on
  /// the Today widget instead of a hardcoded slogan.
  final String? dayInReview;
  final List<HomeWidgetMemory> memories;
  final List<HomeWidgetHighlight> highlights;

  Map<String, Object?> toJson() => <String, Object?>{
    'signedIn': signedIn,
    'capture': capture.toJson(),
    'today': today.toJson(),
    if (device != null) 'device': device!.toJson(),
    if (dayInReview != null && dayInReview!.trim().isNotEmpty)
      'dayInReview': dayInReview!.trim(),
    'memories': memories.map((memory) => memory.toJson()).toList(),
    'highlights': highlights.map((highlight) => highlight.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());
}

/// What capture is doing right now, mirrored from the same state that drives
/// the ongoing notification so the widget and the notification never disagree.
class HomeWidgetCapture {
  const HomeWidgetCapture({
    required this.phase,
    required this.title,
    required this.detail,
    this.recording = false,
    this.startedAtMillis,
    this.progress,
    this.pendingBytes = 0,
    this.pendingSeconds = 0,
    this.etaSeconds,
    this.issue,
  });

  static const HomeWidgetCapture idle = HomeWidgetCapture(
    phase: 'idle',
    title: 'Ready to record',
    detail: 'Nothing is capturing or waiting.',
  );

  final String phase;
  final String title;
  final String detail;
  final bool recording;
  final int? startedAtMillis;
  final double? progress;
  final int pendingBytes;
  final int pendingSeconds;
  final int? etaSeconds;
  final String? issue;

  Map<String, Object?> toJson() => <String, Object?>{
    'phase': phase,
    'title': title,
    'detail': detail,
    'recording': recording,
    if (startedAtMillis != null) 'startedAtMillis': startedAtMillis,
    if (progress != null) 'progress': progress,
    'pendingBytes': pendingBytes,
    'pendingSeconds': pendingSeconds,
    if (etaSeconds != null) 'etaSeconds': etaSeconds,
    if (issue != null && issue!.trim().isNotEmpty) 'issue': issue!.trim(),
  };
}

/// Counts for the Today widget, plus the trailing week that gives them shape.
class HomeWidgetToday {
  const HomeWidgetToday({
    required this.talkSeconds,
    required this.memories,
    required this.highlights,
    required this.openTasks,
    required this.dueToday,
    required this.overdue,
    this.days = const <HomeWidgetDay>[],
    this.dueDays = const <HomeWidgetDay>[],
  });

  static const HomeWidgetToday empty = HomeWidgetToday(
    talkSeconds: 0,
    memories: 0,
    highlights: 0,
    openTasks: 0,
    dueToday: 0,
    overdue: 0,
  );

  /// How many trailing days the Today widget charts, today included.
  static const int trailingDays = 7;

  final int talkSeconds;
  final int memories;
  final int highlights;
  final int openTasks;
  final int dueToday;
  final int overdue;

  /// The week behind today, oldest first.
  final List<HomeWidgetDay> days;

  /// The week ahead, today first: what is due, and when.
  final List<HomeWidgetDay> dueDays;

  Map<String, Object?> toJson() => <String, Object?>{
    'talkSeconds': talkSeconds,
    'memories': memories,
    'highlights': highlights,
    'openTasks': openTasks,
    'dueToday': dueToday,
    'overdue': overdue,
    'days': days.map((day) => day.toJson()).toList(),
    'dueDays': dueDays.map((day) => day.toJson()).toList(),
  };
}

class HomeWidgetDay {
  const HomeWidgetDay({
    required this.label,
    required this.talkSeconds,
    required this.memories,
    required this.highlights,
    this.due = 0,
    this.today = false,
  });

  /// Single-letter weekday initial, resolved app-side so the widget never has
  /// to know the user's locale.
  final String label;
  final int talkSeconds;
  final int memories;
  final int highlights;

  /// Commitments falling due on this day. Only ever set on [HomeWidgetToday.dueDays].
  final int due;
  final bool today;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'talkSeconds': talkSeconds,
    'memories': memories,
    'highlights': highlights,
    'due': due,
    'today': today,
  };
}

class HomeWidgetDevice {
  const HomeWidgetDevice({
    required this.label,
    required this.connected,
    this.batteryPercent,
    this.pendingSeconds = 0,
  });

  final String label;
  final bool connected;
  final int? batteryPercent;
  final int pendingSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'connected': connected,
    if (batteryPercent != null) 'batteryPercent': batteryPercent,
    'pendingSeconds': pendingSeconds,
  };
}

class HomeWidgetMemory {
  const HomeWidgetMemory({
    required this.id,
    required this.emoji,
    required this.title,
    required this.summary,
    required this.type,
    required this.typeLabel,
    required this.atMillis,
    this.pinned = false,
    this.highlightCount = 0,
  });

  final String id;
  final String emoji;
  final String title;
  final String summary;
  final String type;
  final String typeLabel;
  final int atMillis;
  final bool pinned;
  final int highlightCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'emoji': emoji,
    'title': title,
    'summary': summary,
    'type': type,
    'typeLabel': typeLabel,
    'atMillis': atMillis,
    'pinned': pinned,
    'highlightCount': highlightCount,
  };
}

class HomeWidgetHighlight {
  const HomeWidgetHighlight({
    required this.id,
    required this.kind,
    required this.emoji,
    required this.text,
    required this.importance,
    this.dueMillis,
    this.overdue = false,
    this.dueToday = false,
    this.memoryTitle,
    this.memoryId,
  });

  final String id;
  final String kind;
  final String emoji;
  final String text;
  final double importance;
  final int? dueMillis;
  final bool overdue;
  final bool dueToday;
  final String? memoryTitle;
  final String? memoryId;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'emoji': emoji,
    'text': text,
    'importance': importance,
    if (dueMillis != null) 'dueMillis': dueMillis,
    'overdue': overdue,
    'dueToday': dueToday,
    if (memoryTitle != null && memoryTitle!.trim().isNotEmpty)
      'memoryTitle': memoryTitle!.trim(),
    if (memoryId != null) 'memoryId': memoryId,
  };
}

/// A request a widget made while the app was not in a position to serve it.
///
/// The native side records the tap before it launches anything, so a cold
/// engine or a launcher that kills the process cannot lose it — the same
/// guarantee the record widget has always had, generalised to every action.
class HomeWidgetAction {
  const HomeWidgetAction({required this.type, this.targetId});

  final String type;
  final String? targetId;

  static const String startRecording = 'startRecording';
  static const String stopRecording = 'stopRecording';
  static const String completeHighlight = 'completeHighlight';
  static const String openMemory = 'openMemory';
  static const String openHighlight = 'openHighlight';
  static const String openPage = 'openPage';

  factory HomeWidgetAction.fromMap(Map<Object?, Object?> map) =>
      HomeWidgetAction(
        type: map['type']?.toString() ?? '',
        targetId: map['targetId']?.toString(),
      );
}
