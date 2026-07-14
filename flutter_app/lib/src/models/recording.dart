class RecordingSession {
  const RecordingSession({
    required this.id,
    required this.startedAt,
    required this.status,
    required this.chunkCount,
    required this.segmentCount,
  });
  final String id;
  final DateTime startedAt;
  final String status;
  final int chunkCount;
  final int segmentCount;
  factory RecordingSession.fromJson(Map<String, dynamic> json) =>
      RecordingSession(
        id: json['id'] as String,
        startedAt: DateTime.parse(json['corrected_started_at'] as String),
        status: json['status'] as String,
        chunkCount: json['chunk_count'] as int? ?? 0,
        segmentCount: json['segment_count'] as int? ?? 0,
      );
}

class LocalRecordingDeclaration {
  const LocalRecordingDeclaration({
    required this.id,
    required this.sourceId,
    required this.deviceId,
    required this.deviceClientUuid,
    required this.deviceName,
    required this.platform,
    required this.startedAt,
    required this.timezone,
    required this.consentAttestedAt,
    required this.sourceKind,
    required this.channelLayout,
    this.sampleRate = 16000,
    this.endedAt,
    this.finalSequence,
    this.interrupted = false,
    this.synced = false,
  });
  final String id;
  final String sourceId;
  final String deviceId;
  final String deviceClientUuid;
  final String deviceName;
  final String platform;
  final DateTime startedAt;
  final String timezone;
  final DateTime consentAttestedAt;
  final String sourceKind;
  final String channelLayout;
  final int sampleRate;
  final DateTime? endedAt;
  final int? finalSequence;
  final bool interrupted;
  final bool synced;
  LocalRecordingDeclaration copyWith({
    DateTime? endedAt,
    int? finalSequence,
    bool? interrupted,
    bool? synced,
  }) => LocalRecordingDeclaration(
    id: id,
    sourceId: sourceId,
    deviceId: deviceId,
    deviceClientUuid: deviceClientUuid,
    deviceName: deviceName,
    platform: platform,
    startedAt: startedAt,
    timezone: timezone,
    consentAttestedAt: consentAttestedAt,
    sourceKind: sourceKind,
    channelLayout: channelLayout,
    sampleRate: sampleRate,
    endedAt: endedAt ?? this.endedAt,
    finalSequence: finalSequence ?? this.finalSequence,
    interrupted: interrupted ?? this.interrupted,
    synced: synced ?? this.synced,
  );
  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'sourceId': sourceId,
    'deviceId': deviceId,
    'deviceClientUuid': deviceClientUuid,
    'deviceName': deviceName,
    'platform': platform,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'timezone': timezone,
    'consentAttestedAt': consentAttestedAt.toUtc().toIso8601String(),
    'sourceKind': sourceKind,
    'channelLayout': channelLayout,
    'sampleRate': sampleRate,
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'finalSequence': finalSequence,
    'interrupted': interrupted ? 1 : 0,
    'synced': synced ? 1 : 0,
  };
  factory LocalRecordingDeclaration.fromMap(Map<String, dynamic> map) =>
      LocalRecordingDeclaration(
        id: map['id'] as String,
        sourceId: map['sourceId'] as String,
        deviceId: map['deviceId'] as String,
        deviceClientUuid: map['deviceClientUuid'] as String,
        deviceName: map['deviceName'] as String,
        platform: map['platform'] as String,
        startedAt: DateTime.parse(map['startedAt'] as String),
        timezone: map['timezone'] as String,
        consentAttestedAt: DateTime.parse(map['consentAttestedAt'] as String),
        sourceKind: map['sourceKind'] as String,
        channelLayout: map['channelLayout'] as String,
        sampleRate: map['sampleRate'] as int? ?? 16000,
        endedAt: map['endedAt'] == null
            ? null
            : DateTime.parse(map['endedAt'] as String),
        finalSequence: map['finalSequence'] as int?,
        interrupted: map['interrupted'] == 1 || map['interrupted'] == true,
        synced: map['synced'] == 1 || map['synced'] == true,
      );
}
