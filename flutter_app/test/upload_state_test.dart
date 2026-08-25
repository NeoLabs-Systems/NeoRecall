import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/models/chunk.dart';
import 'package:neorecall/src/models/recording.dart';
import 'package:neorecall/src/sync/chunk_store.dart';
import 'package:neorecall/src/sync/pending_audio_preview.dart';
import 'package:neorecall/src/sync/upload_pump.dart';

class _Api extends NeoRecallApiClient {
  _Api() : super(baseUrl: 'http://test', token: 'token');
  Map<String, dynamic> receipt = <String, dynamic>{};
  List<String> statusIds = <String>[];
  List<String> releasedIds = <String>[];
  bool failSessionSync = false;
  final Set<String> rejectedUploadIds = <String>{};
  final List<String> uploadedIds = <String>[];
  @override
  Future<List<Map<String, dynamic>>> chunkStatuses(List<String> ids) async {
    statusIds = ids;
    return <Map<String, dynamic>>[receipt];
  }

  @override
  Future<void> releaseChunks(List<String> ids) async {
    releasedIds.addAll(ids);
  }

  @override
  Future<void> syncSession(LocalRecordingDeclaration session) async {
    if (failSessionSync) {
      throw const ApiException(503, 'UNAVAILABLE', 'server unavailable');
    }
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    AudioChunk chunk,
    Uint8List bytes,
  ) async {
    if (rejectedUploadIds.contains(chunk.id)) {
      throw const ApiException(503, 'UNAVAILABLE', 'temporary failure');
    }
    uploadedIds.add(chunk.id);
    return <String, dynamic>{
      'receipt': <String, dynamic>{
        'chunkId': 'server-${chunk.id}',
        'state': 'uploaded',
      },
    };
  }
}

class _Store implements ChunkStore {
  _Store(this.chunk);
  AudioChunk chunk;
  bool audioDeleted = false;
  final List<String> requestedAccounts = <String>[];
  List<LocalRecordingDeclaration> sessions = <LocalRecordingDeclaration>[];
  @override
  Future<List<AudioChunk>> pending(String accountId, {int limit = 100}) async {
    requestedAccounts.add(accountId);
    return <AudioChunk>[chunk];
  }

  @override
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  }) async {
    if (id != chunk.id) throw StateError('Unknown local chunk ID: $id');
    chunk = chunk.copyWith(state: state, receipt: receipt, error: error);
  }

  @override
  Future<void> release(String id) async {
    if (id != chunk.id) throw StateError('Unknown local chunk ID: $id');
    audioDeleted = true;
    chunk = chunk.copyWith(state: LocalChunkState.released);
  }

  @override
  Future<void> claimLegacySessions(String accountId) async {}
  @override
  Future<List<LocalRecordingDeclaration>> pendingSessions(
    String accountId,
  ) async => sessions;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> put(AudioChunk chunk, Uint8List bytes) async {}
  @override
  Future<bool> hasMatchingChunk(String id, String sha256) async => false;
  @override
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes) async {}
  @override
  Future<void> clearPartial(String sourceId) async {}
  @override
  Future<void> putSession(LocalRecordingDeclaration session) async {}
  @override
  Future<void> markSessionSynced(String id) async {}
  @override
  Future<Uint8List> readBytes(AudioChunk chunk) async => Uint8List(0);
  @override
  Future<int> storedBytes(AudioChunk chunk) async => 0;
  @override
  Future<int> pendingBytes(String accountId) async => 0;
  @override
  Future<void> close() async {}
}

class _QueueStore implements ChunkStore {
  _QueueStore(this.chunks);
  final List<AudioChunk> chunks;

  AudioChunk _find(String id) => chunks.firstWhere((chunk) => chunk.id == id);

  @override
  Future<List<AudioChunk>> pending(String accountId, {int limit = 100}) async =>
      chunks
          .where((chunk) => chunk.state != LocalChunkState.released)
          .take(limit)
          .toList();

