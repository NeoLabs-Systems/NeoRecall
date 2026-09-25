import '../api_client.dart';
import '../settings/usage_section.dart';

/// The admin API, called with the signed-in admin's own session. The server
/// re-checks the account's role on every call, so nothing here is trusted for
/// access; it only shapes what the Admin page shows.
class AdminClient {
  const AdminClient(this.api);

  final NeoRecallApiClient api;

  static const String _base = '/api/v1/admin';

  /// How many rows each activity list asks for.
  static const int listLimit = 100;

  Future<Map<String, dynamic>> _get(String path) async =>
      Map<String, dynamic>.from(await api.request('GET', '$_base$path') as Map);

  List<Map<String, dynamic>> _rows(Map<String, dynamic> body, String key) =>
      (body[key] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

  Future<AdminStats> stats() async => AdminStats.fromJson(await _get('/stats'));

  Future<List<AdminUser>> users() async => _rows(
    await _get('/users?limit=500'),
    'users',
  ).map(AdminUser.fromJson).toList(growable: false);

  Future<void> setUserDisabled(String userId, bool disabled) => api.request(
    'PATCH',
    '$_base/users/$userId',
    body: <String, dynamic>{'disabled': disabled},
  );

  Future<AdminUserLimits> userLimits(String userId) async =>
      AdminUserLimits.fromJson(await _get('/users/$userId/usage-limits'));

  /// Each value is null to inherit the install default, 0 for unlimited, or a
  /// cap.
  Future<AdminUserLimits> setUserLimits(
    String userId,
    Map<String, int?> overrides,
  ) async => AdminUserLimits.fromJson(
    Map<String, dynamic>.from(
      await api.request(
            'PUT',
            '$_base/users/$userId/usage-limits',
            body: overrides,
          )
          as Map,
    ),
  );

  Future<InstallUsageLimits> installLimits() async =>
      InstallUsageLimits.fromJson(
        Map<String, dynamic>.from(
          (await _get('/config/usage-limits'))['limits'] as Map? ?? const {},
        ),
      );

  Future<InstallUsageLimits> setInstallLimits(InstallUsageLimits limits) async {
    final body =
        await api.request(
              'PUT',
              '$_base/config/usage-limits',
              body: limits.toJson(),
            )
            as Map;
    return InstallUsageLimits.fromJson(
      Map<String, dynamic>.from(body['limits'] as Map? ?? const {}),
    );
  }

  /// The latest jobs, only those in [status] when given.
  Future<List<AdminJob>> jobs({String? status}) async => _rows(
    await _get(
      '/jobs?limit=$listLimit${status == null ? '' : '&status=$status'}',
    ),
    'jobs',
  ).map(AdminJob.fromJson).toList(growable: false);

  /// What the navigation flags: failed jobs, and backups that failed or are
  /// overdue. Either half that cannot be read is left out rather than guessed.
  Future<AdminAttention> attention() async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      stats().then<Object?>((value) => value, onError: (_) => null),
      backups().then<Object?>((value) => value, onError: (_) => null),
    ]);
    final overview = results[0] as AdminStats?;
    final backupStatus = results[1] as AdminBackups?;
    return AdminAttention(
      failedJobs: overview?.failed ?? 0,
      backups:
          backupStatus != null &&
          (backupStatus.lastFailed ||
              backupStatus.unreachable != null ||
              (backupStatus.enabled &&
                  backupStatus.due &&
                  backupStatus.lastSuccessAt != null)),
    );
  }

  Future<void> retryJob(String id) =>
      api.request('POST', '$_base/jobs/$id/retry');

  Future<void> cancelJob(String id) =>
      api.request('POST', '$_base/jobs/$id/cancel');

  Future<List<AdminAiRequest>> aiRequests() async => _rows(
    await _get('/ai-requests?limit=$listLimit'),
    'requests',
  ).map(AdminAiRequest.fromJson).toList(growable: false);

  Future<List<AdminAuditEntry>> audit() async => _rows(
    await _get('/audit?limit=$listLimit'),
    'entries',
  ).map(AdminAuditEntry.fromJson).toList(growable: false);

  Future<AdminBackups> backups() async =>
      AdminBackups.fromJson(await _get('/backups?limit=$listLimit'));

  /// A backup can take a while on a large database; the server answers once
  /// the artifact is written.
  Future<AdminBackupRun> runBackup() async => AdminBackupRun.fromJson(
    Map<String, dynamic>.from(
      await api.request(
            'POST',
            '$_base/backups/run',
            timeout: const Duration(minutes: 10),
          )
          as Map,
    ),
  );

  Future<Map<String, Object>> processingSettings() async =>
      _settingsFrom(await _get('/processing-settings'));

  Future<Map<String, Object>> saveProcessingSettings(
    Map<String, Object> settings,
  ) async => _settingsFrom(
    Map<String, dynamic>.from(
      await api.request('PUT', '$_base/processing-settings', body: settings)
          as Map,
    ),
  );

  Map<String, Object> _settingsFrom(Map<String, dynamic> body) {
    final raw = body['settings'];
    if (raw is! Map) return const <String, Object>{};
    return <String, Object>{
      for (final entry in raw.entries)
        if (entry.value is num || entry.value is bool)
          entry.key.toString(): entry.value as Object,
    };
  }
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();

