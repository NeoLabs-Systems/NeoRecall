import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/src/models/chunk.dart';

void main() {
  test('gzip hash rejection falls back once to identity encoding', () async {
    final encodings = <String?>[];
    var uploadAttempts = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/meta') {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'capabilities': <String, dynamic>{'gzipAudioUpload': true},
          }),
          200,
        );
      }
      uploadAttempts += 1;
      encodings.add(request.headers['x-audio-content-encoding']);
      if (uploadAttempts == 1) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'HASH_MISMATCH',
              'message': 'The uploaded audio does not match X-Chunk-Sha256.',
            },
          }),
          422,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'receipt': <String, dynamic>{
            'chunkId': 'server-chunk',
            'state': 'uploaded',
          },
        }),
        202,
      );
    });
    final api = NeoRecallApiClient(
      baseUrl: 'https://recall.example',
      token: 'token',
      client: client,
    );
    final bytes = Uint8List(128 * 1024);

    await api.discoverServerCapabilities();
    final response = await api.uploadChunk(_chunk(bytes), bytes);

    expect(response['receipt'], isA<Map>());
    expect(encodings, <String?>['gzip', null]);
    expect(api.supportsGzipAudioUpload, isFalse);
  });

  test('transport failures expose one stable retryable message', () async {
    final api = NeoRecallApiClient(
      baseUrl: 'https://recall.example',
      token: 'token',
      client: MockClient((_) async {
        throw http.ClientException(
          'Software caused connection abort',
          Uri.parse('https://recall.example/private/chunk/id'),
        );
      }),
    );
    final bytes = Uint8List(1024);

    await expectLater(
      api.uploadChunk(_chunk(bytes), bytes),
      throwsA(
        isA<ApiException>()
            .having(
              (error) => error.code,
              'code',
              'UPLOAD_CONNECTION_INTERRUPTED',
            )
            .having(
              (error) => error.message,
              'message',
              'The connection was interrupted while uploading. It will retry automatically.',
            ),
      ),
    );
  });

  test(
    'large receipt ledgers follow the server-advertised batch limit',
    () async {
      final requestedBatches = <List<String>>[];
      final api = NeoRecallApiClient(
        baseUrl: 'https://recall.example',
        token: 'token',
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/meta') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'capabilities': <String, dynamic>{},
                'limits': <String, dynamic>{'chunkReceiptBatch': 2},
              }),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final ids = (body['chunkIds'] as List).cast<String>();
          requestedBatches.add(ids);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'receipts': ids
                  .map((id) => <String, dynamic>{'chunkId': id})
                  .toList(),
            }),
            200,
          );
        }),
      );

      await api.discoverServerCapabilities();
      final receipts = await api.chunkStatuses(<String>[
        '1',
        '2',
        '3',
        '4',
        '5',
      ]);

      expect(api.maxChunkReceiptBatch, 2);
      expect(requestedBatches, <List<String>>[
        <String>['1', '2'],
        <String>['3', '4'],
        <String>['5'],
      ]);
      expect(receipts, hasLength(5));
    },
  );
}

AudioChunk _chunk(Uint8List bytes) => AudioChunk(
  id: '00000000-0000-4000-8000-000000000001',
  sessionId: '00000000-0000-4000-8000-000000000002',
  sourceId: '00000000-0000-4000-8000-000000000003',
  sequence: 10,
  startedAt: DateTime.utc(2026, 8, 25, 13),
  monotonicOffsetMs: 300000,
  durationMs: 30000,
  overlapMs: 2000,
  channelLayout: 'mono',
  container: 'wav',
  codec: 'pcm_s16le',
  sha256: sha256.convert(bytes).toString(),
  state: LocalChunkState.ready,
  createdAt: DateTime.utc(2026, 8, 25, 13),
);
