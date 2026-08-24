import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/models/chunk.dart';
import 'package:neorecall/src/models/recording.dart';
import 'package:neorecall/src/sync/chunk_store.dart';
import 'package:neorecall/src/sync/upload_pump.dart';

class _Api extends NeoRecallApiClient {
  _Api() : super(baseUrl: 'http://test', token: 'token');
  Map<String, dynamic> receipt = <String, dynamic>{};
  List<String> statusIds = <String>[];
  List<String> releasedIds = <String>[];
  bool failSessionSync = false;
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
  Future<int> pendingBytes(String accountId) async => 0;
  @override
  Future<void> close() async {}
}

AudioChunk _chunk() => AudioChunk(
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
  sha256: 'hash',
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

  test('chunks wait until their own session declaration succeeds', () async {
    final api = _Api()..failSessionSync = true;
    final store = _Store(_chunk())
      ..sessions = <LocalRecordingDeclaration>[_session()];
    final pump = UploadPump(store: store, api: api)..accountId = 'account';

    await pump.pump();
    expect(api.statusIds, isEmpty);
    expect(store.audioDeleted, isFalse);
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
