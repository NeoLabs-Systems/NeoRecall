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

  /// How many chunks one pump cycle uploads at a time.
  static const int _uploadConcurrency = 3;

  /// Idle cadence, and the much shorter pause between cycles while a backlog is
  /// still draining.
  ///
  /// A device may record continuously for days, so the pump has to be able to
  /// outrun capture: one cycle per idle interval would cap the drain rate at a
  /// small multiple of real time, and any offline stretch would then take about
  /// as long to catch up as it lasted. Re-arming immediately after a cycle that
  /// made progress removes that ceiling; a cycle that uploaded nothing falls
  /// back to the idle cadence instead of retrying a failure in a tight loop.
  static const Duration _idleInterval = Duration(seconds: 30);
  static const Duration _drainInterval = Duration(seconds: 1);

  Timer? _drainTimer;
  bool _backlogDraining = false;

  /// Clears the per-chunk reupload counters so a manual retry starts fresh.
  void forgetAttempts() => _reuploadAttempts.clear();

  void start() {
    _timer ??= Timer.periodic(_idleInterval, (_) => pump());
    pump();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  void _scheduleDrain() {
    if (_drainTimer != null || _timer == null) return;
    _drainTimer = Timer(_drainInterval, () {
      _drainTimer = null;
      pump();
    });
  }

  Future<void> pump() async {
    final pumpingAccountId = accountId;
    if (_running || api.token == null || pumpingAccountId == null) return;
    _running = true;
    _backlogDraining = false;
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
          .toList(growable: false);
      final batch = ready.take(_uploadConcurrency).toList(growable: false);
      final results = await Future.wait(
        batch.map((chunk) => _upload(chunk, pumpingAccountId)),
      );
      // Only keep draining while the backlog is both larger than one batch and
      // actually shrinking; otherwise the idle timer owns the retry cadence.
      _backlogDraining =
          ready.length > batch.length && results.any((uploaded) => uploaded);
    } finally {
      _running = false;
      onChanged?.call();
      if (_backlogDraining) _scheduleDrain();
    }
  }

  bool _isCurrent(String pumpingAccountId) =>
      api.token != null && accountId == pumpingAccountId;

  /// Uploads one chunk. Returns whether the server accepted it, which is what
  /// tells the pump a backlog is actually shrinking.
  Future<bool> _upload(AudioChunk chunk, String pumpingAccountId) async {
    if (!_isCurrent(pumpingAccountId)) return false;
    try {
      await store.setState(chunk.id, LocalChunkState.uploading);
      final response = await api.uploadChunk(
        chunk,
        await store.readBytes(chunk),
      );
      if (!_isCurrent(pumpingAccountId)) return false;
      final receipt = Map<String, dynamic>.from(response['receipt'] as Map);
      await _acceptReceipt(chunk.id, receipt);
      return true;
    } on ApiException catch (error) {
      if (error.status == 401) {
        await store.setState(
          chunk.id,
          LocalChunkState.ready,
          error: 'Authentication expired; upload paused.',
        );
        return false;
      }
      await store.setState(
        chunk.id,
        LocalChunkState.failed,
        error: error.message,
      );
      return false;
    } catch (error) {
      await store.setState(
        chunk.id,
        LocalChunkState.failed,
        error: error.toString(),
      );
      return false;
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
