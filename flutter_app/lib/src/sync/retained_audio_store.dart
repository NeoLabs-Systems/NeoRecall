import 'dart:typed_data';

import 'retained_audio_store_stub.dart'
    if (dart.library.io) 'retained_audio_store_io.dart'
    as implementation;

/// A processed recording kept on this device so Moments can play it.
///
/// The server still deletes its copy after a terminal receipt. This store is
/// the only place raw audio lives after that, and it is purged by the same
/// keep-days setting as photos and documents.
class RetainedAudioClip {
  const RetainedAudioClip({
    required this.id,
    required this.accountId,
    required this.capturedAt,
    required this.mimeType,
    required this.filename,
    required this.byteLength,
    this.importId,
    this.sessionId,
    this.sequence = 0,
    this.duration = Duration.zero,
  });

  final String id;
  final String accountId;
  final DateTime capturedAt;
  final String mimeType;
  final String filename;
  final int byteLength;
  final String? importId;
  final String? sessionId;
  final int sequence;
  final Duration duration;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'accountId': accountId,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'mimeType': mimeType,
    'filename': filename,
    'byteLength': byteLength,
    'importId': importId,
    'sessionId': sessionId,
    'sequence': sequence,
    'durationMs': duration.inMilliseconds,
  };

  factory RetainedAudioClip.fromJson(Map<String, dynamic> json) =>
      RetainedAudioClip(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        filename: json['filename'] as String? ?? json['id'] as String,
        byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
        importId: json['importId']?.toString(),
        sessionId: json['sessionId']?.toString(),
        sequence: (json['sequence'] as num?)?.toInt() ?? 0,
        duration: Duration(
          milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
        ),
      );
}

abstract class RetainedAudioStore {
  Future<void> initialize();

  Future<void> retain({
    required String accountId,
    required String id,
    required Uint8List bytes,
    required String mimeType,
    required String filename,
    required DateTime capturedAt,
    String? importId,
    String? sessionId,
    int sequence = 0,
    Duration duration = Duration.zero,
  });

  Future<List<RetainedAudioClip>> lookup({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  });

  Future<bool> hasClips({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  });

  Future<RetainedAudioClip?> getClip(String accountId, String id);

  Future<Uint8List> readBytes(RetainedAudioClip clip);

  Future<int> purgeExpired({
    required String accountId,
    required Duration keep,
    DateTime? now,
  });

  Future<int> purgeAccount(String accountId);

  Future<void> close();
}

RetainedAudioStore createRetainedAudioStore({String? rootPath}) =>
    implementation.createRetainedAudioStore(rootPath: rootPath);
