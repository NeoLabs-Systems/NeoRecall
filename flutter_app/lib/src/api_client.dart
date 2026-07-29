import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'models/chunk.dart';
import 'models/recording.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, [this.details]);
  final int status;
  final String code;
  final String message;
  final dynamic details;
  @override
  String toString() => message;
}

class NeoRecallApiClient {
  NeoRecallApiClient({required String baseUrl, this.token, http.Client? client})
    : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
      _client = client ?? http.Client();
  String baseUrl;
  String? token;
  final http.Client _client;

  Map<String, String> get _headers => <String, String>{
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Uri _resolve(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    if (baseUrl.isEmpty) return Uri.parse(normalizedPath);
    return Uri.parse('$baseUrl$normalizedPath');
  }

  Future<dynamic> request(String method, String path, {Object? body}) async {
    final uri = _resolve(path);
    final headers = <String, String>{
      ..._headers,
      if (body != null) 'Content-Type': 'application/json',
    };
    late http.Response response;
    final encoded = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        response = await _client.get(uri, headers: headers);
      case 'POST':
        response = await _client.post(uri, headers: headers, body: encoded);
      case 'PUT':
        response = await _client.put(uri, headers: headers, body: encoded);
      case 'PATCH':
        response = await _client.patch(uri, headers: headers, body: encoded);
      case 'DELETE':
        response = await _client.delete(uri, headers: headers, body: encoded);
      default:
        throw ArgumentError.value(method, 'method');
    }
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final payload = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = payload is Map ? payload['error'] as Map? : null;
      throw ApiException(
        response.statusCode,
        error?['code'] as String? ?? 'HTTP_ERROR',
        error?['message'] as String? ?? 'Request failed.',
        error?['details'],
      );
    }
    return payload;
  }

  Future<Map<String, dynamic>> uploadChunk(
    AudioChunk chunk,
    Uint8List bytes,
  ) async {
    final request = http.MultipartRequest(
      'PUT',
      _resolve(
        '/api/v1/ingest/sessions/${chunk.sessionId}/sources/${chunk.sourceId}/chunks/${chunk.sequence}',
      ),
    );
    request.headers.addAll(<String, String>{
      ..._headers,
      'Idempotency-Key': chunk.id,
      'X-Chunk-Sha256': chunk.sha256,
      'X-Chunk-Duration-Ms': '${chunk.durationMs}',
      'X-Chunk-Overlap-Ms': '${chunk.overlapMs}',
      'X-Channel-Layout': chunk.channelLayout,
      'X-Monotonic-Offset-Ms': '${chunk.monotonicOffsetMs}',
      'X-Device-Started-At': chunk.startedAt.toUtc().toIso8601String(),
      'X-Audio-Container': chunk.container,
      'X-Audio-Codec': chunk.codec,
      if (chunk.isFinal) 'X-Final-Chunk': 'true',
    });
    request.files.add(
      http.MultipartFile.fromBytes(
        'audio',
        bytes,
        filename: '${chunk.id}.${chunk.container}',
      ),
    );
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    return Map<String, dynamic>.from(_decode(response) as Map);
  }

  Future<List<Map<String, dynamic>>> chunkStatuses(List<String> ids) async {
    final payload =
        await request(
              'POST',
              '/api/v1/ingest/chunks/status',
              body: <String, dynamic>{'chunkIds': ids},
            )
            as Map;
    return (payload['receipts'] as List)
        .cast<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  Future<void> releaseChunks(List<String> ids) async => request(
    'POST',
    '/api/v1/ingest/chunks/released',
    body: <String, dynamic>{'chunkIds': ids},
  );

  Future<void> measureDeviceClock(String deviceId) async {
    final clientSentAt = DateTime.now().toUtc();
    final first =
        await request(
              'POST',
              '/api/v1/devices/$deviceId/heartbeat',
              body: <String, dynamic>{
                'clientSentAt': clientSentAt.toIso8601String(),
              },
            )
            as Map;
    final clientReceivedAt = DateTime.now().toUtc();
    final serverReceivedAt = DateTime.parse(
      first['serverReceivedAt'] as String,
    );
    final serverSentAt = DateTime.parse(first['serverSentAt'] as String);
    final networkMs =
        clientReceivedAt.difference(clientSentAt).inMicroseconds -
        serverSentAt.difference(serverReceivedAt).inMicroseconds;
    final serverMinusClientMicroseconds =
        (serverReceivedAt.difference(clientSentAt).inMicroseconds +
            serverSentAt.difference(clientReceivedAt).inMicroseconds) /
        2;
    // The server corrects device timestamps by subtracting this value, so
    // persist client-minus-server rather than the conventional NTP theta.
    final clientMinusServerMs = -serverMinusClientMicroseconds / 1000;
    await request(
      'POST',
      '/api/v1/devices/$deviceId/heartbeat',
      body: <String, dynamic>{
        'clientSentAt': clientReceivedAt.toIso8601String(),
        'clockOffsetMs': clientMinusServerMs,
        'clockRttMs': (networkMs / 1000).clamp(0, double.infinity),
      },
    );
  }

  Future<void> syncSession(LocalRecordingDeclaration session) async {
    await request(
      'POST',
      '/api/v1/devices',
      body: <String, dynamic>{
        'id': session.deviceId,
        'clientUuid': session.deviceClientUuid,
        'name': session.deviceName,
        'platform': session.platform,
        'kind': session.platform == 'web'
            ? 'browser'
            : (session.platform == 'android' || session.platform == 'ios')
                ? 'mobile'
                : 'desktop',
        'capabilities': <String, dynamic>{
          'microphone': session.sourceKind != 'system',
          'systemAudio': <String>{
            'system',
            'combined',
          }.contains(session.sourceKind),
        },
      },
    );
    try {
      await measureDeviceClock(session.deviceId);
    } catch (_) {
      // Clock telemetry must never block durable audio synchronization.
    }
    await request(
      'POST',
      '/api/v1/ingest/sessions',
      body: <String, dynamic>{
        'id': session.id,
        'deviceId': session.deviceId,
        'clientUuid': session.id,
        'startedAt': session.startedAt.toUtc().toIso8601String(),
        'timezone': session.timezone,
        'consentAttestedAt': session.consentAttestedAt
            .toUtc()
            .toIso8601String(),
        'sources': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': session.sourceId,
            'clientUuid': session.sourceId,
            'kind': session.sourceKind,
            'channelLayout': session.channelLayout,
            'sampleRate': session.sampleRate,
            'sampleFormat': 'pcm_s16le',
            'metadata': <String, dynamic>{
              'actualSampleRate': session.sampleRate,
              'platform': session.platform,
            },
          },
        ],
      },
    );
    if (session.endedAt != null && session.finalSequence != null) {
      await request(
        'PATCH',
        '/api/v1/ingest/sessions/${session.id}',
        body: <String, dynamic>{
          'endedAt': session.endedAt!.toUtc().toIso8601String(),
          'status': session.interrupted ? 'interrupted' : 'ended',
          'sources': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': session.sourceId,
              'finalSequence': session.finalSequence,
            },
          ],
        },
      );
    }
  }

  Future<void> importAudio({
    required String importId,
    required Uint8List bytes,
    required String filename,
    required String contentType,
    DateTime? captureTime,
  }) async {
    final digest = sha256.convert(bytes).toString();
    final declared =
        await request(
              'POST',
              '/api/v1/imports',
              body: <String, dynamic>{
                'id': importId,
                'originalName': filename,
                'contentType': contentType,
                'totalSize': bytes.length,
                'sha256': digest,
                if (captureTime != null)
                  'captureTime': captureTime.toUtc().toIso8601String(),
                'timezone': 'UTC',
              },
            )
            as Map;
    final id = declared['id'] as String;
    final partSize = declared['part_size'] as int;
    final missingParts = (declared['missingParts'] as List)
        .cast<num>()
        .map((part) => part.toInt())
        .toList();
    for (final part in missingParts) {
      final offset = part * partSize;
      final endExclusive = (offset + partSize).clamp(0, bytes.length);
      final content = Uint8List.sublistView(bytes, offset, endExclusive);
      final partRequest = http.MultipartRequest(
        'PUT',
        _resolve('/api/v1/imports/$id/parts/$part'),
      );
      partRequest.headers.addAll(<String, String>{
        ..._headers,
        'Content-Range': 'bytes $offset-${endExclusive - 1}/${bytes.length}',
        'X-Part-Sha256': sha256.convert(content).toString(),
      });
      partRequest.files.add(
        http.MultipartFile.fromBytes(
          'part',
          content,
          filename: '$filename.part-$part',
        ),
      );
      _decode(await http.Response.fromStream(await _client.send(partRequest)));
    }
    await request('POST', '/api/v1/imports/$id/complete');
  }
}
