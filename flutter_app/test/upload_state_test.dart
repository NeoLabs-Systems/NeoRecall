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
  @override
  Future<List<Map<String, dynamic>>> chunkStatuses(List<String> ids) async {
    statusIds = ids;
    return <Map<String, dynamic>>[receipt];
  }

  @override
  Future<void> releaseChunks(List<String> ids) async {
    releasedIds.addAll(ids);
  }
}

class _Store implements ChunkStore {
  _Store(this.chunk);
  AudioChunk chunk;
  bool audioDeleted = false;
  @override
  Future<List<AudioChunk>> pending({int limit = 100}) async => <AudioChunk>[
    chunk,
  ];
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
  Future<List<LocalRecordingDeclaration>> pendingSessions() async =>
      <LocalRecordingDeclaration>[];
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
  Future<int> pendingBytes() async => 0;
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

void main() {
  test(
    'client releases audio only after every terminal proof field exists',
    () async {
      final api = _Api();
      final store = _Store(_chunk());
      final pump = UploadPump(store: store, api: api);
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
}
