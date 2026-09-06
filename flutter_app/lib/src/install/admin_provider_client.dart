import 'dart:convert';

import 'package:http/http.dart' as http;

/// One provider the server supports for a workload.
class ProviderCatalogEntry {
  const ProviderCatalogEntry({
    required this.id,
    required this.label,
    required this.protocol,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.apiKeyRequired,
    required this.modelOptional,
  });

  final String id;
  final String label;
  final String protocol;
  final String? defaultBaseUrl;
  final String? defaultModel;
  final bool apiKeyRequired;
  final bool modelOptional;

  /// Providers without a fixed endpoint need the operator to supply one.
  bool get baseUrlRequired => defaultBaseUrl == null;

  factory ProviderCatalogEntry.fromJson(Map<String, dynamic> json) =>
      ProviderCatalogEntry(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? json['id']?.toString() ?? '',
        protocol: json['protocol']?.toString() ?? 'openai',
        defaultBaseUrl: _trimmedOrNull(json['defaultBaseUrl']),
        defaultModel: _trimmedOrNull(json['defaultModel']),
        apiKeyRequired: json['apiKeyRequired'] == true,
        modelOptional: json['modelOptional'] == true,
      );
}

/// What the server is currently pointed at for one workload.
class ProviderWorkloadSettings {
  const ProviderWorkloadSettings({
    required this.provider,
    required this.label,
    required this.model,
    required this.baseUrl,
    required this.apiKeyConfigured,
    required this.apiKeySource,
  });

  final String provider;
  final String label;
  final String? model;
  final String? baseUrl;
  final bool apiKeyConfigured;
  final String apiKeySource;

  factory ProviderWorkloadSettings.fromJson(Map<String, dynamic> json) =>
      ProviderWorkloadSettings(
        provider: json['provider']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        model: _trimmedOrNull(json['model']),
        baseUrl: _trimmedOrNull(json['baseUrl']),
        apiKeyConfigured: json['apiKeyConfigured'] == true,
        apiKeySource: json['apiKeySource']?.toString() ?? 'none',
      );
}

class ProviderSettingsSnapshot {
  const ProviderSettingsSnapshot({
    required this.transcription,
    required this.llm,
    required this.transcriptionCatalog,
    required this.llmCatalog,
  });

  final ProviderWorkloadSettings transcription;
  final ProviderWorkloadSettings llm;
  final List<ProviderCatalogEntry> transcriptionCatalog;
  final List<ProviderCatalogEntry> llmCatalog;

  factory ProviderSettingsSnapshot.fromJson(Map<String, dynamic> json) {
    final catalogs = json['catalogs'];
    List<ProviderCatalogEntry> catalog(String key) =>
        (catalogs is Map && catalogs[key] is List)
        ? (catalogs[key] as List)
              .whereType<Map>()
              .map(
                (entry) => ProviderCatalogEntry.fromJson(
                  Map<String, dynamic>.from(entry),
                ),
              )
              .toList(growable: false)
        : const <ProviderCatalogEntry>[];
    return ProviderSettingsSnapshot(
      transcription: ProviderWorkloadSettings.fromJson(
        Map<String, dynamic>.from(json['transcription'] as Map? ?? const {}),
      ),
      llm: ProviderWorkloadSettings.fromJson(
        Map<String, dynamic>.from(json['llm'] as Map? ?? const {}),
      ),
      transcriptionCatalog: catalog('transcription'),
      llmCatalog: catalog('llm'),
    );
  }
}

/// One leg of the provider self-test.
class ProviderTestLeg {
  const ProviderTestLeg({
    required this.ok,
    required this.detail,
    this.model,
    this.milliseconds,
  });

  final bool ok;
  final String detail;
  final String? model;
  final int? milliseconds;

  factory ProviderTestLeg.fromJson(Map<String, dynamic> json) {
    final ok = json['ok'] == true;
    final text = ok
        ? (json['text']?.toString() ??
              json['answer']?.toString() ??
              json['detail']?.toString() ??
              'Answered as expected.')
        : (json['error']?.toString() ?? 'The service did not answer.');
    return ProviderTestLeg(
      ok: ok,
      detail: text,
      model: _trimmedOrNull(json['model']),
      milliseconds: int.tryParse(json['ms']?.toString() ?? ''),
    );
  }
}

class ProviderTestReport {
  const ProviderTestReport({
    required this.transcription,
    required this.speakerIdentity,
    required this.llm,
  });

  final ProviderTestLeg transcription;
  final ProviderTestLeg speakerIdentity;
  final ProviderTestLeg llm;

