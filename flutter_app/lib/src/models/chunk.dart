import 'dart:convert';
import 'dart:typed_data';

enum LocalChunkState {
  capturing,
  ready,
  uploading,
  uploaded,
  terminal,
  released,
  failed,
  // Parked after repeated server-side permanent failures. The upload pump does
  // NOT auto-retry this state, so a chunk whose audio the server keeps rejecting
  // stops looping forever; the user resolves it with an explicit retry.
  needsAttention,
}

class AudioChunk {
  const AudioChunk({
    required this.id,
    required this.sessionId,
    required this.sourceId,
    required this.sequence,
    required this.startedAt,
    required this.monotonicOffsetMs,
    required this.durationMs,
    required this.overlapMs,
    required this.channelLayout,
    required this.container,
    required this.codec,
    required this.sha256,
    required this.state,
    required this.createdAt,
    this.bytes,
    this.filePath,
    this.isFinal = false,
    this.receipt,
    this.error,
  });

  final String id;
  final String sessionId;
  final String sourceId;
  final int sequence;
  final DateTime startedAt;
  final int monotonicOffsetMs;
  final int durationMs;
  final int overlapMs;
  final String channelLayout;
  final String container;
  final String codec;
  final String sha256;
  final LocalChunkState state;
  final DateTime createdAt;
  final Uint8List? bytes;
  final String? filePath;
  final bool isFinal;
  final Map<String, dynamic>? receipt;
  final String? error;

  AudioChunk copyWith({
    LocalChunkState? state,
    Uint8List? bytes,
    String? filePath,
    bool? isFinal,
    Map<String, dynamic>? receipt,
    String? error,
  }) => AudioChunk(
    id: id,
    sessionId: sessionId,
    sourceId: sourceId,
    sequence: sequence,
    startedAt: startedAt,
    monotonicOffsetMs: monotonicOffsetMs,
    durationMs: durationMs,
    overlapMs: overlapMs,
    channelLayout: channelLayout,
    container: container,
    codec: codec,
    sha256: sha256,
    state: state ?? this.state,
    createdAt: createdAt,
    bytes: bytes ?? this.bytes,
    filePath: filePath ?? this.filePath,
    isFinal: isFinal ?? this.isFinal,
    receipt: receipt ?? this.receipt,
    error: error ?? this.error,
  );

  Map<String, dynamic> toMap({bool includeBytes = true}) => <String, dynamic>{
    'id': id,
    'sessionId': sessionId,
    'sourceId': sourceId,
    'sequence': sequence,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'monotonicOffsetMs': monotonicOffsetMs,
    'durationMs': durationMs,
    'overlapMs': overlapMs,
    'channelLayout': channelLayout,
    'container': container,
    'codec': codec,
    'sha256': sha256,
    'state': state.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'filePath': filePath,
    'isFinal': isFinal ? 1 : 0,
    'receipt': receipt == null ? null : jsonEncode(receipt),
    'error': error,
    if (includeBytes) 'bytes': bytes,
  };

  factory AudioChunk.fromMap(Map<String, dynamic> map) => AudioChunk(
    id: map['id'] as String,
    sessionId: map['sessionId'] as String,
    sourceId: map['sourceId'] as String,
    sequence: map['sequence'] as int,
    startedAt: DateTime.parse(map['startedAt'] as String),
    monotonicOffsetMs: map['monotonicOffsetMs'] as int,
    durationMs: map['durationMs'] as int,
    overlapMs: map['overlapMs'] as int,
    channelLayout: map['channelLayout'] as String,
    container: map['container'] as String,
    codec: map['codec'] as String,
    sha256: map['sha256'] as String,
    state: LocalChunkState.values.byName(map['state'] as String),
    createdAt: DateTime.parse(map['createdAt'] as String),
    bytes: map['bytes'] as Uint8List?,
    filePath: map['filePath'] as String?,
    isFinal: map['isFinal'] == true || map['isFinal'] == 1,
    receipt: map['receipt'] == null
        ? null
        : Map<String, dynamic>.from(
            map['receipt'] is String
                ? jsonDecode(map['receipt'] as String) as Map
                : map['receipt'] as Map,
          ),
    error: map['error'] as String?,
  );
}
