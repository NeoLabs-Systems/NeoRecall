import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'src/api_client.dart';
import 'src/desktop/startup.dart';
import 'src/models/chunk.dart';
import 'src/models/memory.dart';
import 'src/models/recording.dart';
import 'src/models/speaker.dart';
import 'src/models/transcript.dart';
import 'src/network/network_state.dart';
import 'src/recording/audio_frame.dart';
import 'src/recording/recorder.dart';
import 'src/sync/chunk_store.dart';
import 'src/sync/sync_coordinator.dart';

enum RecallPage {
  record,
  timeline,
  memories,
  search,
  speakers,
  devices,
  settings,
}

class NeoRecallController extends ChangeNotifier {
  NeoRecallController({
    NeoRecallApiClient? api,
    ChunkStore? store,
    RecallRecorder? recorder,
  }) : api = api ?? NeoRecallApiClient(baseUrl: _defaultBackendUrl),
       store = store ?? createChunkStore(),
       recorder = recorder ?? createRecorder();

  static const String _configuredBackendUrl = String.fromEnvironment(
    'NEORECALL_API_URL',
  );

  static String get _defaultBackendUrl {
    final configured = _configuredBackendUrl.trim();
    if (kIsWeb) {
      if (configured.isEmpty) return _sameOriginBackendUrl();
      final configuredUri = Uri.tryParse(configured);
      final configuredHost = configuredUri?.host ?? '';
      // A web bundle accidentally compiled against localhost should still work
      // when served from a real host by falling back to same-origin.
      if (!_isLoopbackHost(Uri.base.host) && _isLoopbackHost(configuredHost)) {
        return _sameOriginBackendUrl();
      }
      return configured.replaceFirst(RegExp(r'/$'), '');
    }
    if (configured.isNotEmpty) {
      return configured.replaceFirst(RegExp(r'/$'), '');
    }
    return 'http://localhost:4500';
  }

  static String _sameOriginBackendUrl() {
    final base = Uri.base;
    return Uri(
      scheme: base.scheme.isEmpty ? 'http' : base.scheme,
      host: base.host.isEmpty ? 'localhost' : base.host,
      port: base.hasPort ? base.port : null,
    ).toString().replaceFirst(RegExp(r'/$'), '');
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }

  final NeoRecallApiClient api;
  final ChunkStore store;
  final RecallRecorder recorder;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Uuid _uuid = const Uuid();
  late final SyncCoordinator sync = SyncCoordinator(
    store: store,
    api: api,
    onChanged: _refreshPending,
  );
  StreamSubscription<RecordedAudioChunk>? _chunkSubscription;
  StreamSubscription<RecordedAudioChunk>? _partialSubscription;
  StreamSubscription<String>? _warningSubscription;
  StreamSubscription<double>? _levelSubscription;
  StreamSubscription<bool>? _networkSubscription;
  SharedPreferences? _preferences;
  bool initialized = false;
  bool loading = false;
  bool online = true;
  bool consentAccepted = false;
  bool _stoppingRecording = false;
  bool cachedData = false;
  bool autostartEnabled = false;
  String? error;
  String? notice;
  String? username;
  String? warning;
  RecallPage page = RecallPage.record;
  List<RecordingSession> recordings = <RecordingSession>[];
  List<TranscriptSegment> transcript = <TranscriptSegment>[];
  List<RecallMemory> memories = <RecallMemory>[];
  List<MiniMemory> miniMemories = <MiniMemory>[];
  List<RecallSpeaker> speakers = <RecallSpeaker>[];
  List<Map<String, dynamic>> devices = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> dailySummaries = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> searchResults = <Map<String, dynamic>>[];
  String? askAnswer;
  List<Map<String, dynamic>> askCitations = <Map<String, dynamic>>[];
  int pendingAudioBytes = 0;
  double audioLevel = 0;
  DateTime? recordingStartedAt;
  RecorderCapability? capability;
  LocalRecordingDeclaration? _activeSession;
  int _sequence = 0;
  Future<void> _chunkWrite = Future<void>.value();
  Future<void> _partialWrite = Future<void>.value();
  String? _pendingAccount;
  String? _pendingPassword;

