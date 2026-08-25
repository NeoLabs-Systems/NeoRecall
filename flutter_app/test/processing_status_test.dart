import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/models/chunk.dart';
import 'package:neorecall/src/sync/processing_status.dart';

AudioChunk chunk(
  String id,
  LocalChunkState state, {
  String? sessionId,
  String sourceId = 'source',
  int durationMs = 30000,
  int overlapMs = 0,
  Map<String, dynamic>? receipt,
  String? error,
}) => AudioChunk(
  id: id,
  sessionId: sessionId ?? id,
  sourceId: sourceId,
  sequence: id.hashCode.abs(),
  startedAt: DateTime.utc(2026, 8, 25),
  monotonicOffsetMs: 0,
  durationMs: durationMs,
  overlapMs: overlapMs,
  channelLayout: 'mono',
  container: 'm4a',
  codec: 'aac',
  sha256: 'digest-$id',
  state: state,
  createdAt: DateTime.utc(2026, 8, 25),
  receipt: receipt,
  error: error,
);

void main() {
  test('maps the durable ledger to each visible processing stage', () {
    final status = ProcessingStatusSnapshot.fromChunks(
      chunks: <AudioChunk>[
        chunk('ready', LocalChunkState.ready),
        chunk('uploading', LocalChunkState.uploading),
        chunk(
          'queued',
          LocalChunkState.uploaded,
          receipt: const <String, dynamic>{
            'state': 'uploaded',
            'estimatedRemainingMs': 90000,
          },
        ),
        chunk(
          'transcribing',
          LocalChunkState.uploaded,
          receipt: const <String, dynamic>{'state': 'processing'},
        ),
        chunk(
          'finalizing',
          LocalChunkState.uploaded,
          receipt: const <String, dynamic>{
            'state': 'persisted_cleanup_pending',
          },
        ),
      ],
      pendingBytes: 4 * 1024 * 1024,
      localUploadBytes: 2 * 1024 * 1024,
      uploadEta: const Duration(minutes: 2),
      offline: false,
      unmeteredOnly: true,
      networkUnmetered: true,
      deviceIssue: null,
    );

    expect(status.phoneQueued, 1);
    expect(status.uploading, 1);
    expect(status.serverQueued, 1);
    expect(status.transcribing, 1);
    expect(status.finalizing, 1);
    expect(status.totalPending, 5);
    expect(
      status.pendingAudioDuration,
      const Duration(minutes: 2, seconds: 30),
    );
    expect(status.totalAudioDuration, const Duration(minutes: 2, seconds: 30));
    expect(status.activeStage, ProcessingPipelineStage.upload);
    expect(status.eta, const Duration(minutes: 2));
    expect(status.hasIssues, isFalse);
  });

  test(
    'reports policy blockers and manual recovery without losing ETA truth',
    () {
      final status = ProcessingStatusSnapshot.fromChunks(
        chunks: <AudioChunk>[
          chunk(
            'attention',
            LocalChunkState.needsAttention,
            error: 'The server rejected this audio.',
          ),
          chunk(
            'attention-2',
            LocalChunkState.needsAttention,
            error: 'The server rejected this audio.',
          ),
        ],
        pendingBytes: 1024,
        localUploadBytes: 1024,
        uploadEta: null,
        offline: true,
        unmeteredOnly: true,
        networkUnmetered: false,
        deviceIssue: null,
      );

      expect(status.activeStage, ProcessingPipelineStage.phoneQueue);
      expect(status.hasIssues, isTrue);
      expect(status.canRetry, isTrue);
      expect(status.issues.first.message, contains('Offline'));
      expect(status.issues.last.message, 'The server rejected this audio.');
      expect(status.issues.last.count, 2);
      expect(status.eta, isNull);
      expect(status.etaCalibrating, isTrue);
    },
  );

  test('exposes a structured mobile-data override affordance', () {
    final waiting = ProcessingStatusSnapshot.fromChunks(
      chunks: <AudioChunk>[chunk('ready', LocalChunkState.ready)],
      pendingBytes: 1024,
      localUploadBytes: 1024,
      uploadEta: null,
      offline: false,
      unmeteredOnly: true,
      networkUnmetered: false,
      deviceIssue: null,
    );
    final unrestricted = ProcessingStatusSnapshot.fromChunks(
      chunks: <AudioChunk>[chunk('ready', LocalChunkState.ready)],
      pendingBytes: 1024,
      localUploadBytes: 1024,
      uploadEta: null,
      offline: false,
      unmeteredOnly: false,
      networkUnmetered: false,
      deviceIssue: null,
    );

    expect(waiting.waitingForUnmeteredNetwork, isTrue);
    expect(
      waiting.issues.first.message,
      contains('mobile-data uploads are disabled'),
    );
    expect(unrestricted.waitingForUnmeteredNetwork, isFalse);
    expect(unrestricted.issues, isEmpty);
  });

  test('groups legacy transport errors without exposing chunk URLs', () {
    final status = ProcessingStatusSnapshot.fromChunks(
      chunks: <AudioChunk>[
        chunk(
          'failed-1',
          LocalChunkState.failed,
          error:
              'ClientException: Software caused connection abort, uri=https://recall.example/api/chunks/1',
        ),
        chunk(
          'failed-2',
          LocalChunkState.failed,
          error:
              'ClientException: Software caused connection abort, uri=https://recall.example/api/chunks/2',
        ),
      ],
      pendingBytes: 2048,
      localUploadBytes: 2048,
      uploadEta: null,
      offline: false,
      unmeteredOnly: false,
      networkUnmetered: false,
      deviceIssue: null,
    );

    expect(status.issues, hasLength(1));
    expect(status.issues.single.count, 2);
    expect(status.issues.single.message, 'Software caused connection abort');
    expect(status.issues.single.message, isNot(contains('https://')));
  });

  test('many transport chunks remain one user-facing recording session', () {
    final status = ProcessingStatusSnapshot.fromChunks(
      chunks: <AudioChunk>[
        chunk(
          'part-1',
          LocalChunkState.failed,
          sessionId: 'recording',
          error: 'Temporary upload failure',
        ),
        chunk(
          'part-2',
          LocalChunkState.failed,
          sessionId: 'recording',
          durationMs: 30000,
          overlapMs: 2000,
          error: 'Temporary upload failure',
        ),
        chunk(
          'part-3',
          LocalChunkState.uploaded,
          sessionId: 'recording',
          durationMs: 30000,
          overlapMs: 2000,
          receipt: const <String, dynamic>{'state': 'processing'},
        ),
      ],
      pendingBytes: 1024,
      localUploadBytes: 512,
      uploadEta: null,
      offline: false,
      unmeteredOnly: false,
      networkUnmetered: false,
      deviceIssue: null,
    );

    expect(status.totalPending, 1);
    expect(status.phoneQueued, 1);
    expect(status.transcribing, 0);
    expect(status.issues.single.count, 1);
    expect(status.pendingAudioDuration, const Duration(seconds: 86));
  });

  test(
    'watch transfer overrides the ledger stage and exposes real progress',
    () {
      final status =
          const ProcessingStatusSnapshot(
            phoneQueued: 2,
            totalPending: 2,
          ).copyWithTransfer(
            active: true,
            pending: 3,
            pendingSeconds: 95,
            transferred: 2,
            total: 5,
          );

      expect(status.activeStage, ProcessingPipelineStage.watchTransfer);
      expect(status.watchFraction, 0.4);
      expect(status.totalAudioDuration, const Duration(seconds: 95));
      expect(status.complete, isFalse);
    },
  );
}
