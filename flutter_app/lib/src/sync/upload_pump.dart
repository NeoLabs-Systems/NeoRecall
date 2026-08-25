import 'dart:async';

import 'package:crypto/crypto.dart';

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

  /// Keeps the platform background runtime alive only while an eligible queue
  /// is actively draining. Failures in this advisory callback never affect the
  /// durable upload state machine.
  Future<void> Function(bool active)? onUploadActivity;
  bool _uploadActivityActive = false;

  // A one-time metered-network override is scoped to the exact local chunks
  // that existed when the user requested it. Newly recorded audio therefore
  // continues to obey the saved Wi-Fi-only policy.
  static const int _ledgerScanLimit = 10000;
  final Set<String> _meteredOverrideChunkIds = <String>{};
  String? _meteredOverrideAccountId;

  bool get meteredUploadOverrideActive =>
      _meteredOverrideAccountId == accountId &&
      _meteredOverrideChunkIds.isNotEmpty;

  /// A source may need to durably forward the receipt before its phone-side
  /// copy can be released (Wear OS does this to release the watch original).
  Future<bool> Function(AudioChunk chunk, Map<String, dynamic> receipt)?
  onTerminalReceipt;
  bool _running = false;
  Timer? _timer;
  String? _accountId;
  String? get accountId => _accountId;
  set accountId(String? value) {
    if (_accountId == value) return;
    _accountId = value;
    _clearMeteredOverride();
    unawaited(_setUploadActivity(false));
  }

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
  static const double _throughputSmoothing = 0.25;

  double? _uploadBytesPerSecond;
  String? processingIssue;

  /// ETA derived only from successful uploads during this process. Until the
  /// first sample exists the UI reports that it is calibrating.
  Duration? estimateUploadDuration(int bytes) {
    final rate = _uploadBytesPerSecond;
    // Zero local bytes means uploading is complete, not that the server-side
    // transcription backlog has a zero-second ETA. Returning null lets receipt
    // estimates (or the truthful "calibrating" state) own the server phase.
    if (bytes <= 0) return null;
    if (rate == null || rate <= 0) return null;
    return Duration(milliseconds: (bytes * 1000 / rate).ceil());
  }

  Timer? _drainTimer;
  bool _backlogDraining = false;
  bool _manualPumpRequested = false;

  /// Permits one drain of the uploadable backlog currently retained locally,
  /// even when the normal network policy rejects a metered connection.
  ///
  /// The returned count is the number of snapshotted chunks. Each chunk gets
  /// one upload attempt under this override; failed chunks return to the normal
  /// policy afterward and remain durable for a later retry.
  Future<int> uploadQueuedAudioOnMeteredOnce() async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null || api.token == null) return 0;
    final chunks = await store.pending(ownerAccountId, limit: _ledgerScanLimit);
    final eligible = chunks.where(
      (chunk) => <LocalChunkState>{
        LocalChunkState.ready,
        LocalChunkState.uploading,
        LocalChunkState.failed,
      }.contains(chunk.state),
    );
    _meteredOverrideAccountId = ownerAccountId;
    _meteredOverrideChunkIds
      ..clear()
      ..addAll(eligible.map((chunk) => chunk.id));
    final snapshotCount = _meteredOverrideChunkIds.length;
    onChanged?.call();
    if (_meteredOverrideChunkIds.isNotEmpty) {
      // A request racing an existing cycle is replayed immediately after that
      // cycle finishes; otherwise wait for the first upload attempt here so the
      // caller's progress state reflects real work rather than just scheduling.
      if (_running) {
        _manualPumpRequested = true;
      } else {
        await pump();
      }
    }
    return snapshotCount;
  }

  void _clearMeteredOverride() {
    _meteredOverrideAccountId = null;
    _meteredOverrideChunkIds.clear();
  }

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
    unawaited(_setUploadActivity(false));
  }

  Future<void> _setUploadActivity(bool active) async {
    if (_uploadActivityActive == active) return;
    _uploadActivityActive = active;
    try {
      await onUploadActivity?.call(active);
    } catch (_) {
      // Platform hosting is best-effort. The ledger and foreground upload must
      // continue even if an OEM rejects a background-host transition.
    }
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
    processingIssue = null;
    var awaitingServerReceipts = false;
    try {
      var policyAllowed = true;
      final allowed = uploadAllowed;
      if (allowed != null) {
        try {
          policyAllowed = await allowed();
        } catch (_) {
          // Uncertain network state is treated as ineligible. Local audio
          // remains durable and the periodic pump will ask again later.
          policyAllowed = false;
        }
      }
      final meteredOverride =
          !policyAllowed &&
          _meteredOverrideAccountId == pumpingAccountId &&
          _meteredOverrideChunkIds.isNotEmpty;
      if (policyAllowed && _meteredOverrideAccountId == pumpingAccountId) {
        // The saved policy (or an unmetered network) now permits normal
        // draining, so the exceptional authorization is no longer needed.
        _clearMeteredOverride();
      }
      if (!policyAllowed && !meteredOverride) return;
      await _setUploadActivity(true);
      final sessions = await store.pendingSessions(pumpingAccountId);
      final blockedSessionIds = <String>{};
      for (final session in sessions) {
        if (!_isCurrent(pumpingAccountId)) return;
        try {
          await api.syncSession(session);
          if (!_isCurrent(pumpingAccountId)) return;
          await store.markSessionSynced(session.id);
        } catch (error) {
          // Keep trying other sessions/devices. Network or one bad session
          // must not freeze the entire multi-device upload ledger.
          blockedSessionIds.add(session.id);
          processingIssue = _issueMessage('Server session setup failed', error);
          continue;
        }
      }
      if (!_isCurrent(pumpingAccountId)) return;
      final chunks = await store.pending(
        pumpingAccountId,
        limit: _ledgerScanLimit,
      );
      if (meteredOverride) {
        final stillUploadable = chunks
            .where(
              (chunk) => <LocalChunkState>{
                LocalChunkState.ready,
                LocalChunkState.uploading,
                LocalChunkState.failed,
              }.contains(chunk.state),
            )
            .map((chunk) => chunk.id)
            .toSet();
        // A normal cycle may have accepted a snapshotted chunk just before the
        // metered request raced in. Reconcile those IDs so completed uploads do
        // not keep an otherwise-finished override alive.
        _meteredOverrideChunkIds.retainAll(stillUploadable);
      }
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
      awaitingServerReceipts = uploaded.isNotEmpty;
      if (uploaded.isNotEmpty) await _poll(uploaded, pumpingAccountId);
      final ready = chunks
          .where(
            (chunk) =>
                !blockedSessionIds.contains(chunk.sessionId) &&
                (!meteredOverride ||
                    _meteredOverrideChunkIds.contains(chunk.id)) &&
                <LocalChunkState>{
                  LocalChunkState.ready,
                  // A process crash can leave this durable state behind. The PUT
                  // is idempotent, so retrying is the only safe recovery action.
                  LocalChunkState.uploading,
                  LocalChunkState.failed,
                }.contains(chunk.state),
          )
          .toList(growable: false);
      // A transiently failing old chunk must not sit at the front forever.
      // Crash-recovery uploads go first, new ready work follows, and failures
      // are retried only after every untouched chunk has had a chance.
      int uploadPriority(AudioChunk chunk) => switch (chunk.state) {
        LocalChunkState.uploading => 0,
        LocalChunkState.ready => 1,
        LocalChunkState.failed => 2,
        _ => 3,
      };
      ready.sort((left, right) {
        final byPriority = uploadPriority(
          left,
        ).compareTo(uploadPriority(right));
        return byPriority != 0
            ? byPriority
            : left.createdAt.compareTo(right.createdAt);
      });
      final batch = ready.take(_uploadConcurrency).toList(growable: false);
      final results = await Future.wait(
        batch.map((chunk) => _upload(chunk, pumpingAccountId)),
      );
      awaitingServerReceipts =
          awaitingServerReceipts || results.any((uploaded) => uploaded);
      if (meteredOverride && _meteredOverrideAccountId == pumpingAccountId) {
        // The override authorizes one attempt per snapshotted chunk. Success is
        // not required before removing the authorization: audio remains local
        // and a failed retry must not consume mobile data indefinitely.
        _meteredOverrideChunkIds.removeAll(batch.map((chunk) => chunk.id));
        if (_meteredOverrideChunkIds.isEmpty || batch.isEmpty) {
          _clearMeteredOverride();
        }
      }
      // Only keep draining while the backlog is both larger than one batch and
      // actually shrinking; otherwise the idle timer owns the retry cadence.
      final untouchedWork = ready
          .skip(batch.length)
          .any((chunk) => chunk.state != LocalChunkState.failed);
      _backlogDraining = meteredOverride
          ? _meteredOverrideChunkIds.isNotEmpty
          : ready.length > batch.length &&
                (results.any((uploaded) => uploaded) || untouchedWork);
    } finally {
      _running = false;
      onChanged?.call();
      if (_manualPumpRequested) {
        _manualPumpRequested = false;
        unawaited(Future<void>.delayed(Duration.zero, pump));
      } else if (_backlogDraining) {
        _scheduleDrain();
      } else if (!awaitingServerReceipts) {
        await _setUploadActivity(false);
      }
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
      onChanged?.call();
      final bytes = await store.readBytes(chunk);
      final storedHash = sha256.convert(bytes).toString();
      if (storedHash != chunk.sha256) {
        const message =
            'Local audio integrity verification failed. The original is still protected on this device.';
        processingIssue = message;
        await store.setState(
          chunk.id,
          LocalChunkState.needsAttention,
          error: message,
        );
        return false;
      }
      final timer = Stopwatch()..start();
      final response = await api.uploadChunk(chunk, bytes);
      timer.stop();
      if (timer.elapsedMicroseconds > 0) {
        final sample = bytes.length * 1000000 / timer.elapsedMicroseconds;
        final previous = _uploadBytesPerSecond;
        _uploadBytesPerSecond = previous == null
            ? sample
            : previous * (1 - _throughputSmoothing) +
                  sample * _throughputSmoothing;
      }
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
    } catch (error) {
      /* Connectivity failures leave durable audio untouched. */
      processingIssue = _issueMessage(
        'Could not refresh server processing status',
        error,
      );
    }
  }

  String _issueMessage(String context, Object error) {
    final detail = error is ApiException ? error.message : error.toString();
    final clean = detail
        .replaceFirst(RegExp(r'^(Bad state|StateError|Exception):\s*'), '')
        .trim();
    return clean.isEmpty ? '$context.' : '$context: $clean';
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
      final forward = onTerminalReceipt;
      if (forward != null) {
        try {
          if (!await forward(chunk, receipt)) return;
        } catch (_) {
          // The terminal receipt stays durable and is retried next pump. Audio
          // remains in both ownership ledgers until forwarding succeeds.
          return;
        }
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