  @override
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  }) async {
    final index = chunks.indexWhere((chunk) => chunk.id == id);
    chunks[index] = chunks[index].copyWith(
      state: state,
      receipt: receipt,
      error: error,
    );
  }

  @override
  Future<Uint8List> readBytes(AudioChunk chunk) async => Uint8List(0);
  @override
  Future<int> storedBytes(AudioChunk chunk) async => 0;
  @override
  Future<int> pendingBytes(String accountId) async => 0;
  @override
  Future<List<LocalRecordingDeclaration>> pendingSessions(
    String accountId,
  ) async => const <LocalRecordingDeclaration>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> put(AudioChunk chunk, Uint8List bytes) async {}
  @override
  Future<bool> hasMatchingChunk(String id, String sha256) async => false;
  @override
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes) async {}
  @override
  Future<void> clearPartial(String sourceId) async {}
  @override
  Future<void> putSession(LocalRecordingDeclaration session) async {}
  @override
  Future<void> claimLegacySessions(String accountId) async {}
  @override
  Future<void> markSessionSynced(String id) async {}
  @override
  Future<void> release(String id) async {
    final chunk = _find(id);
    await setState(chunk.id, LocalChunkState.released);
  }

  @override
  Future<void> close() async {}
}

AudioChunk _chunk({
  String hash =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
}) => AudioChunk(
  id: 'chunk',
  sessionId: 'session',
  sourceId: 'source',
  sequence: 0,
  startedAt: DateTime.utc(2026, 7, 13),
  monotonicOffsetMs: 0,
  durationMs: 30000,
  overlapMs: 0,
  channelLayout: 'mono',
  container: 'wav',
  codec: 'pcm_s16le',
  sha256: hash,
  state: LocalChunkState.uploaded,
  createdAt: DateTime.utc(2026, 7, 13),
  receipt: const <String, dynamic>{
    'chunkId': 'server-chunk',
    'state': 'uploaded',
  },
);

