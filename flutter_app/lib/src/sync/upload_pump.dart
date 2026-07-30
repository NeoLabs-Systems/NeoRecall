import 'dart:async';

import '../api_client.dart';
import '../models/chunk.dart';
import 'chunk_store.dart';

class UploadPump {
  UploadPump({required this.store, required this.api, this.onChanged});
  final ChunkStore store;
  final NeoRecallApiClient api;
  final void Function()? onChanged;
  bool _running = false;
  Timer? _timer;
  String? accountId;

  // How many times the client re-uploads a chunk the server keeps permanently
  // failing (state reupload_required) before parking it as needsAttention.
  // Re-uploading identical bytes fails deterministically, so this bound stops an
  // otherwise-infinite upload/transcribe/fail loop that would never release the
  // local audio. Counts are per-chunk and cleared on success or manual retry.
  static const int _maxReuploadAttempts = 3;
  final Map<String, int> _reuploadAttempts = <String, int>{};

  /// Clears the per-chunk reupload counters so a manual retry starts fresh.
  void forgetAttempts() => _reuploadAttempts.clear();

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => pump());
    pump();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> pump() async {
    final pumpingAccountId = accountId;
    if (_running || api.token == null || pumpingAccountId == null) return;
    _running = true;
    try {
      final sessions = await store.pendingSessions(pumpingAccountId);
      final blockedSessionIds = <String>{};
      for (final session in sessions) {
        if (!_isCurrent(pumpingAccountId)) return;
        try {
          await api.syncSession(session);
          if (!_isCurrent(pumpingAccountId)) return;
          await store.markSessionSynced(session.id);
        } catch (_) {
          // Keep trying other sessions/devices. Network or one bad session
          // must not freeze the entire multi-device upload ledger.
          blockedSessionIds.add(session.id);
          continue;
        }
      }
      if (!_isCurrent(pumpingAccountId)) return;
      final chunks = await store.pending(pumpingAccountId, limit: 200);
      final uploaded = chunks
          .where(
            (chunk) =>
                !blockedSessionIds.contains(chunk.sessionId) &&
                chunk.state == LocalChunkState.uploaded,
          )
          .toList();
      if (uploaded.isNotEmpty) await _poll(uploaded, pumpingAccountId);
      final ready = chunks
          .where(
            (chunk) =>
                !blockedSessionIds.contains(chunk.sessionId) &&
                <LocalChunkState>{
                  LocalChunkState.ready,
                  // A process crash can leave this durable state behind. The PUT
                  // is idempotent, so retrying is the only safe recovery action.
                  LocalChunkState.uploading,
                  LocalChunkState.failed,
                }.contains(chunk.state),
          )
          .take(2);
      await Future.wait(ready.map((chunk) => _upload(chunk, pumpingAccountId)));
    } finally {
      _running = false;
      onChanged?.call();
    }
  }

  bool _isCurrent(String pumpingAccountId) =>
      api.token != null && accountId == pumpingAccountId;

  Future<void> _upload(AudioChunk chunk, String pumpingAccountId) async {
    if (!_isCurrent(pumpingAccountId)) return;
    try {
      await store.setState(chunk.id, LocalChunkState.uploading);
      final response = await api.uploadChunk(
        chunk,
        await store.readBytes(chunk),
      );
      if (!_isCurrent(pumpingAccountId)) return;
      final receipt = Map<String, dynamic>.from(response['receipt'] as Map);
      await _acceptReceipt(chunk.id, receipt);
    } on ApiException catch (error) {
      if (error.status == 401) {
        await store.setState(
          chunk.id,
          LocalChunkState.ready,
          error: 'Authentication expired; upload paused.',
        );
        return;
      }
      await store.setState(
        chunk.id,
        LocalChunkState.failed,
        error: error.message,
      );
    } catch (error) {
      await store.setState(
        chunk.id,
        LocalChunkState.failed,
        error: error.toString(),
      );
    }
  }

  Future<void> _poll(List<AudioChunk> chunks, String pumpingAccountId) async {
    if (!_isCurrent(pumpingAccountId)) return;
    try {
      final serverToLocal = <String, String>{
        for (final chunk in chunks)
          (chunk.receipt?['chunkId'] as String? ?? chunk.id): chunk.id,
      };
      final receipts = await api.chunkStatuses(serverToLocal.keys.toList());
      if (!_isCurrent(pumpingAccountId)) return;
      for (final receipt in receipts) {
        final localId = serverToLocal[receipt['chunkId'] as String?];
        if (localId != null) await _acceptReceipt(localId, receipt);
      }
    } catch (_) {
      /* Connectivity failures leave durable audio untouched. */
    }
  }

  Future<void> _acceptReceipt(String id, Map<String, dynamic> receipt) async {
    final state = receipt['state'];
    final terminal = state == 'transcribed' || state == 'silent';
    if (terminal &&
        receipt['persistedAt'] != null &&
        receipt['serverAudioDeletedAt'] != null &&
        receipt['transcriptSha256'] != null) {
      _reuploadAttempts.remove(id);
      await store.setState(id, LocalChunkState.terminal, receipt: receipt);
      await store.release(id);
      try {
        await api.releaseChunks(<String>[receipt['chunkId'] as String]);
      } catch (_) {}
    } else if (state == 'reupload_required') {
      final attempts = (_reuploadAttempts[id] ?? 0) + 1;
      if (attempts >= _maxReuploadAttempts) {
        _reuploadAttempts.remove(id);
        final code = receipt['errorCode'];
        await store.setState(
          id,
          LocalChunkState.needsAttention,
          receipt: receipt,
          error:
              'The server could not transcribe this recording after repeated attempts'
              '${code == null ? '' : ' ($code)'}. Retry when ready.',
        );
      } else {
        _reuploadAttempts[id] = attempts;
        await store.setState(id, LocalChunkState.ready, receipt: receipt);
      }
    } else {
      await store.setState(id, LocalChunkState.uploaded, receipt: receipt);
    }
  }
}