int _int(Object? value) => (value as num?)?.toInt() ?? 0;

String? _text(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

class AdminStats {
  const AdminStats({
    required this.version,
    required this.users,
    required this.devices,
    required this.recordings,
    required this.queue,
    required this.oldestQueuedAt,
    required this.workers,
    required this.temporaryAudioBytes,
    required this.cleanupPending,
    required this.vectorReady,
    required this.vectorVersion,
    required this.aiTokens,
    required this.processing,
  });

  final String? version;
  final int users;
  final int devices;
  final int recordings;

  /// Job count per status.
  final Map<String, int> queue;
  final DateTime? oldestQueuedAt;
  final List<AdminWorker> workers;
  final int temporaryAudioBytes;
  final int cleanupPending;
  final bool vectorReady;
  final String? vectorVersion;
  final int aiTokens;
  final List<AdminProcessingMetric> processing;

  int get queued => queue['queued'] ?? 0;
  int get failed => queue['failed'] ?? 0;

  factory AdminStats.fromJson(Map<String, dynamic> json) {
    final vector = json['vector'] as Map? ?? const {};
    final ai = (json['ai'] as List? ?? const <dynamic>[]).whereType<Map>();
    return AdminStats(
      version: _text(json['version']),
      users: _int(json['users']),
      devices: _int(json['devices']),
      recordings: _int(json['recordings']),
      queue: <String, int>{
        for (final row
            in (json['queue'] as List? ?? const <dynamic>[]).whereType<Map>())
          row['status'].toString(): _int(row['count']),
      },
      oldestQueuedAt: _date(json['oldestQueuedAt']),
      workers: (json['workers'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((row) => AdminWorker.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false),
      temporaryAudioBytes: _int(json['temporaryAudioBytes']),
      cleanupPending: _int(json['cleanupPending']),
      vectorReady: vector['ready'] == true,
      vectorVersion: _text(vector['version']),
      aiTokens: ai.fold<int>(
        0,
        (sum, row) =>
            sum + _int(row['prompt_tokens']) + _int(row['completion_tokens']),
      ),
      processing: (json['processing'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (row) =>
                AdminProcessingMetric.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false),
    );
  }
}

/// Areas that need a look, for the navigation.
class AdminAttention {
  const AdminAttention({this.failedJobs = 0, this.backups = false});

  final int failedJobs;

  /// The last backup failed, the destination cannot be reached, or one is
  /// overdue after an earlier success.
  final bool backups;
}

class AdminWorker {
  const AdminWorker({
    required this.host,
    required this.modelState,
    required this.heartbeatAt,
  });

  final String host;
  final String modelState;
  final DateTime? heartbeatAt;

  factory AdminWorker.fromJson(Map<String, dynamic> json) => AdminWorker(
    host: json['host']?.toString() ?? '',
    modelState: json['model_state']?.toString() ?? '',
    heartbeatAt: _date(json['heartbeat_at']),
  );
}

class AdminProcessingMetric {
  const AdminProcessingMetric({
    required this.metric,
    required this.average,
    required this.maximum,
    required this.unit,
  });

  final String metric;
  final double average;
  final double maximum;
  final String unit;

  factory AdminProcessingMetric.fromJson(Map<String, dynamic> json) =>
      AdminProcessingMetric(
        metric: json['metric']?.toString() ?? '',
        average: (json['average'] as num?)?.toDouble() ?? 0,
        maximum: (json['maximum'] as num?)?.toDouble() ?? 0,
        unit: json['unit']?.toString() ?? '',
      );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.email,
    required this.isAdmin,
    required this.disabled,
    required this.createdAt,
    required this.lastLoginAt,
    required this.deviceCount,
    required this.recordingCount,
  });

  final String id;
  final String username;
  final String? email;
  final bool isAdmin;
  final bool disabled;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;
  final int deviceCount;
  final int recordingCount;

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    id: json['id']?.toString() ?? '',
    username: json['username']?.toString() ?? '',
    email: _text(json['email']),
    isAdmin: json['role'] == 'admin',
    disabled: json['disabled_at'] != null,
    createdAt: _date(json['created_at']),
    lastLoginAt: _date(json['last_login_at']),
    deviceCount: _int(json['device_count']),
    recordingCount: _int(json['recording_count']),
  );
}

/// The install-wide rolling caps. 0 means unlimited.
class InstallUsageLimits {
  const InstallUsageLimits({
    required this.aiTokens4h,
    required this.aiTokensWeekly,
    required this.transcriptionSeconds4h,
    required this.transcriptionSecondsWeekly,
  });

  final int aiTokens4h;
  final int aiTokensWeekly;
  final int transcriptionSeconds4h;
  final int transcriptionSecondsWeekly;

  factory InstallUsageLimits.fromJson(Map<String, dynamic> json) =>
      InstallUsageLimits(
        aiTokens4h: _int(json['aiTokens4h']),
        aiTokensWeekly: _int(json['aiTokensWeekly']),
        transcriptionSeconds4h: _int(json['transcriptionSeconds4h']),
        transcriptionSecondsWeekly: _int(json['transcriptionSecondsWeekly']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'aiTokens4h': aiTokens4h,
    'aiTokensWeekly': aiTokensWeekly,
    'transcriptionSeconds4h': transcriptionSeconds4h,
    'transcriptionSecondsWeekly': transcriptionSecondsWeekly,
  };
}

/// One account's own caps (null inherits the install default, 0 is
/// unlimited) and what it has used.
class AdminUserLimits {
  const AdminUserLimits({
    required this.username,
    required this.overrides,
    required this.usage,
  });

  /// Keyed by the field names the API takes: `aiLimit4h`, `aiLimitWeekly`,
  /// `transcriptionLimit4h`, `transcriptionLimitWeekly`.
  final Map<String, int?> overrides;
  final String username;
  final AccountUsageSnapshot usage;

  static const List<String> fields = <String>[
    'aiLimit4h',
    'aiLimitWeekly',
    'transcriptionLimit4h',
    'transcriptionLimitWeekly',
  ];

  factory AdminUserLimits.fromJson(Map<String, dynamic> json) =>
      AdminUserLimits(
        username: json['username']?.toString() ?? '',
        overrides: <String, int?>{
          for (final field in fields) field: (json[field] as num?)?.toInt(),
        },
        usage: AccountUsageSnapshot.fromJson(
          Map<String, dynamic>.from(json['usage'] as Map? ?? const {}),
        ),
      );
}

class AdminJob {
  const AdminJob({
    required this.id,
    required this.type,
    required this.status,
    required this.attempts,
    required this.maxAttempts,
    required this.errorCode,
    required this.errorMessage,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String status;
  final int attempts;
  final int maxAttempts;
  final String? errorCode;
  final String? errorMessage;
  final DateTime? createdAt;

  bool get retryable => status == 'failed';
  bool get cancellable => status == 'queued' || status == 'failed';

  factory AdminJob.fromJson(Map<String, dynamic> json) => AdminJob(
    id: json['id']?.toString() ?? '',
    type: json['type']?.toString() ?? '',
    status: json['status']?.toString() ?? '',
    attempts: _int(json['attempts']),
    maxAttempts: _int(json['max_attempts']),
    errorCode: _text(json['last_error_code']),
    errorMessage: _text(json['last_error_message']),
    createdAt: _date(json['created_at']),
  );
}

class AdminAiRequest {
  const AdminAiRequest({
    required this.purpose,
    required this.state,
    required this.model,
    required this.tokens,
    required this.errorCode,
    required this.sentAt,
  });

  final String purpose;
  final String state;
  final String? model;
  final int tokens;
  final String? errorCode;

  /// Null while the request is only reserved.
  final DateTime? sentAt;

  factory AdminAiRequest.fromJson(Map<String, dynamic> json) => AdminAiRequest(
    purpose: json['purpose']?.toString() ?? '',
    state: json['state']?.toString() ?? '',
    model: _text(json['model']),
    tokens: _int(json['prompt_tokens']) + _int(json['completion_tokens']),
    errorCode: _text(json['error_code']),
    sentAt: _date(json['sent_at']),
  );
}

class AdminAuditEntry {
  const AdminAuditEntry({
    required this.actorType,
    required this.actorName,
    required this.affectedName,
    required this.action,
    required this.resource,
    required this.createdAt,
  });

  /// `user`, `admin`, `api_key` or `system`.
  final String actorType;
  final String? actorName;
  final String? affectedName;
  final String action;
  final String? resource;
  final DateTime? createdAt;

  factory AdminAuditEntry.fromJson(Map<String, dynamic> json) {
    final resource = <String>[
      if (_text(json['resource_type']) != null)
        json['resource_type'].toString(),
      if (_text(json['resource_id']) != null) json['resource_id'].toString(),
    ].join(' · ');
    return AdminAuditEntry(
      actorType: json['actor_type']?.toString() ?? '',
      actorName: _text(json['actor_username']),
      affectedName: _text(json['affected_username']),
      action: json['action']?.toString() ?? '',
      resource: resource.isEmpty ? null : resource,
      createdAt: _date(json['created_at']),
    );
  }
}

class AdminBackups {
  const AdminBackups({
    required this.enabled,
    required this.destination,
    required this.location,
    required this.unreachable,
    required this.intervalHours,
    required this.retain,
    required this.running,
    required this.due,
    required this.nextDueAt,
    required this.lastSuccessAt,
    required this.lastFailed,
    required this.artifactCount,
    required this.artifactBytes,
    required this.history,
  });

  final bool enabled;
  final String destination;
  final String? location;

  /// Why the destination cannot be reached, when it cannot.
  final String? unreachable;
  final int intervalHours;
  final int retain;
  final bool running;
  final bool due;
  final DateTime? nextDueAt;
  final DateTime? lastSuccessAt;
  final bool lastFailed;
  final int artifactCount;
  final int artifactBytes;
  final List<AdminBackupRecord> history;

  factory AdminBackups.fromJson(Map<String, dynamic> json) {
    final status = Map<String, dynamic>.from(
      json['status'] as Map? ?? const {},
    );
    final last = status['last'];
    return AdminBackups(
      enabled: status['enabled'] == true,
      destination: status['destination']?.toString() ?? '',
      location: _text(status['location']),
      unreachable: _text(status['unreachable']),
      intervalHours: _int(status['intervalHours']),
      retain: _int(status['retain']),
      running: status['running'] == true,
      due: status['due'] == true,
      nextDueAt: _date(status['nextDueAt']),
      lastSuccessAt: _date(status['lastSuccessAt']),
      lastFailed: last is Map && last['state'] == 'failed',
      artifactCount: _int(status['artifactCount']),
      artifactBytes: _int(status['artifactBytes']),
      history: (json['history'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (row) => AdminBackupRecord.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false),
    );
  }
}

class AdminBackupRecord {
  const AdminBackupRecord({
    required this.startedAt,
    required this.trigger,
    required this.state,
    required this.errorCode,
    required this.errorMessage,
    required this.bytes,
    required this.artifactKey,
    required this.pruned,
  });

  final DateTime? startedAt;
  final String trigger;
  final String state;
  final String? errorCode;
  final String? errorMessage;
  final int bytes;
  final String? artifactKey;
  final bool pruned;

  factory AdminBackupRecord.fromJson(Map<String, dynamic> json) =>
      AdminBackupRecord(
        startedAt: _date(json['started_at']),
        trigger: json['trigger_kind']?.toString() ?? '',
        state: json['state']?.toString() ?? '',
        errorCode: _text(json['error_code']),
        errorMessage: _text(json['error_message']),
        bytes: _int(json['bytes']),
        artifactKey: _text(json['artifact_key']),
        pruned: json['pruned_at'] != null,
      );
}

class AdminBackupRun {
  const AdminBackupRun({required this.skipped, required this.bytes});

  /// Another backup was already running.
  final bool skipped;
  final int bytes;

  factory AdminBackupRun.fromJson(Map<String, dynamic> json) => AdminBackupRun(
    skipped: json['skipped'] == true,
    bytes: _int(json['bytes']),
  );
}
