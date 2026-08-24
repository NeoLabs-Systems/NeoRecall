import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'diagnostics/client_diagnostic_log.dart';
import 'models/chunk.dart';
import 'sync/upload_compression.dart';
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
  NeoRecallApiClient({
    required String baseUrl,
    this.token,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(minutes: 2),
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
       _client = client ?? http.Client();
  String baseUrl;
  String? token;
  final http.Client _client;
  final Duration requestTimeout;
  final Duration uploadTimeout;

  Map<String, String> get _headers => <String, String>{
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Uri _resolve(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    if (baseUrl.isEmpty) return Uri.parse(normalizedPath);
    return Uri.parse('$baseUrl$normalizedPath');
  }

  Future<Uint8List> speakerPreview(String speakerId) async {
    final response = await _client
        .get(
          _resolve('/api/v1/speakers/$speakerId/preview'),
          headers: <String, String>{..._headers, 'Accept': 'audio/wav'},
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
    }
    return response.bodyBytes;
  }

  Future<dynamic> request(String method, String path, {Object? body}) async {
    final uri = _resolve(path);
    final headers = <String, String>{
      ..._headers,
      if (body != null) 'Content-Type': 'application/json',
    };
    late Future<http.Response> responseFuture;
    final encoded = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        responseFuture = _client.get(uri, headers: headers);
      case 'POST':
        responseFuture = _client.post(uri, headers: headers, body: encoded);
      case 'PUT':
        responseFuture = _client.put(uri, headers: headers, body: encoded);
      case 'PATCH':
        responseFuture = _client.patch(uri, headers: headers, body: encoded);
      case 'DELETE':
        responseFuture = _client.delete(uri, headers: headers, body: encoded);
      default:
        throw ArgumentError.value(method, 'method');
    }
    late http.Response response;
    try {
      response = await responseFuture.timeout(requestTimeout);
    } catch (error) {
      ClientDiagnosticLog.instance.record(
        'network',
        'request_failed',
        level: 'error',
        details: <String, Object?>{
          'method': method,
          'path': _diagnosticPath(path),
          'error': error.toString(),
        },
      );
      rethrow;
    }
    if (response.statusCode >= 400) {
      ClientDiagnosticLog.instance.record(
        'network',
        'request_rejected',
        level: 'warning',
        details: <String, Object?>{
          'method': method,
          'path': _diagnosticPath(path),
          'status': response.statusCode,
        },
      );
    }
    return _decode(response);
  }

  String _diagnosticPath(String path) => path.replaceAll(
    RegExp(
      r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',
      caseSensitive: false,
    ),
    ':id',
  );

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
    final upload = await prepareAudioUpload(bytes);
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
      if (upload.contentEncoding != null)
        'X-Audio-Content-Encoding': upload.contentEncoding!,
      if (chunk.isFinal) 'X-Final-Chunk': 'true',
    });
    request.files.add(
      http.MultipartFile.fromBytes(
        'audio',
        upload.bytes,
        filename: '${chunk.id}.${chunk.container}',
      ),
    );
    final streamed = await _client.send(request).timeout(uploadTimeout);
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(uploadTimeout);
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

  /// Device kind this client reports for [platform].
  static String deviceKindFor(String platform) => platform == 'web'
      ? 'browser'
      : (platform == 'android' || platform == 'ios')
      ? 'mobile'
      : 'desktop';

  /// Registers this client as a device and returns the id the server holds.
  ///
  /// Registration is keyed on the client UUID and is therefore idempotent, so it
  /// is safe to call before any request that needs the device to exist — an
  /// import that wants its audio attributed to this device, for instance.
  Future<String> registerDevice({
    required String id,
    required String clientUuid,
    required String name,
    required String platform,
    Map<String, dynamic> capabilities = const <String, dynamic>{},
  }) async {
    final device =
        await request(
              'POST',
              '/api/v1/devices',
              body: <String, dynamic>{
                'id': id,
                'clientUuid': clientUuid,
                'name': name,
                'platform': platform,
                'kind': deviceKindFor(platform),
                'capabilities': capabilities,
              },
            )
            as Map;
    return device['id'] as String;
  }

  Future<void> syncSession(LocalRecordingDeclaration session) async {
    await registerDevice(
      id: session.deviceId,
      clientUuid: session.deviceClientUuid,
      name: session.deviceName,
      platform: session.platform,
      capabilities: <String, dynamic>{
        'microphone': session.sourceKind != 'system',
        'systemAudio': <String>{
          'system',
          'combined',
        }.contains(session.sourceKind),
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
    String? deviceId,
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
                // Naming the device is what lets the server recognise
                // consecutive sync sweeps as one recording instead of one
                // conversation each.
                'deviceId': ?deviceId,
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
      _decode(
        await http.Response.fromStream(
          await _client.send(partRequest).timeout(uploadTimeout),
        ).timeout(uploadTimeout),
      );
    }
    await request('POST', '/api/v1/imports/$id/complete');
  }
}
