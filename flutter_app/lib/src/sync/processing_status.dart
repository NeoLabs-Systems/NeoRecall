import '../models/chunk.dart';

String _presentableUploadError(String value) {
  final withoutUris = value.replaceAll(
    RegExp(r'(?:,\s*)?uri=\S+', caseSensitive: false),
    '',
  );
  return withoutUris
      .replaceFirst(RegExp(r'^[A-Za-z][A-Za-z0-9_]*Exception:\s*'), '')
      .trim();
}

enum ProcessingPipelineStage {
  watchTransfer,
  phoneQueue,
  upload,
  serverQueue,
  transcription,
  finalizing,
  complete,
}

class ProcessingIssue {
  const ProcessingIssue({
    required this.message,
    this.recoverable = false,
    this.count = 1,
  });
  final String message;
  final bool recoverable;
  final int count;
}

/// Verifiable aggregate of every locally retained recording.
///
/// It deliberately carries facts rather than UI strings so the compact and
/// expanded presentations cannot disagree about what the durable ledger says.
class ProcessingStatusSnapshot {
  const ProcessingStatusSnapshot({
    this.pendingBytes = 0,
    this.pendingAudioDuration = Duration.zero,
    this.watchPending = 0,
    this.watchPendingSeconds = 0,
    this.watchTransferred = 0,
    this.watchTotal = 0,
    this.watchTransferActive = false,
    this.phoneQueued = 0,
    this.uploading = 0,
    this.serverQueued = 0,
    this.transcribing = 0,
    this.finalizing = 0,
    this.totalPending = 0,
    this.eta,
    this.etaCalibrating = false,
    this.waitingForUnmeteredNetwork = false,
    this.issues = const <ProcessingIssue>[],
  });

  final int pendingBytes;
  final Duration pendingAudioDuration;
  final int watchPending;
  final int watchPendingSeconds;
  final int watchTransferred;
  final int watchTotal;
  final bool watchTransferActive;
  final int phoneQueued;
  final int uploading;
  final int serverQueued;
  final int transcribing;
  final int finalizing;
  final int totalPending;
  final Duration? eta;
  final bool etaCalibrating;
  final bool waitingForUnmeteredNetwork;
  final List<ProcessingIssue> issues;

  bool get complete =>
      totalPending == 0 && watchPending == 0 && !watchTransferActive;
  Duration get totalAudioDuration =>
      pendingAudioDuration + Duration(seconds: watchPendingSeconds);
  bool get hasIssues => issues.isNotEmpty;
  bool get canRetry => issues.any((issue) => issue.recoverable);
  double? get watchFraction =>
      watchTotal > 0 ? (watchTransferred / watchTotal).clamp(0.0, 1.0) : null;

  ProcessingPipelineStage get activeStage {
    if (watchTransferActive || watchPending > 0) {
      return ProcessingPipelineStage.watchTransfer;
    }
    if (uploading > 0) return ProcessingPipelineStage.upload;
    if (transcribing > 0) return ProcessingPipelineStage.transcription;
    if (finalizing > 0) return ProcessingPipelineStage.finalizing;
    if (phoneQueued > 0) return ProcessingPipelineStage.phoneQueue;
    if (serverQueued > 0) return ProcessingPipelineStage.serverQueue;
    return ProcessingPipelineStage.complete;
  }

  ProcessingStatusSnapshot copyWithTransfer({
    required bool active,
    required int pending,
    required int pendingSeconds,
    required int transferred,
    required int total,
    List<ProcessingIssue>? issues,
  }) => ProcessingStatusSnapshot(
    pendingBytes: pendingBytes,
    pendingAudioDuration: pendingAudioDuration,
    watchPending: pending,
    watchPendingSeconds: pendingSeconds,
    watchTransferred: transferred,
    watchTotal: total,
    watchTransferActive: active,
    phoneQueued: phoneQueued,
    uploading: uploading,
    serverQueued: serverQueued,
    transcribing: transcribing,
    finalizing: finalizing,
    totalPending: totalPending,
    eta: eta,
    etaCalibrating: etaCalibrating,
    waitingForUnmeteredNetwork: waitingForUnmeteredNetwork,
    issues: issues ?? this.issues,
  );

