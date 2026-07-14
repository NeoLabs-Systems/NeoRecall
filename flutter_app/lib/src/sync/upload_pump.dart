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

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => pump());
    pump();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> pump() async {
    if (_running || api.token == null) return;
    _running = true;
    try {
      final sessions = await store.pendingSessions();
      for (final session in sessions) {
        try {
          await api.syncSession(session);
          await store.markSessionSynced(session.id);
        } catch (_) {
          return;
        }
      }
      final chunks = await store.pending(limit: 200);
      final uploaded = chunks
          .where((chunk) => chunk.state == LocalChunkState.uploaded)
          .toList();
      if (uploaded.isNotEmpty) await _poll(uploaded);
      final ready = chunks
          .where(
            (chunk) => <LocalChunkState>{
              LocalChunkState.ready,
              // A process crash can leave this durable state behind. The PUT is
              // idempotent, so retrying is the only safe recovery action.
              LocalChunkState.uploading,
              LocalChunkState.failed,
            }.contains(chunk.state),
          )
          .take(2);
      await Future.wait(ready.map(_upload));
    } finally {
      _running = false;
      onChanged?.call();
    }
  }

  Future<void> _upload(AudioChunk chunk) async {
    try {
      await store.setState(chunk.id, LocalChunkState.uploading);
      final response = await api.uploadChunk(
        chunk,
        await store.readBytes(chunk),
      );
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

  Future<void> _poll(List<AudioChunk> chunks) async {
    try {
      final serverToLocal = <String, String>{
        for (final chunk in chunks)
          (chunk.receipt?['chunkId'] as String? ?? chunk.id): chunk.id,
      };
      final receipts = await api.chunkStatuses(serverToLocal.keys.toList());
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
      await store.setState(id, LocalChunkState.terminal, receipt: receipt);
      await store.release(id);
      try {
        await api.releaseChunks(<String>[receipt['chunkId'] as String]);
      } catch (_) {}
    } else if (state == 'reupload_required') {
      await store.setState(id, LocalChunkState.ready, receipt: receipt);
    } else {
      await store.setState(id, LocalChunkState.uploaded, receipt: receipt);
    }
  }
}
