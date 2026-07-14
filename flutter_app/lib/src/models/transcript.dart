class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.text,
    required this.startedAt,
    required this.endedAt,
    this.language,
    this.speaker,
    this.conversationId,
  });
  final String id;
  final String text;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? language;
  final String? speaker;
  final String? conversationId;
  factory TranscriptSegment.fromJson(Map<String, dynamic> json) =>
      TranscriptSegment(
        id: (json['public_id'] ?? json['id']).toString(),
        text: json['text'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: DateTime.parse(json['ended_at'] as String),
        language: json['language'] as String?,
        speaker: (json['voiceprint_name'] ?? json['local_label']) as String?,
        conversationId: json['conversation_id'] as String?,
      );
}
