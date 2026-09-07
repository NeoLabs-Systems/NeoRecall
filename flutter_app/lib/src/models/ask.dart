/// One piece of evidence the answer was written from.
///
/// `relevance` is the server's fused retrieval score for the document, kept so
/// the app can show how strong a match was rather than presenting every source
/// as equally certain.
class AskSource {
  const AskSource({
    required this.kind,
    required this.excerpt,
    this.title,
    this.occurredAt,
    this.relevance = 0,
    this.link,
  });

  factory AskSource.fromJson(Map<String, dynamic> json) {
    final raw = json['timestamp'];
    return AskSource(
      kind: (json['kind'] as String?)?.trim().isNotEmpty == true
          ? json['kind'] as String
          : 'source',
      excerpt: (json['excerpt'] as String?)?.trim() ?? '',
      title: (json['title'] as String?)?.trim(),
      occurredAt: raw is String ? DateTime.tryParse(raw)?.toLocal() : null,
      relevance: (json['relevance'] as num?)?.toDouble() ?? 0,
      link: json['link'] as String?,
    );
  }

  final String kind;
  final String excerpt;
  final String? title;
  final DateTime? occurredAt;
  final double relevance;
  final String? link;

  /// Human label for a source kind (not snake_case).
  String get kindLabel => switch (kind) {
    'segment' => 'Transcript',
    'memory' => 'Memory',
    'mini_memory' => 'Detail',
    'daily_summary' => 'Day',
    _ => 'Source',
  };
}

/// One question and what came back for it.
class AskTurn {
  AskTurn({required this.question});

  final String question;
  String? answer;
  String? error;
  List<AskSource> sources = <AskSource>[];

  /// How many documents retrieval read, and how many nearest neighbours were
  /// too far from the question to count as evidence.
  int considered = 0;
  int weakCount = 0;

  bool get isPending => answer == null && error == null;
}
