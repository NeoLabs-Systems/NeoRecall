import '../api_client.dart';

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
    this.defaultResponseFormat,
  });

  final String id;
  final String label;
  final String protocol;
  final String? defaultBaseUrl;
  final String? defaultModel;
  final bool apiKeyRequired;
  final bool modelOptional;
  final String? defaultResponseFormat;

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
        defaultResponseFormat: _trimmedOrNull(json['defaultResponseFormat']),
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
    this.environmentApiKeyConfigured = false,
    this.language,
    this.responseFormat,
    this.extraBody,
    this.sources = const <String, String>{},
  });

  final String provider;
  final String label;
  final String? model;
  final String? baseUrl;
  final bool apiKeyConfigured;

  /// `admin` (saved from this app), `environment` (the server's `.env`) or
  /// `none`.
  final String apiKeySource;

  /// Whether the server's own configuration has a key, so removing the one
  /// saved from the app still leaves the service usable.
  final bool environmentApiKeyConfigured;

  /// Transcription only.
  final String? language;
  final String? responseFormat;

  /// Language model only: extra fields merged into every request.
  final Map<String, dynamic>? extraBody;

  /// Where each value comes from, per field: `admin`, `environment`,
  /// `default` or `none`.
  final Map<String, String> sources;

  /// True when any value is an override saved from the app rather than the
  /// server's own configuration.
  bool get hasOverrides =>
      apiKeySource == 'admin' || sources.values.contains('admin');

  factory ProviderWorkloadSettings.fromJson(Map<String, dynamic> json) {
    final extraBody = json['extraBody'];
    final sources = json['sources'];
    return ProviderWorkloadSettings(
      provider: json['provider']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      model: _trimmedOrNull(json['model']),
      baseUrl: _trimmedOrNull(json['baseUrl']),
      apiKeyConfigured: json['apiKeyConfigured'] == true,
      apiKeySource: json['apiKeySource']?.toString() ?? 'none',
      environmentApiKeyConfigured: json['environmentApiKeyConfigured'] == true,
      language: _trimmedOrNull(json['language']),
      responseFormat: _trimmedOrNull(json['responseFormat']),
      extraBody: extraBody is Map ? Map<String, dynamic>.from(extraBody) : null,
      sources: sources is Map
          ? sources.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const <String, String>{},
    );
  }
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
          Map<String, dynamic>.from(
            json['speakerIdentity'] as Map? ?? const {},
          ),
        ),
        llm: ProviderTestLeg.fromJson(
          Map<String, dynamic>.from(json['llm'] as Map? ?? const {}),
        ),
      );
}

/// What to write for one workload.
///
/// The server stores a workload as a whole, so a selection carries every
/// value saved from the app — including the ones a form left folded away — or
/// saving would quietly reset them. A value that comes from the server's own
/// configuration is sent as null instead, so saving never freezes it.
class ProviderSelection {
  const ProviderSelection({
    required this.provider,
    this.model,
    this.baseUrl,
    this.apiKey,
    this.clearApiKey = false,
    this.language,
    this.responseFormat,
    this.extraBody,
  });

  final String provider;
  final String? model;
  final String? baseUrl;
  final String? apiKey;
  final bool clearApiKey;
  final String? language;
  final String? responseFormat;
  final Map<String, dynamic>? extraBody;

  Map<String, dynamic> toJson(String workload) => <String, dynamic>{
    'provider': provider,
    if (model != null && model!.isNotEmpty) 'model': model,
    if (baseUrl != null && baseUrl!.isNotEmpty) 'baseUrl': baseUrl,
    if (apiKey != null && apiKey!.isNotEmpty) 'apiKey': apiKey,
    // A typed key replaces the saved one; only an empty field removes it.
    if (clearApiKey && (apiKey?.isEmpty ?? true)) 'clearApiKey': true,
    if (workload == 'transcription') ...<String, dynamic>{
      'language': (language?.isEmpty ?? true) ? null : language,
      'responseFormat': (responseFormat?.isEmpty ?? true)
          ? null
          : responseFormat,
    } else
      'extraBody': (extraBody?.isEmpty ?? true) ? null : extraBody,
  };
}

/// The provider endpoints of the admin API, called with the signed-in admin's
/// own session.
class AdminProviderClient {
  const AdminProviderClient(this.api);

  final NeoRecallApiClient api;

  static const String _base = '/api/v1/admin/provider-settings';

  /// A real transcription of the bundled sample plus a model round trip takes
  /// far longer than an ordinary request.
  static const Duration _testTimeout = Duration(minutes: 3);

  Future<ProviderSettingsSnapshot> load() async {
    final body = await api.request('GET', _base) as Map;
    return ProviderSettingsSnapshot.fromJson(
      Map<String, dynamic>.from(body['settings'] as Map? ?? const {}),
    );
  }

  Future<ProviderSettingsSnapshot> save({
    ProviderSelection? transcription,
    ProviderSelection? llm,
  }) async {
    final body =
        await api.request(
              'PUT',
              _base,
              body: <String, dynamic>{
                if (transcription != null)
                  'transcription': transcription.toJson('transcription'),
                if (llm != null) 'llm': llm.toJson('llm'),
              },
            )
            as Map;
    return ProviderSettingsSnapshot.fromJson(
      Map<String, dynamic>.from(body['settings'] as Map? ?? const {}),
    );
  }

  /// Drops every value saved from the app, so the server's own configuration
  /// applies again.
  Future<ProviderSettingsSnapshot> reset() async {
    final body = await api.request('DELETE', _base) as Map;
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
    final body =
        await api.request(
              'POST',
              '$_base/models',
              body: <String, dynamic>{
                'workload': workload,
                'provider': provider,
                if (baseUrl != null && baseUrl.isNotEmpty) 'baseUrl': baseUrl,
                if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
              },
            )
            as Map;
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
    final body =
        await api.request('POST', '$_base/test', timeout: _testTimeout) as Map;
    return ProviderTestReport.fromJson(Map<String, dynamic>.from(body));
  }
}

String? _trimmedOrNull(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
