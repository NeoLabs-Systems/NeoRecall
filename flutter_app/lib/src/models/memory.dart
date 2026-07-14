class RecallMemory {
  const RecallMemory({
    required this.id,
    required this.type,
    required this.title,
    required this.summary,
    required this.importance,
    required this.startedAt,
  });
  final String id;
  final String type;
  final String title;
  final String summary;
  final double importance;
  final DateTime startedAt;
  factory RecallMemory.fromJson(Map<String, dynamic> json) => RecallMemory(
    id: json['public_id'] as String,
    type: json['type'] as String,
    title: json['title_en'] as String,
    summary: json['summary_en'] as String,
    importance: (json['importance_override'] ?? json['importance'] as num)
        .toDouble(),
    startedAt: DateTime.parse(json['started_at'] as String),
  );
}

class MiniMemory {
  const MiniMemory({
    required this.id,
    required this.kind,
    required this.text,
    required this.importance,
    this.status,
  });
  final String id;
  final String kind;
  final String text;
  final double importance;
  final String? status;
  factory MiniMemory.fromJson(Map<String, dynamic> json) => MiniMemory(
    id: json['public_id'] as String,
    kind: json['kind'] as String,
    text: json['text_en'] as String,
    importance: (json['importance_override'] ?? json['importance'] as num)
        .toDouble(),
    status: json['status'] as String?,
  );
}
