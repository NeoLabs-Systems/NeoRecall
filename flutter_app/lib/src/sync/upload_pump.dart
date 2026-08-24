import 'dart:async';

import '../api_client.dart';
import '../models/chunk.dart';
import 'chunk_store.dart';

class UploadPump {
  UploadPump({
    required this.store,
    required this.api,
    this.onChanged,
    this.uploadAllowed,
  });
  final ChunkStore store;
  final NeoRecallApiClient api;
  final void Function()? onChanged;

  /// Re-evaluated for every pump cycle so an Android metered-capability change
  /// is respected even when the network transport itself did not change.
  Future<bool> Function()? uploadAllowed;
  bool _running = false;
  Timer? _timer;
  String? accountId;

  // How many times the client re-uploads a chunk the server keeps permanently
  // failing (state reupload_required) before parking it as needsAttention.
  // Re-uploading identical bytes fails deterministically, so this bound stops an
  // otherwise-infinite upload/transcribe/fail loop that would never release the
  // local audio. Counts are stored with each local receipt so a process restart
  // cannot reset the bound; terminal success or an explicit manual retry clears
  // them.
  static const int _maxReuploadAttempts = 3;
  static const String _reuploadAttemptKey = '_clientReuploadAttempts';

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

  /// Re-queues a parked chunk and durably resets its re-upload budget.
  Future<void> retry(AudioChunk chunk) async {
    final receipt = <String, dynamic>{...?chunk.receipt}
      ..remove(_reuploadAttemptKey);
    await store.setState(
      chunk.id,
      LocalChunkState.ready,
      receipt: receipt,
      error: '',
    );
  }

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
      final allowed = uploadAllowed;
      if (allowed != null) {
        try {
          if (!await allowed()) return;
        } catch (_) {
          // Uncertain network state is treated as ineligible. Local audio
          // remains durable and the periodic pump will ask again later.
          return;
        }
      }
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
      // A crash can happen after the terminal proof is committed but before the
      // local file is removed. Revisit that durable state on every pump cycle;
      // release remains guarded by the proof validator in both layers.
      final terminal = chunks
          .where((chunk) => chunk.state == LocalChunkState.terminal)
          .toList(growable: false);
      for (final chunk in terminal) {
        final receipt = chunk.receipt;
        if (receipt != null) await _acceptReceipt(chunk, receipt);
      }
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
      await _acceptReceipt(chunk, receipt);
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
      final serverToLocal = <String, AudioChunk>{
        for (final chunk in chunks)
          (chunk.receipt?['chunkId'] as String? ?? chunk.id): chunk,
      };
      final receipts = await api.chunkStatuses(serverToLocal.keys.toList());
      if (!_isCurrent(pumpingAccountId)) return;
      for (final receipt in receipts) {
        final localChunk = serverToLocal[receipt['chunkId'] as String?];
        if (localChunk != null) await _acceptReceipt(localChunk, receipt);
      }
    } catch (_) {
      /* Connectivity failures leave durable audio untouched. */
    }
  }

  Future<void> _acceptReceipt(
    AudioChunk chunk,
    Map<String, dynamic> receipt,
  ) async {
    final id = chunk.id;
    final state = receipt['state'];
    if (provesSafeAudioRelease(receipt)) {
      if (chunk.state != LocalChunkState.terminal) {
        await store.setState(id, LocalChunkState.terminal, receipt: receipt);
      }
      await store.release(id);
      try {
        await api.releaseChunks(<String>[receipt['chunkId'] as String]);
      } catch (_) {}
    } else if (state == 'reupload_required') {
      final previousAttempts =
          (chunk.receipt?[_reuploadAttemptKey] as num?)?.toInt() ?? 0;
      final attempts = previousAttempts + 1;
      final durableReceipt = <String, dynamic>{
        ...receipt,
        _reuploadAttemptKey: attempts,
      };
      if (attempts >= _maxReuploadAttempts) {
        final code = receipt['errorCode'];
        await store.setState(
          id,
          LocalChunkState.needsAttention,
          receipt: durableReceipt,
          error:
              'The server could not transcribe this recording after repeated attempts'
              '${code == null ? '' : ' ($code)'}. Retry when ready.',
        );
      } else {
        await store.setState(
          id,
          LocalChunkState.ready,
          receipt: durableReceipt,
        );
      }
    } else {
      final previousAttempts =
          (chunk.receipt?[_reuploadAttemptKey] as num?)?.toInt() ?? 0;
      await store.setState(
        id,
        LocalChunkState.uploaded,
        receipt: <String, dynamic>{
          ...receipt,
          if (previousAttempts > 0) _reuploadAttemptKey: previousAttempts,
        },
      );
    }
  }
}
