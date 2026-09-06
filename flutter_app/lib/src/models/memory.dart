class RecallMemory {
  const RecallMemory({
    required this.id,
    required this.type,
    required this.title,
    required this.summary,
    required this.emoji,
    required this.importance,
    required this.startedAt,
    this.endedAt,
    this.pinned = false,
    this.archived = false,
    this.topics = const <String>[],
    this.miniCount = 0,
  });

  final String id;
  final String type;
  final String title;
  final String summary;
  final String emoji;
  final double importance;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool pinned;
  final bool archived;
  final List<String> topics;
  final int miniCount;

  /// Human label for the memory type (not snake_case).
  String get typeLabel => switch (type) {
    'meeting' => 'Meeting',
    'lesson' => 'Lesson',
    'conversation' => 'Conversation',
    'project_discussion' => 'Project',
    'introduction' => 'Introduction',
    'decision' => 'Decision',
    'experience' => 'Experience',
    _ => 'Moment',
  };

  factory RecallMemory.fromJson(Map<String, dynamic> json) {
    final topicsRaw = json['topics'];
    return RecallMemory(
      id: json['public_id'] as String,
      type: json['type'] as String? ?? 'other',
      title: json['title_en'] as String? ?? '',
      summary: json['summary_en'] as String? ?? '',
      emoji: (json['emoji'] as String?)?.trim().isNotEmpty == true
          ? json['emoji'] as String
          : _fallbackEmoji(json['type'] as String?),
      importance:
          (json['importance_override'] ?? json['importance'] as num? ?? 5)
              .toDouble(),
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: json['ended_at'] != null
          ? DateTime.tryParse(json['ended_at'] as String)
          : null,
      pinned: json['pinned'] == true || json['pinned'] == 1,
      archived: json['archived'] == true || json['archived'] == 1,
      topics: topicsRaw is List
          ? topicsRaw.map((value) => value.toString()).toList()
          : const <String>[],
      miniCount: (json['mini_count'] as num?)?.toInt() ?? 0,
    );
  }

  static String _fallbackEmoji(String? type) => switch (type) {
    'meeting' => '🤝',
    'lesson' => '📚',
    'conversation' => '💬',
    'project_discussion' => '📋',
    'introduction' => '👋',
    'decision' => '⚖️',
    'experience' => '✨',
    _ => '💭',
  };
}

class MiniMemory {
  const MiniMemory({
    required this.id,
    required this.kind,
    required this.text,
    required this.importance,
    this.status,
    this.occurredAt,
    this.dueAt,
    this.createdAt,
    this.timelineAt,
    this.memoryId,
    this.memoryTitle,
    this.memoryEmoji,
  });

  final String id;
  final String kind;
  final String text;
  final double importance;
  final String? status;
  final DateTime? occurredAt;
  final DateTime? dueAt;
  final DateTime? createdAt;
  final DateTime? timelineAt;
  final String? memoryId;
  final String? memoryTitle;
  final String? memoryEmoji;

  bool get isActionable => kind == 'task' || kind == 'promise';
  bool get isOpen => status == 'open';
  bool get isCompleted => status == 'completed';

  String get kindLabel => switch (kind) {
    'task' => 'Task',
    'promise' => 'Promise',
    'event' => 'Event',
    'location' => 'Place',
    'person' => 'Person',
    'relationship' => 'Relationship',
    'fact' => 'Fact',
    _ => kind,
  };

  String get kindEmoji => switch (kind) {
    'task' => '✅',
    'promise' => '🤝',
    'event' => '📅',
    'location' => '📍',
    'person' => '👤',
    'relationship' => '🔗',
    'fact' => '💡',
    _ => '✨',
  };

  factory MiniMemory.fromJson(Map<String, dynamic> json) {
    final memory = json['memory'] is Map
        ? Map<String, dynamic>.from(json['memory'] as Map)
        : null;
    DateTime? parseOptional(dynamic value) =>
        value is String ? DateTime.tryParse(value) : null;
    return MiniMemory(
      id: json['public_id'] as String,
      kind: json['kind'] as String? ?? 'fact',
      text: json['text_en'] as String? ?? '',
      importance:
          (json['importance_override'] ?? json['importance'] as num? ?? 5)
              .toDouble(),
      status: json['status'] as String?,
      occurredAt: parseOptional(json['occurred_at']),
      dueAt: parseOptional(json['due_at']),
      createdAt: parseOptional(json['created_at']),
      timelineAt:
          parseOptional(json['timeline_at']) ??
          parseOptional(json['occurred_at']) ??
          parseOptional(json['due_at']) ??
          parseOptional(json['created_at']),
      memoryId:
          memory?['public_id'] as String? ??
          json['memory_public_id'] as String?,
      memoryTitle: memory?['title_en'] as String?,
      memoryEmoji: memory?['emoji'] as String?,
    );
  }
}
