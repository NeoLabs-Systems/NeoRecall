class RecallSpeaker {
  const RecallSpeaker({
    required this.id,
    this.name,
    required this.occurrences,
    required this.matchingEnabled,
  });
  final String id;
  final String? name;
  final int occurrences;
  final bool matchingEnabled;
  factory RecallSpeaker.fromJson(Map<String, dynamic> json) => RecallSpeaker(
    id: json['id'] as String,
    name: json['display_name'] as String?,
    occurrences: json['occurrence_count'] as int? ?? 0,
    matchingEnabled:
        json['matching_enabled'] == 1 || json['matching_enabled'] == true,
  );
}
