import 'dart:typed_data';
import '../models/chunk.dart';
import '../models/recording.dart';
import 'chunk_store.dart';

ChunkStore createChunkStore() => _UnsupportedChunkStore();

class _UnsupportedChunkStore implements ChunkStore {
  Never _unsupported() => throw UnsupportedError(
    'Durable chunk storage is unavailable on this platform.',
  );
  @override
  Future<void> initialize() async => _unsupported();
  @override
  Future<void> put(AudioChunk chunk, Uint8List bytes) async => _unsupported();
  @override
  Future<bool> hasMatchingChunk(String id, String sha256) async =>
      _unsupported();
  @override
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes) async =>
      _unsupported();
  @override
  Future<void> clearPartial(String sourceId) async => _unsupported();
  @override
  Future<void> putSession(LocalRecordingDeclaration session) async =>
      _unsupported();
  @override
  Future<void> claimLegacySessions(String accountId) async => _unsupported();
  @override
  Future<List<LocalRecordingDeclaration>> pendingSessions(
    String accountId,
  ) async => _unsupported();
  @override
  Future<void> markSessionSynced(String id) async => _unsupported();
  @override
  Future<List<AudioChunk>> pending(String accountId, {int limit = 100}) async =>
      _unsupported();
  @override
  Future<Uint8List> readBytes(AudioChunk chunk) async => _unsupported();
  @override
  Future<int> storedBytes(AudioChunk chunk) async => _unsupported();
  @override
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  }) async => _unsupported();
  @override
  Future<void> release(String id) async => _unsupported();
  @override
  Future<int> pendingBytes(String accountId) async => _unsupported();
  @override
  Future<void> close() async {}

  @override
  Future<void> purgeAll() async {}
}