  bool get ok => transcription.ok && llm.ok;

  factory ProviderTestReport.fromJson(Map<String, dynamic> json) =>
      ProviderTestReport(
        transcription: ProviderTestLeg.fromJson(
          Map<String, dynamic>.from(json['transcription'] as Map? ?? const {}),
        ),
        speakerIdentity: ProviderTestLeg.fromJson(
          Map<String, dynamic>.from(json['speakerIdentity'] as Map? ?? const {}),
        ),
        llm: ProviderTestLeg.fromJson(
          Map<String, dynamic>.from(json['llm'] as Map? ?? const {}),
        ),
      );
}

/// What to write for one workload.
class ProviderSelection {
  const ProviderSelection({
    required this.provider,
    this.model,
    this.baseUrl,
    this.apiKey,
  });

  final String provider;
  final String? model;
  final String? baseUrl;
  final String? apiKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    if (model != null && model!.isNotEmpty) 'model': model,
    if (baseUrl != null && baseUrl!.isNotEmpty) 'baseUrl': baseUrl,
    if (apiKey != null && apiKey!.isNotEmpty) 'apiKey': apiKey,
  };
}

class AdminProviderException implements Exception {
  const AdminProviderException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Talks to the admin provider endpoints with the server's `ADMIN_API_KEY`, so
/// transcription and language-model setup can happen in this app instead of the
/// admin web dashboard.
class AdminProviderClient {
  AdminProviderClient({
    required String backendUrl,
    required this.apiKey,
    http.Client? client,
  }) : backendUrl = backendUrl.replaceFirst(RegExp(r'/$'), ''),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String backendUrl;
  final String apiKey;
  final http.Client _client;
  final bool _ownsClient;

  Uri _uri(String path) => Uri.parse('$backendUrl/admin/api/v1$path');

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };

  Future<ProviderSettingsSnapshot> load() async {
    final body = await _send(() => _client.get(_uri('/provider-settings'),
        headers: _headers));
    return ProviderSettingsSnapshot.fromJson(
      Map<String, dynamic>.from(body['settings'] as Map? ?? const {}),
    );
  }

  Future<ProviderSettingsSnapshot> save({
    ProviderSelection? transcription,
    ProviderSelection? llm,
  }) async {
    final payload = <String, dynamic>{
      if (transcription != null) 'transcription': transcription.toJson(),
      if (llm != null) 'llm': llm.toJson(),
    };
    final body = await _send(
      () => _client.put(
        _uri('/provider-settings'),
        headers: _headers,
        body: jsonEncode(payload),
      ),
    );
    return ProviderSettingsSnapshot.fromJson(
      Map<String, dynamic>.from(body['settings'] as Map? ?? const {}),
    );
  }

  /// Model ids the provider lists. Providers that choose a model themselves, or
  /// that do not publish a catalog, report an empty list rather than failing.
  Future<List<String>> discoverModels({
    required String workload,
    required String provider,
    String? baseUrl,
    String? apiKey,
  }) async {
    final body = await _send(
      () => _client.post(
        _uri('/provider-settings/models'),
        headers: _headers,
        body: jsonEncode(<String, dynamic>{
          'workload': workload,
          'provider': provider,
          if (baseUrl != null && baseUrl.isNotEmpty) 'baseUrl': baseUrl,
          if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        }),
      ),
    );
    final models = body['models'];
    if (models is! List) return const <String>[];
    return models
        .map((entry) => entry.toString())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  /// Runs the server's own end-to-end probe: a real transcription of the
  /// bundled sample recording and a real generation request.
  Future<ProviderTestReport> test() async {
    final body = await _send(
      () => _client.post(_uri('/provider-settings/test'), headers: _headers),
    );
    return ProviderTestReport.fromJson(body);
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    http.Response response;
    try {
      response = await request().timeout(const Duration(minutes: 3));
    } on Object catch (error) {
      throw AdminProviderException(
        'Could not reach the NeoRecall server: $error',
      );
    }
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      body = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on Object {
      body = <String, dynamic>{};
    }
    if (response.statusCode >= 400) {
      final error = body['error'];
      final message = error is Map
          ? (error['message']?.toString() ?? error['code']?.toString())
          : body['message']?.toString();
      throw AdminProviderException(
        message ?? 'The server rejected the request (HTTP ${response.statusCode}).',
        code: error is Map ? error['code']?.toString() : null,
      );
    }
    return body;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

String? _trimmedOrNull(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
