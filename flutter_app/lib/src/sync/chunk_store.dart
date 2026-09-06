import 'dart:typed_data';

import '../models/chunk.dart';
import '../models/recording.dart';
import '../models/recording_context.dart';
import 'chunk_store_stub.dart'
    if (dart.library.io) 'chunk_store_io.dart'
    if (dart.library.html) 'chunk_store_web.dart'
    as implementation;

abstract class ChunkStore {
  Future<void> initialize();
  Future<void> put(AudioChunk chunk, Uint8List bytes);

  /// Used by cross-runtime handoffs to make the commit/claim boundary
  /// idempotent after a process crash.
  Future<bool> hasMatchingChunk(String id, String sha256) async => false;
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes);
  Future<void> clearPartial(String sourceId);
  Future<void> putSession(LocalRecordingDeclaration session);
  Future<void> claimLegacySessions(String accountId);
  Future<List<LocalRecordingDeclaration>> pendingSessions(String accountId);
  Future<void> markSessionSynced(String id);
  Future<List<AudioChunk>> pending(String accountId, {int limit = 100});
  Future<Uint8List> readBytes(AudioChunk chunk);
  Future<int> storedBytes(AudioChunk chunk);
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  });
  Future<void> release(String id);

  /// Erases every locally spooled recording and its metadata.
  ///
  /// Used when an account is deleted: the server cascade cannot reach audio
  /// that is still sitting on this device waiting to upload, and leaving it
  /// behind would make "delete everything" untrue.
  Future<void> purgeAll();
  Future<int> pendingBytes(String accountId);
  Future<void> close();
}

/// Durable storage used only by the recording-context feature.
///
/// Keeping this separate from [ChunkStore] means audio-only store fakes and
/// integrations do not have to know about multimodal context.
abstract interface class RecordingContextStore {
  Future<void> putContext(RecordingContextItem item, Uint8List? bytes);
  Future<List<RecordingContextItem>> contextItems(
    String accountId, {
    String? sessionId,
    bool pendingOnly = false,
  });
  Future<Uint8List?> readContextBytes(RecordingContextItem item);
  Future<void> setContextState(
    String id,
    LocalContextState state, {
    String? error,
  });
  Future<void> releaseContextBytes(String id);
}

ChunkStore createChunkStore() => implementation.createChunkStore();
