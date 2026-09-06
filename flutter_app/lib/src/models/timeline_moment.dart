import 'transcript.dart';

/// One entry of the timeline: a conversation with everything that was said in
/// it, or the speech that has been transcribed but not grouped yet.
class TimelineMoment {
  const TimelineMoment({
    required this.id,
    required this.kind,
    required this.startedAt,
    required this.endedAt,
    required this.state,
    required this.segmentCount,
    required this.segments,
    required this.topics,
    this.insightState,
    this.titleEn,
    this.summaryEn,
    this.memoryWorthy,
    this.refinedAt,
    this.quarantined = false,
  });

  final String? id;
  final String kind;
  final DateTime startedAt;
  final DateTime endedAt;
  final String state;
  final String? insightState;
  final String? titleEn;
  final String? summaryEn;
  final List<String> topics;
  final bool? memoryWorthy;
  final DateTime? refinedAt;
  final bool quarantined;
  final int segmentCount;
  final List<TranscriptSegment> segments;

  /// Speech that arrived so recently it has not been grouped into a
  /// conversation yet.
  bool get isPending => kind == 'pending';

  /// Still being recorded, so its account of itself is provisional.
  bool get isLive => state == 'open';

  /// Finished, but the model has not described it yet — either because it is
  /// queued, or because generation is currently failing.
  bool get awaitsWriteUp => kind == 'conversation' && state == 'closed';

  /// Set aside after repeated failures; the transcript is unaffected.
  bool get isSetAside => quarantined;

  bool get hasWriteUp =>
      (titleEn ?? '').trim().isNotEmpty || (summaryEn ?? '').trim().isNotEmpty;

  /// A moment can be written up again only once it is finished.
  bool get canReprocess => id != null && !isPending && !isLive;

  /// A stable key for expansion state that survives a refresh.
  String get key => id ?? 'pending:${startedAt.toIso8601String()}';

  factory TimelineMoment.fromJson(Map<String, dynamic> json) => TimelineMoment(
    id: json['id']?.toString(),
    kind: json['kind']?.toString() ?? 'conversation',
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: DateTime.parse(json['endedAt'] as String),
    state: json['state']?.toString() ?? 'closed',
    insightState: json['insightState']?.toString(),
    titleEn: json['titleEn']?.toString(),
    summaryEn: json['summaryEn']?.toString(),
    topics: ((json['topics'] as List?) ?? const <dynamic>[])
        .map((topic) => topic.toString())
        .where((topic) => topic.trim().isNotEmpty)
        .toList(),
    memoryWorthy: json['memoryWorthy'] as bool?,
    refinedAt: json['refinedAt'] == null
        ? null
        : DateTime.tryParse(json['refinedAt'].toString()),
    quarantined: json['quarantined'] == true,
    segmentCount: (json['segmentCount'] as num?)?.toInt() ?? 0,
    segments: ((json['segments'] as List?) ?? const <dynamic>[])
        .cast<Map>()
        .map(
          (row) => TranscriptSegment.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList(),
  );
}
