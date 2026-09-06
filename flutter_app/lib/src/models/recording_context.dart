import 'dart:typed_data';

enum RecordingContextKind { highlight, note, image, document, file }

enum LocalContextState { pending, uploading, synced, failed }

class RecordingContextItem {
  const RecordingContextItem({
    required this.id,
    required this.accountId,
    required this.sessionId,
    required this.kind,
    required this.capturedOffsetMs,
    required this.state,
    required this.createdAt,
    this.noteText,
    this.originalName,
    this.contentType,
    this.byteSize,
    this.sha256,
    this.filePath,
    this.bytes,
    this.error,
  });

  final String id;
  final String accountId;
  final String sessionId;
  final RecordingContextKind kind;
  final int capturedOffsetMs;
  final String? noteText;
  final String? originalName;
  final String? contentType;
  final int? byteSize;
  final String? sha256;
  final String? filePath;
  final Uint8List? bytes;
  final LocalContextState state;
  final String? error;
  final DateTime createdAt;

  RecordingContextItem copyWith({
    LocalContextState? state,
    String? filePath,
    String? error,
  }) => RecordingContextItem(
    id: id,
    accountId: accountId,
    sessionId: sessionId,
    kind: kind,
    capturedOffsetMs: capturedOffsetMs,
    noteText: noteText,
    originalName: originalName,
    contentType: contentType,
    byteSize: byteSize,
    sha256: sha256,
    filePath: filePath ?? this.filePath,
    bytes: bytes,
    state: state ?? this.state,
    error: error,
    createdAt: createdAt,
  );

  Map<String, dynamic> toMap({bool includeBytes = true}) => <String, dynamic>{
    'id': id,
    'accountId': accountId,
    'sessionId': sessionId,
    'kind': kind.name,
    'capturedOffsetMs': capturedOffsetMs,
    'noteText': noteText,
    'originalName': originalName,
    'contentType': contentType,
    'byteSize': byteSize,
    'sha256': sha256,
    'filePath': filePath,
    if (includeBytes) 'bytes': bytes,
    'state': state.name,
    'error': error,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory RecordingContextItem.fromMap(Map<String, dynamic> map) =>
      RecordingContextItem(
        id: map['id'] as String,
        accountId: map['accountId'] as String,
        sessionId: map['sessionId'] as String,
        kind: RecordingContextKind.values.byName(map['kind'] as String),
        capturedOffsetMs: (map['capturedOffsetMs'] as num).toInt(),
        noteText: map['noteText'] as String?,
        originalName: map['originalName'] as String?,
        contentType: map['contentType'] as String?,
        byteSize: (map['byteSize'] as num?)?.toInt(),
        sha256: map['sha256'] as String?,
        filePath: map['filePath'] as String?,
        bytes: map['bytes'] as Uint8List?,
        state: LocalContextState.values.byName(map['state'] as String),
        error: map['error'] as String?,
        createdAt: DateTime.parse(map['createdAt'] as String),
      );
}