  bool get authenticated => api.token != null;
  bool get isRecording => recorder.isRecording;
  String get backendUrl => api.baseUrl;

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    final savedBackendUrl = _preferences!.getString('backendUrl')?.trim() ?? '';
    if (savedBackendUrl.isNotEmpty) {
      if (kIsWeb &&
          !_isLoopbackHost(Uri.base.host) &&
          _isLoopbackHost(Uri.tryParse(savedBackendUrl)?.host ?? '')) {
        // Ignore a stale localhost preference when the app is served remotely.
        api.baseUrl = _defaultBackendUrl;
        await _preferences!.remove('backendUrl');
      } else {
        api.baseUrl = savedBackendUrl.replaceFirst(RegExp(r'/$'), '');
      }
    } else {
      api.baseUrl = _defaultBackendUrl;
    }
    api.token = await _secureStorage.read(key: 'sessionToken');
    username = _preferences!.getString('username');
    consentAccepted =
        _preferences!.getBool('recordingConsentAccepted') ?? false;
    autostartEnabled = await startupEnabled();
    await sync.initialize();
    _chunkSubscription = recorder.chunks.listen((chunk) {
      final write = _chunkWrite.then((_) => _storeRecordedChunk(chunk));
      _chunkWrite = write.catchError((Object exception) {
        error = exception.toString();
        warning =
            'Local audio could not be stored. Recording is stopping without deleting queued audio.';
        if (recorder.isRecording) {
          unawaited(
            Future<void>.delayed(Duration.zero).then((_) => stopRecording()),
          );
        }
        notifyListeners();
      });
    });
    _partialSubscription = recorder.partials.listen((partial) {
      _partialWrite = _partialWrite.then((_) => _storeCapturePartial(partial));
      _partialWrite = _partialWrite.catchError((Object exception) {
        error = exception.toString();
        warning =
            'The active desktop audio block could not be written to durable storage.';
        if (recorder.isRecording) {
          unawaited(
            Future<void>.delayed(Duration.zero).then((_) => stopRecording()),
          );
        }
        notifyListeners();
      });
    });
    _warningSubscription = recorder.warnings.listen((value) {
      warning = value;
      notifyListeners();
    });
    _levelSubscription = recorder.levels.listen((value) {
      audioLevel = value;
      notifyListeners();
    });
    _networkSubscription = networkAvailability().listen((available) {
      online = available;
      if (available) sync.pump.pump();
      notifyListeners();
    });
    await _refreshPending();
    if (authenticated) await refreshAll(silent: true);
    initialized = true;
    notifyListeners();
  }

  Future<void> setBackendUrl(String value) async {
    final normalized = value.trim().replaceFirst(RegExp(r'/$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const FormatException(
        'Enter a complete server URL including http:// or https://.',
      );
    }
    api.baseUrl = normalized;
    await _preferences?.setString('backendUrl', normalized);
    notifyListeners();
  }

  Future<bool> login(
    String account,
    String password, {
    String? twoFactorCode,
  }) async {
    return _run(
      () async {
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/login',
                  body: <String, dynamic>{
                    'account': account,
                    'password': password,
                    'twoFactorCode': ?twoFactorCode,
                  },
                )
                as Map;
        await _acceptSession(payload);
        _pendingAccount = null;
        _pendingPassword = null;
        await refreshAll(silent: true);
      },
      onTwoFactor: () {
        _pendingAccount = account;
        _pendingPassword = password;
      },
    );
  }

  Future<bool> completeTwoFactor(String code) =>
      login(_pendingAccount ?? '', _pendingPassword ?? '', twoFactorCode: code);
  Future<bool> register(String usernameValue, String? email, String password) =>
      _run(() async {
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/register',
                  body: <String, dynamic>{
                    'username': usernameValue,
                    if (email?.isNotEmpty ?? false) 'email': email,
                    'password': password,
                  },
                )
                as Map;
        await _acceptSession(payload);
        await refreshAll(silent: true);
      });
  Future<void> _acceptSession(Map payload) async {
    final session = payload['session'] as Map;
    final user = payload['user'] as Map;
    api.token = session['token'] as String;
    username = user['username'] as String;
    await _secureStorage.write(key: 'sessionToken', value: api.token);
    await _preferences?.setString('username', username!);
    sync.pump.start();
  }

  Future<void> logout() async {
    try {
      await api.request('POST', '/api/v1/auth/logout');
    } catch (_) {}
    api.token = null;
    username = null;
    await _secureStorage.delete(key: 'sessionToken');
    notifyListeners();
  }

  Future<bool> _run(
    Future<void> Function() operation, {
    void Function()? onTwoFactor,
  }) async {
    loading = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await operation();
      return true;
    } on ApiException catch (exception) {
      if (exception.code == 'TWO_FACTOR_REQUIRED') onTwoFactor?.call();
      error = exception.message;
      return false;
    } catch (exception) {
      error = exception.toString();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> acceptConsent() async {
    consentAccepted = true;
    await _preferences?.setBool('recordingConsentAccepted', true);
    notifyListeners();
  }

  Future<void> setAutostart(bool enabled) async {
    final changed = await setStartupEnabled(enabled);
    if (!changed) throw StateError('Desktop autostart could not be changed.');
    autostartEnabled = enabled;
    notifyListeners();
  }

  String get _platform => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS => 'macos',
          TargetPlatform.windows => 'windows',
          _ => defaultTargetPlatform.name,
        };
  String get _deviceName => kIsWeb
      ? 'Web browser'
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS => 'Mac',
          TargetPlatform.windows => 'Windows PC',
          _ => 'Desktop',
        };

  Future<void> startRecording({
    required bool microphone,
    required bool systemAudio,
  }) async {
    if (!consentAccepted) {
      throw StateError('Recording consent must be acknowledged first.');
    }
    error = null;
    warning = null;
    notifyListeners();
    var ledgerStored = false;
    try {
      final settings = await _settings();
      final deviceId = _preferences!.getString('deviceId') ?? _uuid.v4();
      final clientUuid =
          _preferences!.getString('deviceClientUuid') ?? _uuid.v4();
      await _preferences!.setString('deviceId', deviceId);
      await _preferences!.setString('deviceClientUuid', clientUuid);
      final now = DateTime.now().toUtc();
      recordingStartedAt = now;
      final sessionId = _uuid.v4();
      final sourceId = _uuid.v4();
      final requestedKind = microphone && systemAudio
          ? 'combined'
          : systemAudio
          ? 'system'
          : 'microphone';
      _activeSession = LocalRecordingDeclaration(
        id: sessionId,
        sourceId: sourceId,
        deviceId: deviceId,
        deviceClientUuid: clientUuid,
        deviceName: _deviceName,
        platform: _platform,
        startedAt: now,
        timezone: settings['timezone'] as String? ?? 'UTC',
        consentAttestedAt: now,
        sourceKind: requestedKind,
        channelLayout: microphone && systemAudio
            ? 'microphone_left_system_right'
            : 'mono',
        // This reservation is not eligible for upload. Capture negotiation
        // replaces it with the actual device sample rate and source layout.
        synced: true,
      );
      _sequence = 0;
      await store.putSession(_activeSession!);
      ledgerStored = true;
      capability = await recorder.start(
        microphone: microphone,
        systemAudio: systemAudio,
        chunkMs: settings['chunkTargetMs'] as int? ?? 30000,
        overlapMs: settings['chunkOverlapMs'] as int? ?? 2000,
      );
      warning = capability!.warning;
      final layout = capability!.systemAudio && capability!.microphone
          ? 'microphone_left_system_right'
          : 'mono';
      _activeSession = LocalRecordingDeclaration(
        id: sessionId,
        sourceId: sourceId,
        deviceId: deviceId,
        deviceClientUuid: clientUuid,
        deviceName: _deviceName,
        platform: _platform,
        startedAt: now,
        timezone: settings['timezone'] as String? ?? 'UTC',
        consentAttestedAt: now,
        sourceKind: capability!.systemAudio && capability!.microphone
            ? 'combined'
            : capability!.systemAudio
            ? 'system'
            : 'microphone',
        channelLayout: layout,
        sampleRate: capability!.sampleRate,
      );
      await store.putSession(_activeSession!);
      sync.pump.pump();
    } catch (exception) {
      error = exception.toString();
      if (recorder.isRecording) await recorder.stop();
      await _partialWrite;
      await Future<void>.delayed(Duration.zero);
      await _chunkWrite;
      if (ledgerStored && _activeSession != null) {
        try {
          await store.putSession(
            _activeSession!.copyWith(
              endedAt: DateTime.now().toUtc(),
              finalSequence: _sequence - 1,
              interrupted: true,
              synced: false,
            ),
          );
          sync.pump.pump();
        } catch (_) {
          // Preserve the original capture failure. Startup recovery will close
          // the already-durable session on the next application launch.
        }
      }
      _activeSession = null;
      recordingStartedAt = null;
      audioLevel = 0;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _storeRecordedChunk(RecordedAudioChunk recorded) async {
    final session = _activeSession;
    if (session == null) return;
    final sequence = _sequence;
    final digest = sha256.convert(recorded.bytes).toString();
    final chunk = AudioChunk(
      id: _uuid.v4(),
      sessionId: session.id,
      sourceId: session.sourceId,
      sequence: sequence,
      startedAt: recorded.startedAt,
      monotonicOffsetMs: recorded.monotonicOffsetMs,
      durationMs: recorded.durationMs,
      overlapMs: recorded.overlapMs,
      channelLayout: recorded.channelLayout,
      container: 'wav',
      codec: 'pcm_s16le',
      sha256: digest,
      state: LocalChunkState.ready,
      createdAt: DateTime.now().toUtc(),
      isFinal: recorded.isFinal,
    );
    await _partialWrite;
    await store.put(chunk, recorded.bytes);
    _sequence = sequence + 1;
    await store.clearPartial(session.sourceId);
    await _refreshPending();
    sync.pump.pump();
  }

  Future<void> _storeCapturePartial(RecordedAudioChunk recorded) async {
    final session = _activeSession;
    if (session == null || recorded.bytes.isEmpty) return;
    final chunk = AudioChunk(
      id: _uuid.v4(),
      sessionId: session.id,
      sourceId: session.sourceId,
      sequence: _sequence,
      startedAt: recorded.startedAt,
      monotonicOffsetMs: recorded.monotonicOffsetMs,
      durationMs: recorded.durationMs,
      overlapMs: recorded.overlapMs,
      channelLayout: recorded.channelLayout,
      container: 'wav',
      codec: 'pcm_s16le',
      sha256: sha256.convert(recorded.bytes).toString(),
      state: LocalChunkState.capturing,
      createdAt: DateTime.now().toUtc(),
      isFinal: true,
    );
    await store.putPartial(chunk, recorded.bytes);
    await _refreshPending();
  }

  Future<void> stopRecording() async {
    if (_stoppingRecording) return;
    _stoppingRecording = true;
    try {
      await recorder.stop();
      await _partialWrite;
      await Future<void>.delayed(Duration.zero);
      await _chunkWrite;
      final session = _activeSession;
      if (session != null) {
        _activeSession = session.copyWith(
          endedAt: DateTime.now().toUtc(),
          finalSequence: _sequence - 1,
          synced: false,
        );
        await store.putSession(_activeSession!);
      }
      _activeSession = null;
      recordingStartedAt = null;
      audioLevel = 0;
      sync.pump.pump();
      notifyListeners();
    } finally {
      _stoppingRecording = false;
    }
  }

  Future<Map<String, dynamic>> _settings() async {
    if (!authenticated || !online) {
      return <String, dynamic>{'chunkTargetMs': 30000, 'chunkOverlapMs': 2000};
    }
    try {
      final payload = await api.request('GET', '/api/v1/settings') as Map;
      return Map<String, dynamic>.from(payload['settings'] as Map);
    } catch (_) {
      return <String, dynamic>{'chunkTargetMs': 30000, 'chunkOverlapMs': 2000};
    }
  }

  Future<void> _refreshPending() async {
    pendingAudioBytes = await store.pendingBytes();
    notifyListeners();
  }

  Future<void> refreshAll({bool silent = false}) async {
    if (!authenticated) return;
    if (!silent) {
      loading = true;
      notifyListeners();
    }
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        api.request('GET', '/api/v1/recordings'),
        api.request('GET', '/api/v1/memories'),
        api.request('GET', '/api/v1/mini-memories'),
        api.request('GET', '/api/v1/speakers'),
        api.request('GET', '/api/v1/devices'),
        api.request('GET', '/api/v1/transcripts?limit=100'),
        api.request('GET', '/api/v1/conversations?limit=100'),
        api.request('GET', '/api/v1/daily-summaries?limit=100'),
      ]);
      recordings = ((results[0] as Map)['items'] as List)
          .cast<Map>()
          .map(
            (value) =>
                RecordingSession.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
      memories = ((results[1] as Map)['items'] as List)
          .cast<Map>()
          .map(
            (value) => RecallMemory.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
      miniMemories = ((results[2] as Map)['items'] as List)
          .cast<Map>()
          .map((value) => MiniMemory.fromJson(Map<String, dynamic>.from(value)))
          .toList();
      speakers = ((results[3] as Map)['speakers'] as List)
          .cast<Map>()
          .map(
            (value) => RecallSpeaker.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
      devices = ((results[4] as Map)['devices'] as List)
          .cast<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      transcript = ((results[5] as Map)['items'] as List)
          .cast<Map>()
          .map(
            (value) =>
                TranscriptSegment.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
      conversations = ((results[6] as Map)['items'] as List)
          .cast<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      dailySummaries = ((results[7] as Map)['items'] as List)
          .cast<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      cachedData = false;
    } catch (exception) {
      cachedData = true;
      error = silent ? null : exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      searchResults = <Map<String, dynamic>>[];
      notifyListeners();
      return;
    }
    final payload =
        await api.request(
              'GET',
              '/api/v1/search?q=${Uri.encodeQueryComponent(query)}',
            )
            as Map;
    searchResults = (payload['results'] as List)
        .cast<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    askAnswer = null;
    askCitations = <Map<String, dynamic>>[];
    notifyListeners();
  }

  Future<void> ask(String question) async {
    final payload =
        await api.request(
              'POST',
              '/api/v1/search/ask',
              body: <String, dynamic>{'question': question},
            )
            as Map;
    askAnswer = payload['answer'] as String;
    askCitations = (payload['citations'] as List)
        .cast<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    notifyListeners();
  }

  Future<void> importAudio(
    List<int> bytes,
    String filename,
    String contentType,
  ) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final contentHash = sha256.convert(bytes).toString();
      final importId = _uuid.v5(
        Namespace.url.value,
        '$backendUrl:${username ?? ''}:$contentHash:${bytes.length}',
      );
      await api.importAudio(
        importId: importId,
        bytes: Uint8List.fromList(bytes),
        filename: filename,
        contentType: contentType,
      );
      notice = 'Import uploaded. Local transcription has been queued.';
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> renameSpeaker(String id, String name) async {
    await api.request(
      'PATCH',
      '/api/v1/speakers/$id',
      body: <String, dynamic>{'displayName': name},
    );
    await refreshAll(silent: true);
  }

  Future<void> mergeSpeaker(String targetId, String sourceId) async {
    await api.request(
      'POST',
      '/api/v1/speakers/$targetId/merge',
      body: <String, dynamic>{'sourceId': sourceId},
    );
    await refreshAll(silent: true);
  }

  Future<void> setSpeakerMatching(String id, bool enabled) async {
    await api.request(
      'PATCH',
      '/api/v1/speakers/$id',
      body: <String, dynamic>{'matchingEnabled': enabled},
    );
    await refreshAll(silent: true);
  }

  Future<Map<String, dynamic>> loadSettings() => _settings();
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    await api.request('PUT', '/api/v1/settings', body: changes);
    notice = 'Settings saved.';
    notifyListeners();
  }

  Future<void> revokeDevice(String id) async {
    await api.request('DELETE', '/api/v1/devices/$id');
    await refreshAll(silent: true);
  }

  Future<void> updateMiniMemory(String id, String status) async {
    await api.request(
      'PATCH',
      '/api/v1/mini-memories/$id',
      body: <String, dynamic>{'status': status},
    );
    await refreshAll(silent: true);
  }

  Future<void> consolidateNow() async {
    await api.request('POST', '/api/v1/memories/consolidations');
    notice = 'Memory consolidation queued.';
    notifyListeners();
  }

  void selectPage(RecallPage value) {
    page = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _chunkSubscription?.cancel();
    _partialSubscription?.cancel();
    _warningSubscription?.cancel();
    _levelSubscription?.cancel();
    _networkSubscription?.cancel();
    sync.close();
    recorder.dispose();
    super.dispose();
  }
}
