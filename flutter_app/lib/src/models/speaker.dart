class RecallSpeaker {
  const RecallSpeaker({
    required this.id,
    this.name,
    required this.occurrences,
    required this.matchingEnabled,
    this.previewDurationMs,
  });
  final String id;
  final String? name;
  final int occurrences;
  final bool matchingEnabled;
  final int? previewDurationMs;
  final int? totalDurationMs;
  bool get hasPreview => previewDurationMs != null;
  factory RecallSpeaker.fromJson(Map<String, dynamic> json) => RecallSpeaker(
    id: json['id'] as String,
    name: json['display_name'] as String?,
    occurrences: json['occurrence_count'] as int? ?? 0,
    matchingEnabled:
        json['matching_enabled'] == 1 || json['matching_enabled'] == true,
    previewDurationMs: json['preview_duration_ms'] as int?,
    totalDurationMs: json['total_duration_ms'] as int?,
  );
}