  static ProcessingStatusSnapshot fromChunks({
    required List<AudioChunk> chunks,
    required int pendingBytes,
    required int localUploadBytes,
    required Duration? uploadEta,
    required bool offline,
    required bool unmeteredOnly,
    required bool networkUnmetered,
    required String? deviceIssue,
  }) {
    var phoneQueued = 0;
    var uploading = 0;
    var serverQueued = 0;
    var transcribing = 0;
    var finalizing = 0;
    var maximumServerEtaMs = 0;
    var serverEstimateMissing = false;
    final issueSessions =
        <String, ({bool recoverable, Set<String> sessionIds})>{};
    void addIssue(
      String message, {
      required String sessionId,
      bool recoverable = false,
    }) {
      final existing = issueSessions[message];
      issueSessions[message] = (
        recoverable: recoverable || (existing?.recoverable ?? false),
        sessionIds: <String>{...?existing?.sessionIds, sessionId},
      );
    }

    final sessions = <String, List<AudioChunk>>{};
    for (final chunk in chunks) {
      if (chunk.state == LocalChunkState.released) continue;
      sessions.putIfAbsent(chunk.sessionId, () => <AudioChunk>[]).add(chunk);
      if (chunk.state == LocalChunkState.uploaded) {
        final estimate = (chunk.receipt?['estimatedRemainingMs'] as num?)
            ?.toInt();
        if (estimate != null && estimate >= 0) {
          if (estimate > maximumServerEtaMs) maximumServerEtaMs = estimate;
        } else {
          serverEstimateMissing = true;
        }
      }
      if (chunk.state == LocalChunkState.needsAttention) {
        addIssue(
          chunk.error?.trim().isNotEmpty == true
              ? _presentableUploadError(chunk.error!)
              : 'A recording needs a manual upload retry.',
          sessionId: chunk.sessionId,
          recoverable: true,
        );
      }
      if (chunk.state == LocalChunkState.failed) {
        addIssue(
          chunk.error?.trim().isNotEmpty == true
              ? _presentableUploadError(chunk.error!)
              : 'A recording upload failed and will retry automatically.',
          sessionId: chunk.sessionId,
        );
      }
    }

    // A recording can contain hundreds of transport chunks at different
    // pipeline positions. Present it exactly once, at its earliest incomplete
    // stage, so internal chunk sizing never leaks into user-facing counts.
    for (final sessionChunks in sessions.values) {
      if (sessionChunks.any(
        (chunk) =>
            chunk.state == LocalChunkState.capturing ||
            chunk.state == LocalChunkState.ready ||
            chunk.state == LocalChunkState.failed ||
            chunk.state == LocalChunkState.needsAttention,
      )) {
        phoneQueued += 1;
      } else if (sessionChunks.any(
        (chunk) => chunk.state == LocalChunkState.uploading,
      )) {
        uploading += 1;
      } else if (sessionChunks.any(
        (chunk) =>
            chunk.state == LocalChunkState.uploaded &&
            chunk.receipt?['state'] != 'processing' &&
            chunk.receipt?['state'] != 'persisted_cleanup_pending',
      )) {
        serverQueued += 1;
      } else if (sessionChunks.any(
        (chunk) =>
            chunk.state == LocalChunkState.uploaded &&
            chunk.receipt?['state'] == 'processing',
      )) {
        transcribing += 1;
      } else {
        finalizing += 1;
      }
    }

    final issues = issueSessions.entries
        .map(
          (entry) => ProcessingIssue(
            message: entry.key,
            recoverable: entry.value.recoverable,
            count: entry.value.sessionIds.length,
          ),
        )
        .toList();

    final waitingForUnmeteredNetwork =
        !offline && unmeteredOnly && !networkUnmetered && localUploadBytes > 0;
    if (offline && localUploadBytes > 0) {
      issues.insert(
        0,
        const ProcessingIssue(
          message: 'Offline — audio remains safely stored on this device.',
        ),
      );
    } else if (waitingForUnmeteredNetwork) {
      issues.insert(
        0,
        const ProcessingIssue(
          message:
              'Waiting for Wi‑Fi because mobile-data uploads are disabled.',
        ),
      );
    }
    if (deviceIssue?.trim().isNotEmpty == true) {
      issues.add(ProcessingIssue(message: deviceIssue!, recoverable: true));
    }

    final serverEta = maximumServerEtaMs > 0
        ? Duration(milliseconds: maximumServerEtaMs)
        : null;
    final eta = switch ((uploadEta, serverEta)) {
      (final Duration upload, final Duration server) =>
        upload > server ? upload : server,
      (final Duration upload, null) => upload,
      (null, final Duration server) => server,
      _ => null,
    };
    final pending = sessions.length;
    final pendingDurationMs = sessions.values.fold<int>(0, (total, chunks) {
      // Sources within one recording may be concurrent. Count each source's
      // non-overlapping audio, then use the longest source as session duration.
      final sourceDurations = <String, int>{};
      for (final chunk in chunks) {
        final contribution = (chunk.durationMs - chunk.overlapMs).clamp(
          0,
          chunk.durationMs,
        );
        sourceDurations.update(
          chunk.sourceId,
          (duration) => duration + contribution,
          ifAbsent: () => contribution,
        );
      }
      final sessionDuration = sourceDurations.values.fold<int>(
        0,
        (longest, duration) => duration > longest ? duration : longest,
      );
      return total + sessionDuration;
    });
    return ProcessingStatusSnapshot(
      pendingBytes: pendingBytes,
      pendingAudioDuration: Duration(milliseconds: pendingDurationMs),
      phoneQueued: phoneQueued,
      uploading: uploading,
      serverQueued: serverQueued,
      transcribing: transcribing,
      finalizing: finalizing,
      totalPending: pending,
      eta: eta,
      etaCalibrating:
          pending > 0 &&
          eta == null &&
          (localUploadBytes > 0 || serverEstimateMissing),
      waitingForUnmeteredNetwork: waitingForUnmeteredNetwork,
      issues: issues,
    );
  }
}