LocalRecordingDeclaration _session() => LocalRecordingDeclaration(
  id: 'session',
  accountId: 'account',
  sourceId: 'source',
  deviceId: 'device',
  deviceClientUuid: 'device-client',
  deviceName: 'Device',
  platform: 'android',
  startedAt: DateTime.utc(2026, 7, 13),
  timezone: 'UTC',
  consentAttestedAt: DateTime.utc(2026, 7, 13),
  sourceKind: 'microphone',
  channelLayout: 'mono',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zero local upload bytes do not claim a zero server ETA', () {
    final pump = UploadPump(store: _Store(_chunk()), api: _Api());

    expect(pump.estimateUploadDuration(0), isNull);
  });

  test('pending playback metadata stays lazy and account scoped', () async {
    final store = _Store(_chunk());
    final controller = NeoRecallController(store: store, api: _Api())
      ..accountId = 'account';
    addTearDown(controller.dispose);

    final recordings = await controller.loadPendingAudioRecordings();

    expect(store.requestedAccounts, <String>['account']);
    expect(recordings, hasLength(1));
    expect(recordings.single.duration, const Duration(seconds: 30));
    expect(recordings.single.stage, PendingAudioPlaybackStage.serverProcessing);
    expect(recordings.single.parts.single.id, 'chunk');
    expect(await controller.readPendingAudioPart('chunk'), isEmpty);
    expect(store.requestedAccounts, <String>['account', 'account']);
  });

  test(
    'terminal proof validation rejects incomplete and malformed receipts',
    () {
      expect(provesSafeAudioRelease(null), isFalse);
      expect(
        provesSafeAudioRelease(<String, dynamic>{
          'chunkId': 'server-chunk',
          'state': 'transcribed',
          'persistedAt': 'not-a-timestamp',
          'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
          'transcriptSha256': 'hash',
        }),
        isFalse,
      );
      expect(
        provesSafeAudioRelease(<String, dynamic>{
          'chunkId': 'server-chunk',
          'state': 'silent',
          'persistedAt': '2026-07-13T10:00:00Z',
          'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
          'transcriptSha256': 'hash',
        }),
        isTrue,
      );
    },
  );

  test(
    'client releases audio only after every terminal proof field exists',
    () async {
      final api = _Api();
      final store = _Store(_chunk());
      final pump = UploadPump(store: store, api: api);
      pump.accountId = 'account';
      api.receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'transcribed',
        'persistedAt': '2026-07-13T10:00:00Z',
        'transcriptSha256': 'hash',
      };
      await pump.pump();
      expect(api.statusIds, <String>['server-chunk']);
      expect(store.audioDeleted, isFalse);
      api.receipt = <String, dynamic>{
        ...api.receipt,
        'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
      };
      await pump.pump();
      expect(store.audioDeleted, isTrue);
      expect(api.releasedIds, <String>['server-chunk']);
    },
  );

  test(
    'terminal forwarding must succeed before local audio is released',
    () async {
      final api = _Api();
      final store = _Store(_chunk());
      var forwarded = false;
      var attempts = 0;
      final pump = UploadPump(store: store, api: api)
        ..accountId = 'account'
        ..onTerminalReceipt = (chunk, receipt) async {
          attempts += 1;
          return forwarded;
        };
      api.receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'silent',
        'persistedAt': '2026-07-13T10:00:00Z',
        'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
        'transcriptSha256': 'hash',
      };

      await pump.pump();
      expect(store.chunk.state, LocalChunkState.terminal);
      expect(store.audioDeleted, isFalse);
      forwarded = true;
      await pump.pump();
      expect(attempts, 2);
      expect(store.audioDeleted, isTrue);
    },
  );

  test(
    'upload pump never reads a ledger without an authenticated owner',
    () async {
      final api = _Api();
      final store = _Store(_chunk());
      final pump = UploadPump(store: store, api: api);

      await pump.pump();
      expect(store.requestedAccounts, isEmpty);
      expect(api.statusIds, isEmpty);

      pump.accountId = 'account-b';
      api.receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'uploaded',
      };
      await pump.pump();
      expect(store.requestedAccounts, <String>['account-b']);
    },
  );

  test('upload policy blocks all server work without touching audio', () async {
    final api = _Api();
    final store = _Store(_chunk());
    final pump = UploadPump(
      store: store,
      api: api,
      uploadAllowed: () async => false,
    )..accountId = 'account';

    await pump.pump();

    expect(store.requestedAccounts, isEmpty);
    expect(api.statusIds, isEmpty);
    expect(store.audioDeleted, isFalse);
  });

  test('one-time metered override uploads the current queued audio', () async {
    final api = _Api();
    final store = _Store(_chunk().copyWith(state: LocalChunkState.ready));
    final pump = UploadPump(
      store: store,
      api: api,
      uploadAllowed: () async => false,
    )..accountId = 'account';

    await pump.pump();
    expect(api.uploadedIds, isEmpty);

    final count = await pump.uploadQueuedAudioOnMeteredOnce();

    expect(count, 1);
    expect(api.uploadedIds, <String>['chunk']);
    expect(store.chunk.state, LocalChunkState.uploaded);
    expect(pump.meteredUploadOverrideActive, isFalse);
  });

  test(
    'an active upload drain acquires and releases background ownership',
    () async {
      final activity = <bool>[];
      final api = _Api();
      final pump =
          UploadPump(
              store: _Store(_chunk().copyWith(state: LocalChunkState.ready)),
              api: api,
            )
            ..accountId = 'account'
            ..onUploadActivity = (active) async => activity.add(active);

      await pump.pump();
      expect(activity, <bool>[true]);
      api.receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'silent',
        'persistedAt': '2026-07-13T10:00:00Z',
        'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
        'transcriptSha256': 'hash',
      };
      await pump.pump();
      await pump.pump();

      expect(activity, <bool>[true, false]);
    },
  );

  test('local integrity mismatch never sends audio to the server', () async {
    final api = _Api();
    final store = _Store(
      _chunk(
        hash:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ).copyWith(state: LocalChunkState.ready),
    );
    final pump = UploadPump(store: store, api: api)..accountId = 'account';

    await pump.pump();

    expect(api.uploadedIds, isEmpty);
    expect(store.chunk.state, LocalChunkState.needsAttention);
    expect(store.audioDeleted, isFalse);
    expect(store.chunk.error, contains('integrity verification failed'));
  });

  test('failed chunks cannot block untouched chunks behind them', () async {
    final createdAt = DateTime.utc(2026, 7, 13);
    final chunks = List<AudioChunk>.generate(
      5,
      (index) => AudioChunk(
        id: 'chunk-$index',
        sessionId: 'session',
        sourceId: 'source',
        sequence: index,
        startedAt: createdAt.add(Duration(seconds: index * 30)),
        monotonicOffsetMs: index * 30000,
        durationMs: 30000,
        overlapMs: 0,
        channelLayout: 'mono',
        container: 'wav',
        codec: 'pcm_s16le',
        sha256:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        state: LocalChunkState.ready,
        createdAt: createdAt.add(Duration(seconds: index)),
      ),
    );
    final store = _QueueStore(chunks);
    final api = _Api()
      ..rejectedUploadIds.addAll(<String>{'chunk-0', 'chunk-1', 'chunk-2'});
    final pump = UploadPump(store: store, api: api)..accountId = 'account';

    await pump.pump();
    await pump.pump();

    expect(api.uploadedIds, containsAll(<String>['chunk-3', 'chunk-4']));
    expect(
      chunks.where((chunk) => chunk.state == LocalChunkState.failed).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('chunks wait until their own session declaration succeeds', () async {
    final api = _Api()..failSessionSync = true;
    final store = _Store(_chunk())
      ..sessions = <LocalRecordingDeclaration>[_session()];
    final pump = UploadPump(store: store, api: api)..accountId = 'account';

    await pump.pump();
    expect(api.statusIds, isEmpty);
    expect(store.audioDeleted, isFalse);
    expect(pump.processingIssue, contains('Server session setup failed'));
    expect(pump.processingIssue, contains('server unavailable'));
  });

  test(
    'a crash between terminal state and file release is recovered',
    () async {
      final receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'transcribed',
        'persistedAt': '2026-07-13T10:00:00Z',
        'serverAudioDeletedAt': '2026-07-13T10:00:01Z',
        'transcriptSha256': 'hash',
      };
      final api = _Api();
      final store = _Store(
        _chunk().copyWith(state: LocalChunkState.terminal, receipt: receipt),
      );
      final pump = UploadPump(store: store, api: api)..accountId = 'account';

      await pump.pump();

      expect(store.audioDeleted, isTrue);
      expect(api.releasedIds, <String>['server-chunk']);
    },
  );

  test('re-upload limits survive pump and process restarts', () async {
    final api = _Api()
      ..receipt = <String, dynamic>{
        'chunkId': 'server-chunk',
        'state': 'reupload_required',
        'errorCode': 'DECODE_FAILED',
      };
    final store = _Store(_chunk());

    for (var attempt = 0; attempt < 3; attempt += 1) {
      final pump = UploadPump(store: store, api: api)..accountId = 'account';
      await pump.pump();
      if (attempt < 2) {
        expect(store.chunk.state, LocalChunkState.ready);
        // A successful idempotent PUT would return the chunk to uploaded before
        // the next status poll. Preserve its durable receipt to simulate a full
        // process restart between attempts.
        store.chunk = store.chunk.copyWith(state: LocalChunkState.uploaded);
      }
    }

    expect(store.chunk.state, LocalChunkState.needsAttention);
    expect(store.audioDeleted, isFalse);
  });
}
