import '../../l10n/gen/app_l10n.dart';

/// One piece of evidence the answer was written from.
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

  /// Human label for a source kind.
  String kindLabel(AppL10n l10n) => switch (kind) {
    'segment' => l10n.askSourceKindTranscript,
    'memory' => l10n.askSourceKindMemory,
    'mini_memory' => l10n.askSourceKindDetail,
    'daily_summary' => l10n.askSourceKindDay,
    _ => l10n.askSourceKindSource,
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

  /// Local wall-clock bounds the question was read as, in the account timezone.
  DateTime? periodFrom;
  DateTime? periodTo;
  String? timezone;

  bool get isPending => answer == null && error == null;

  bool get hasPeriod => periodFrom != null || periodTo != null;

  void readRetrieval(Map<String, dynamic> retrieval) {
    considered = (retrieval['considered'] as num?)?.toInt() ?? considered;
    weakCount = (retrieval['weakCount'] as num?)?.toInt() ?? 0;
    timezone = retrieval['timezone'] as String?;
    final period = retrieval['period'];
    if (period is Map) {
      periodFrom = DateTime.tryParse(period['fromLocal'] as String? ?? '');
      periodTo = DateTime.tryParse(period['toLocal'] as String? ?? '');
    }
  }
}
