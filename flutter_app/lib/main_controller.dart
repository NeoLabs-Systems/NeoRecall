import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'src/api_client.dart';
import 'src/background/background_capture_service.dart';
import 'src/desktop/startup.dart';
import 'src/diagnostics/client_diagnostic_log.dart';
import 'src/devices/audio_device_adapter.dart';
import 'src/devices/audio_codec_decoder.dart';
import 'src/devices/device_registry_bootstrap.dart';
import 'src/devices/device_session_controller.dart';
import 'src/devices/device_storage_sync_scheduler.dart';
import 'src/devices/omi/offline_sync.dart';
import 'src/models/chunk.dart';
import 'src/models/memory.dart';
import 'src/models/recording.dart';
import 'src/models/speaker.dart';
import 'src/models/transcript.dart';
import 'src/network/network_state.dart';
import 'src/recording/audio_frame.dart';
import 'src/recording/audio_level_scale.dart';
import 'src/recording/recorder.dart';
import 'src/recording/recorder_mobile.dart';
import 'src/sync/chunk_store.dart';
import 'src/sync/sync_coordinator.dart';

enum RecallPage {
  record,
  timeline,
  memories,
  search,
  speakers,
  sources,
  devices,
  settings,
}

bool canRestoreSessionForBackend({
  required bool web,
  required String baseUrl,
}) => web || baseUrl.trim().isNotEmpty;

class NeoRecallController extends ChangeNotifier {
  NeoRecallController({
    NeoRecallApiClient? api,
    ChunkStore? store,
    RecallRecorder? recorder,
    AudioDeviceAdapterRegistry? audioDeviceRegistry,
    DeviceSessionController? audioDeviceSessions,
  }) : api = api ?? NeoRecallApiClient(baseUrl: _defaultBackendUrl),
       store = store ?? createChunkStore(),
       recorder = recorder ?? createRecorder() {
    final mobileRecorder = this.recorder;
    if (mobileRecorder is MobileRecallRecorder) {
      this.audioDeviceRegistry = mobileRecorder.registry;
      this.audioDeviceSessions = mobileRecorder.devices;
    } else {
      this.audioDeviceRegistry =
          audioDeviceRegistry ?? createDefaultDeviceRegistry();
      this.audioDeviceSessions =
          audioDeviceSessions ??
          DeviceSessionController(registry: this.audioDeviceRegistry);
    }
  }

  static const String _configuredBackendUrl = String.fromEnvironment(
    'NEORECALL_API_URL',
  );
  static const Map<String, dynamic> _fallbackSettings = <String, dynamic>{
    'consolidationIntervalMs': 3600000,
    'effectiveConsolidationIntervalMs': 3600000,
    'timezone': 'UTC',
    'recurringSpeakerMatching': true,
    'diarizationEnabled': true,
    'chunkTargetMs': 30000,
    'chunkOverlapMs': 2000,
    'chunkMinMs': 15000,
    'chunkMaxMs': 120000,
  };

  static String get _defaultBackendUrl {
    final configured = _configuredBackendUrl.trim();
    if (kIsWeb) {
      // Web is always served by NeoRecall itself under /app, so same-origin is
      // the correct default. An empty base URL keeps API calls relative.
      if (configured.isEmpty) return '';
      final configuredUri = Uri.tryParse(configured);
      final configuredHost = configuredUri?.host ?? '';
      if (_isLoopbackHost(configuredHost) && !_isLoopbackHost(Uri.base.host)) {
        return '';
      }
      return configured.replaceFirst(RegExp(r'/$'), '');
    }
    if (configured.isNotEmpty) {
      return configured.replaceFirst(RegExp(r'/$'), '');
    }
    // Native clients can run on a different device than the server. Falling
    // back to localhost silently points Android/iOS at the phone itself and
    // skips the required backend setup flow.
    return '';
  }

  static String get _sameOriginBackendUrl {
    final base = Uri.base;
    if (base.host.isEmpty) return '';
    return Uri(
      scheme: base.scheme.isEmpty ? 'http' : base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
    ).toString().replaceFirst(RegExp(r'/$'), '');
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized.isEmpty ||
        normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }

  static bool _shouldPreferSameOrigin(String candidate) {
    if (!kIsWeb) return false;
    final uri = Uri.tryParse(candidate.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return true;
    if (_isLoopbackHost(uri.host) && !_isLoopbackHost(Uri.base.host)) {
      return true;
    }
    // If the page is served by NeoRecall and the saved backend points at a
    // different host only because of an old default, keep same-origin.
    return false;
  }

  final NeoRecallApiClient api;
  final ChunkStore store;
  final RecallRecorder recorder;
  late final AudioDeviceAdapterRegistry audioDeviceRegistry;
  late final DeviceSessionController audioDeviceSessions;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Uuid _uuid = const Uuid();
  final AudioLevelScale _audioLevelScale = const AudioLevelScale();
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
  StreamSubscription<dynamic>? _deviceStateSubscription;
  StreamSubscription<DeviceControlEvent>? _deviceControlSubscription;
  StreamSubscription<BackgroundCaptureEvent>? _backgroundSubscription;
  SharedPreferences? _preferences;
  bool initialized = false;
  bool loading = false;
  bool online = true;
  bool consentAccepted = false;
  bool _stoppingRecording = false;
  bool _resumingMobileCapture = false;
  bool _switchingMobileSource = false;
  bool cachedData = false;
  bool autostartEnabled = false;
  bool preferBluetoothCapture = true;
  String? preferredDeviceLabel;
  String? error;
  String? notice;
  String? accountId;
  String? username;
  String? warning;
  bool isConfiguringTwoFactor = false;
  Map<String, dynamic> accountTwoFactor = const <String, dynamic>{};
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
  // Chunks parked after repeated server-side permanent failures; surfaced with a
  // manual retry so a stuck queue is visible instead of silently growing.
  int needsAttentionCount = 0;
  // Chunks whose upload is currently failing (transient); still auto-retried.
  int failedUploadCount = 0;
  // True when Android/OEM battery optimization may suspend always-on capture.
  bool backgroundCaptureAtRisk = false;
  // Offline device-storage sync (recordings held on the wearable's own flash).
  bool deviceStorageSyncing = false;
  int deviceStorageSyncedCount = 0;
  int deviceStoragePendingCount = 0;

  /// Live transfer progress of the running sweep, so a multi-minute drain shows
  /// how far it has got instead of an indeterminate spinner.
  WearableSyncProgress? deviceStorageSyncProgress;

  /// Audio still waiting on the device, refreshed when the device links and
  /// after each sweep. Lets the UI say what is outstanding before syncing.
  int deviceStoragePendingSeconds = 0;
  StreamSubscription<WearableSyncProgress>? _syncProgressSub;

  /// Asks the connected wearable how much it is holding, without transferring.
  Future<void> refreshDeviceStoragePending() async {
    final adapter = audioDeviceSessions.activeAdapter;
    if (adapter is! StorageSyncCapableAdapter) return;
    final storage = (adapter as StorageSyncCapableAdapter).offlineSyncConnector;
    if (storage == null) return;
    try {
      final pending = await storage.peekPending();
      if (pending == null) return;
      deviceStoragePendingSeconds = pending.pendingSeconds;
      notifyListeners();
    } catch (_) {
      // Advisory only; never surface a probe failure as a sync error.
    }
  }
  String? deviceStorageSyncError;
  static const int _deviceStorageMinBytes = 2048;
  // Automatic on-device recording sync. It runs on every platform (web
  // included), needs no user action, and keeps sweeping for as long as the
  // process lives — which on Android is for as long as the wearable link hold
  // keeps the foreground host alive, i.e. also while the app is swiped away.
  late final DeviceStorageSyncScheduler deviceStorageSync =
      DeviceStorageSyncScheduler(
        isEligible: _canSyncDeviceStorage,
        runSync: _runDeviceStorageSync,
      );
  double audioLevel = 0;
  DateTime? recordingStartedAt;
  RecorderCapability? capability;
  LocalRecordingDeclaration? _activeSession;
  int _sequence = 0;
  Future<void> _chunkWrite = Future<void>.value();
  Future<void> _partialWrite = Future<void>.value();
  String? _pendingAccount;
  String? _pendingPassword;
  bool _initializing = false;
  bool _syncInitialized = false;
  bool _deviceRuntimeInitialized = false;
  bool _runtimeSubscriptionsReady = false;
  String? initializationError;

  bool get authenticated => api.token != null && accountId != null;
  bool get isRecording => recorder.isRecording;

  // Devices that record on-device (button-triggered) rather than streaming live;
  // for these, pulling stored recordings is the primary action, not live capture.
  static const Set<String> _offlineFirstDeviceTypes = <String>{'heyPocket'};

  /// True when the connected wearable is an offline-first (button-record-on-
  /// device) type, so the UI can present "sync recordings" as the primary flow.
  bool get preferredDeviceIsOfflineFirst {
    final type = audioDeviceSessions.preferredDevice?.metadata['type'];
    return type is String && _offlineFirstDeviceTypes.contains(type);
  }

  /// True when the preferred wearable is actually connected right now — not
  /// merely saved as the preference. The device list must use this (rather than a
  /// name match) so its "connected" indicator never contradicts the sync card.
  bool get deviceConnected =>
      audioDeviceSessions.state == DeviceTransportState.connectedStandby ||
      audioDeviceSessions.state == DeviceTransportState.recording;

  /// True when a connected wearable exposes on-board storage that can be synced,
  /// so the UI can offer a manual "sync device recordings" action.
  bool get deviceStorageSyncAvailable {
    final adapter = audioDeviceSessions.activeAdapter;
    if (adapter is! StorageSyncCapableAdapter) return false;
    if ((adapter as StorageSyncCapableAdapter).offlineSyncConnector == null) {
      return false;
    }
    // A drain may run during live capture only where the device keeps the two on
    // independent channels (Omi does; HeyPocket does not). Everywhere else the
    // action stays idle-only, because a concurrent drain there would corrupt
    // both streams.
    final state = audioDeviceSessions.state;
    if (state == DeviceTransportState.connectedStandby) return true;
    return state == DeviceTransportState.recording &&
        (adapter as StorageSyncCapableAdapter)
            .offlineSyncConnector!
            .supportsConcurrentCapture;
  }
  String get backendUrl {
    if (api.baseUrl.isNotEmpty) return api.baseUrl;
    if (kIsWeb) return _sameOriginBackendUrl;
    return api.baseUrl;
  }

  /// Web is always same-origin. Native builds only expose server configuration
  /// when no backend URL was baked in at compile time.
  bool get allowsBackendUrlConfiguration =>
      !kIsWeb && _configuredBackendUrl.trim().isEmpty;

  bool get requiresBackendUrlSetup =>
      allowsBackendUrlConfiguration && api.baseUrl.trim().isEmpty;
  bool get initializing => _initializing;

  Future<void> initialize() async {
    if (_initializing) return;
    _initializing = true;
    if (error == initializationError) error = null;
    initializationError = null;
    notifyListeners();
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final savedBackendUrl =
          _preferences!.getString('backendUrl')?.trim() ?? '';
      if (!allowsBackendUrlConfiguration) {
        api.baseUrl = _defaultBackendUrl;
        if (savedBackendUrl.isNotEmpty) {
          await _preferences!.remove('backendUrl');
        }
      } else if (savedBackendUrl.isNotEmpty &&
          !_shouldPreferSameOrigin(savedBackendUrl)) {
        api.baseUrl = savedBackendUrl.replaceFirst(RegExp(r'/$'), '');
      } else {
        api.baseUrl = _defaultBackendUrl;
        if (savedBackendUrl.isNotEmpty) {
          await _preferences!.remove('backendUrl');
        }
      }
      if (requiresBackendUrlSetup && !initialized) {
        // Match NeoAgent's bootstrap behavior: show server setup as soon as
        // preferences are loaded. Local audio recovery continues without
        // holding the entire app behind a blank spinner.
        initialized = true;
        notifyListeners();
      }
      final backendIsConfigured = canRestoreSessionForBackend(
        web: kIsWeb,
        baseUrl: api.baseUrl,
      );
      if (backendIsConfigured) {
        api.token = await _secureStorage.read(key: 'sessionToken');
        accountId = _preferences!.getString('accountId');
        username = _preferences!.getString('username');
      } else {
        // A token is valid only for the server that issued it. Never attach a
        // cached native session to a backend selected later by the user.
        api.token = null;
        accountId = null;
        username = null;
      }
      consentAccepted =
          _preferences!.getBool('recordingConsentAccepted') ?? false;
      try {
        autostartEnabled = await startupEnabled();
      } catch (_) {
        // Autostart is a desktop convenience and must never block mobile boot.
        autostartEnabled = false;
      }
      if (!_syncInitialized) {
        await sync.initialize();
        _syncInitialized = true;
      }
      if (api.token != null && backendIsConfigured) {
        try {
          final payload = await api.request('GET', '/api/v1/auth/me') as Map;
          final user = payload['user'] as Map;
          accountId = user['id'] as String;
          username = user['username'] as String;
          sync.pump.accountId = accountId;
          // Databases created before account ownership was added can only be
          // claimed by the still-authenticated session present during upgrade.
          await store.claimLegacySessions(accountId!);
          await _preferences!.setString('accountId', accountId!);
        } on ApiException catch (exception) {
          if (exception.status != 401 && exception.status != 403) {
            sync.pump.accountId = accountId;
            if (accountId != null) await store.claimLegacySessions(accountId!);
          } else {
            api.token = null;
            accountId = null;
            username = null;
            sync.pump.accountId = null;
            await _secureStorage.delete(key: 'sessionToken');
            await _preferences!.remove('accountId');
            await _preferences!.remove('username');
          }
        } catch (_) {
          // Offline startup keeps the last server-proven account binding. The
          // token is not discarded merely because this device cannot reach the
          // server; queued audio remains account-scoped and upload stays paused.
          sync.pump.accountId = accountId;
          if (accountId != null) await store.claimLegacySessions(accountId!);
        }
        if (accountId == null) {
          api.token = null;
          username = null;
          sync.pump.accountId = null;
          await _secureStorage.delete(key: 'sessionToken');
          await _preferences!.remove('accountId');
          await _preferences!.remove('username');
        }
      }
      await ClientDiagnosticLog.instance.bindAccount(accountId);
      ClientDiagnosticLog.instance.record(
        'application',
        'startup_completed',
        details: <String, Object?>{
          'authenticated': authenticated,
          'platform': _platform,
          'backendMode': kIsWeb ? 'same_origin' : 'configured',
        },
      );
      if (!_deviceRuntimeInitialized) {
        if (recorder is MobileRecallRecorder) {
          await (recorder as MobileRecallRecorder).initialize(
            accountId: accountId,
          );
        } else {
          await audioDeviceRegistry.initializeAll();
          await audioDeviceSessions.bindAccount(accountId);
        }
        _deviceRuntimeInitialized = true;
        preferBluetoothCapture = audioDeviceSessions.preferBluetooth;
        preferredDeviceLabel = audioDeviceSessions.preferredDevice?.displayName;
        _deviceStateSubscription = audioDeviceSessions.states.listen((state) {
          preferredDeviceLabel =
              audioDeviceSessions.preferredDevice?.displayName;
          _handleDeviceTransportState(state);
          notifyListeners();
        });
        _deviceControlSubscription = audioDeviceSessions.controlEvents.listen(
          _handleDeviceControlEvent,
        );
        if (recorder is MobileRecallRecorder) {
          final mobile = recorder as MobileRecallRecorder;
          _backgroundSubscription = mobile.background.events.listen((event) {
            switch (event.type) {
              case BackgroundCaptureEventType.stopRequested:
                // The notification's Stop releases everything the background
                // host was holding — capture and the wearable link — until the
                // app is opened again.
                unawaited(_releaseBackgroundRuntime(mobile));
              case BackgroundCaptureEventType.batteryOptimizationActive:
                backgroundCaptureAtRisk = true;
                notifyListeners();
              case BackgroundCaptureEventType.microphoneUnavailable:
                warning = event.message;
                notifyListeners();
              case BackgroundCaptureEventType.message:
                break;
            }
          });
          // A host restored after a reboot reports a dropped microphone hold
          // before anything can listen; read it once subscriptions are live.
          if (mobile.background.state.microphoneUnavailable) {
            warning = backgroundMicrophoneUnavailableMessage;
          }
        }
      }
      if (!_runtimeSubscriptionsReady) {
        _attachRuntimeSubscriptions();
        _runtimeSubscriptionsReady = true;
      }
      // Automatic device-storage sync needs no user action and no open UI.
      deviceStorageSync.start();
      // Recover interrupted offline sessions/chunks before new capture starts.
      sync.pump.pump();
      await _refreshPending();
      if (authenticated) await refreshAll(silent: true);
      if (_supportsDurableMobileResume) {
        unawaited(_resumeMobileCaptureIfRequested());
      }
    } catch (exception) {
      initializationError =
          'NeoRecall could not finish local startup. Your queued audio was not deleted. Retry to recover safely.';
      error = initializationError;
      debugPrint('NeoRecall initialization failed: $exception');
    } finally {
      initialized = true;
      _initializing = false;
      notifyListeners();
    }
  }

  void _attachRuntimeSubscriptions() {
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
      audioLevel = _audioLevelScale.smooth(
        audioLevel,
        _audioLevelScale.normalizeRms(value),
      );
      notifyListeners();
    });
    _networkSubscription = networkAvailability().listen((available) {
      online = available;
      if (available) sync.pump.pump();
      notifyListeners();
    });
  }

  Future<bool> setBackendUrl(String value) async {
    if (!allowsBackendUrlConfiguration) {
      // Web and compile-time configured clients keep their fixed backend target.
      api.baseUrl = kIsWeb ? '' : _defaultBackendUrl;
      await _preferences?.remove('backendUrl');
      notifyListeners();
      return true;
    }
    final normalized = value.trim().replaceFirst(RegExp(r'/$'), '');
    if (kIsWeb &&
        (normalized.isEmpty ||
            normalized == _sameOriginBackendUrl ||
            _shouldPreferSameOrigin(normalized))) {
      api.baseUrl = '';
      await _preferences?.remove('backendUrl');
      notifyListeners();
      return true;
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      error = 'Enter a complete server URL including http:// or https://.';
      notifyListeners();
      return false;
    }
    final previous = api.baseUrl;
    loading = true;
    error = null;
    notifyListeners();
    try {
      api.baseUrl = normalized;
      final health = await api.request('GET', '/health');
      if (health is! Map || health['status'] != 'ok') {
        throw const FormatException(
          'The address did not return a NeoRecall health response.',
        );
      }
      _preferences ??= await SharedPreferences.getInstance();
      await _preferences!.setString('backendUrl', normalized);
      return true;
    } on ApiException catch (exception) {
      api.baseUrl = previous;
      error = exception.message;
      return false;
    } catch (_) {
      api.baseUrl = previous;
      error =
          'NeoRecall could not reach that server. Check the address and that the server is running.';
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
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
    accountId = user['id'] as String;
    username = user['username'] as String;
    sync.pump.accountId = accountId;
    await audioDeviceSessions.bindAccount(accountId);
    await ClientDiagnosticLog.instance.bindAccount(accountId);
    ClientDiagnosticLog.instance.record(
      'authentication',
      'session_started',
      details: <String, Object?>{'platform': _platform},
    );
    preferBluetoothCapture = audioDeviceSessions.preferBluetooth;
    preferredDeviceLabel = audioDeviceSessions.preferredDevice?.displayName;
    await _secureStorage.write(key: 'sessionToken', value: api.token);
    await _preferences?.setString('accountId', accountId!);
    await _preferences?.setString('username', username!);
    sync.pump.start();
    await _refreshPending();
  }

  Future<void> logout() async {
    if (isRecording) await stopRecording();
    await audioDeviceSessions.bindAccount(null);
    await ClientDiagnosticLog.instance.bindAccount(null);
    preferredDeviceLabel = null;
    try {
      await api.request('POST', '/api/v1/auth/logout');
    } catch (_) {}
    sync.pump.accountId = null;
    api.token = null;
    accountId = null;
    username = null;
    pendingAudioBytes = 0;
    await _secureStorage.delete(key: 'sessionToken');
    await _preferences?.remove('accountId');
    await _preferences?.remove('username');
    accountTwoFactor = const <String, dynamic>{};
    notifyListeners();
  }

  Future<void> fetchTwoFactorStatus() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('GET', '/api/v1/settings/2fa');
      accountTwoFactor = Map<String, dynamic>.from(response as Map);
    } catch (_) {
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> beginTwoFactorSetup() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('POST', '/api/v1/settings/2fa/setup');
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      error = e.toString();
      return null;
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<List<String>> enableTwoFactor(String code) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('POST', '/api/v1/settings/2fa/enable', body: {'code': code});
      await fetchTwoFactorStatus();
      final map = response as Map;
      if (map['recoveryCodes'] is List) {
        return (map['recoveryCodes'] as List).cast<String>();
      }
      return [];
    } catch (e) {
      error = e.toString();
      return [];
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<void> disableTwoFactor({required String password, String? code}) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      await api.request('DELETE', '/api/v1/settings/2fa', body: {'password': password, 'code': ?code});
      await fetchTwoFactorStatus();
    } catch (e) {
      error = e.toString();
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<List<String>> regenerateTwoFactorCodes({required String password, required String code}) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request('POST', '/api/v1/settings/2fa/recovery-codes', body: {'password': password, 'code': code});
      await fetchTwoFactorStatus();
      final map = response as Map;
      if (map['recoveryCodes'] is List) {
        return (map['recoveryCodes'] as List).cast<String>();
      }
      return [];
    } catch (e) {
      error = e.toString();
      return [];
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<String> buildDiagnosticExport() async {
    if (!authenticated) {
      throw StateError('Sign in before exporting diagnostics.');
    }
    Object backend;
    var backendAvailable = true;
    try {
      backend = await api.request('GET', '/api/v1/diagnostics/export');
    } catch (error) {
      backendAvailable = false;
      backend = <String, Object?>{
        'available': false,
        'error': error.toString(),
      };
    }
    ClientDiagnosticLog.instance.record(
      'diagnostics',
      'export_created',
      details: <String, Object?>{'backendAvailable': backendAvailable},
    );
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'schemaVersion': 2,
      'client': <String, Object?>{
        ...ClientDiagnosticLog.instance.clientSummary(),
        'wearableAudioCodec': wearableAudioCodecStatus,
        'preferredDevice': audioDeviceSessions.preferredDevice?.displayName,
        'preferredDeviceType':
            audioDeviceSessions.preferredDevice?.metadata['type'],
        'deviceState': audioDeviceSessions.state.name,
        'deviceConnected': deviceConnected,
        'pendingAudioBytes': pendingAudioBytes,
        'needsAttentionCount': needsAttentionCount,
      },
      'backend': backend,
    });
  }

  /// Recent diagnostic events (newest last) for the in-app viewer.
  List<Map<String, Object?>> get diagnosticEvents =>
      ClientDiagnosticLog.instance.recent(80);

  int get diagnosticEventCount => ClientDiagnosticLog.instance.length;

  /// One readable line for a diagnostic event (used by the viewer).
  String formatDiagnosticEvent(Map<String, Object?> event) =>
      ClientDiagnosticLog.instance.formatLine(event);

  /// Wipes the local diagnostic log (the "delete" action in Settings).
  Future<void> clearDiagnostics() async {
    await ClientDiagnosticLog.instance.clear();
    ClientDiagnosticLog.instance.record(
      'diagnostics',
      'log_cleared',
      details: <String, Object?>{'by': 'user'},
    );
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
          TargetPlatform.android => 'android',
          TargetPlatform.iOS => 'ios',
          TargetPlatform.linux => 'linux',
          _ => defaultTargetPlatform.name,
        };
  String get _deviceName => kIsWeb
      ? 'Web browser'
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS => 'Mac',
          TargetPlatform.windows => 'Windows PC',
          TargetPlatform.android => 'Android phone',
          TargetPlatform.iOS => 'iPhone',
          TargetPlatform.linux => 'Linux desktop',
          _ => 'Device',
        };

  bool get isMobileCapturePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _supportsDurableMobileResume =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get hasPreferredBluetoothDevice =>
      audioDeviceSessions.hasPreferredDevice;

  Future<void> setPreferBluetoothCapture(bool enabled) async {
    preferBluetoothCapture = enabled;
    await audioDeviceSessions.setPreferBluetooth(enabled);
    if (enabled && audioDeviceSessions.hasPreferredDevice) {
      await audioDeviceSessions.connectPreferred();
    }
    preferredDeviceLabel = audioDeviceSessions.preferredDevice?.displayName;
    notifyListeners();
  }

  Future<void> preferBluetoothDevice(AudioDeviceDescriptor device) async {
    await audioDeviceSessions.prefer(device);
    preferBluetoothCapture = true;
    preferredDeviceLabel = device.displayName;
    notifyListeners();
  }

  Future<void> clearPreferredBluetoothDevice() async {
    await audioDeviceSessions.clearPreferred();
    preferredDeviceLabel = null;
    notifyListeners();
  }

  List<AudioDeviceDescriptor> discoveredWearables = <AudioDeviceDescriptor>[];
  bool scanningWearables = false;

  Future<void> scanForWearables({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (audioDeviceRegistry.adapters.isEmpty) {
      throw StateError(
        'No validated Bluetooth device protocol is installed yet.',
      );
    }
    scanningWearables = true;
    discoveredWearables = <AudioDeviceDescriptor>[];
    // Each scan reports its own outcome; a leftover notice from the previous one
    // would otherwise stay on screen and contradict this run.
    notice = null;
    notifyListeners();
    final subs = <StreamSubscription<dynamic>>[];
    final firstWebDiscovery = Completer<void>();
    try {
      for (final adapter in audioDeviceRegistry.adapters) {
        subs.add(
          adapter.discoveries.listen((device) {
            if (discoveredWearables.any(
              (item) => item.deviceKey == device.deviceKey,
            )) {
              discoveredWearables = discoveredWearables
                  .map(
                    (item) =>
                        item.deviceKey == device.deviceKey ? device : item,
                  )
                  .toList(growable: false);
            } else {
              discoveredWearables = <AudioDeviceDescriptor>[
                ...discoveredWearables,
                device,
              ];
            }
            if (kIsWeb && !firstWebDiscovery.isCompleted) {
              firstWebDiscovery.complete();
            }
            notifyListeners();
          }),
        );
        await adapter.startScan(timeout: timeout);
      }
      if (kIsWeb) {
        await Future.any<void>(<Future<void>>[
          Future<void>.delayed(timeout),
          firstWebDiscovery.future,
        ]);
      } else {
        await Future<void>.delayed(timeout);
      }
    } finally {
      for (final adapter in audioDeviceRegistry.adapters) {
        await adapter.stopScan();
      }
      for (final sub in subs) {
        await sub.cancel();
      }
      scanningWearables = false;
      // A scan that finds nothing looks identical to a broken scan, so say which
      // it was instead of leaving an empty list on screen. Every cause here is
      // actionable by the user.
      if (discoveredWearables.isEmpty) {
        notice = kIsWeb
            ? 'No device was selected in the browser chooser.'
            : 'No supported device found. Check that the wearable is switched '
                  'on, close by, and not already connected to another app or phone.';
      }
      notifyListeners();
    }
  }

  Future<void> startRecording({
    required bool microphone,
    required bool systemAudio,
    bool? bluetooth,
  }) async {
    if (!consentAccepted) {
      throw StateError('Recording consent must be acknowledged first.');
    }
    final useBluetooth =
        bluetooth ?? (!microphone && !systemAudio && preferBluetoothCapture);
    ExternalAudioCaptureDevice? externalDevice;
    if (useBluetooth) {
      final descriptor = audioDeviceSessions.preferredDevice;
      final adapter =
          audioDeviceSessions.activeAdapter ??
          (descriptor == null
              ? null
              : audioDeviceRegistry[descriptor.adapterId]);
      if (descriptor == null || adapter == null) {
        throw StateError(
          'Connect a supported Bluetooth device before starting capture.',
        );
      }
      final transportReady =
          audioDeviceSessions.state == DeviceTransportState.connectedStandby ||
          audioDeviceSessions.state == DeviceTransportState.recording ||
          await audioDeviceSessions.connectPreferred();
      if (!transportReady) {
        throw StateError(
          'The Bluetooth device could not be connected. Keep it nearby and try again.',
        );
      }
      // A live capture and an offline drain must never run together (they share
      // the BLE channel/buffer on several wearables). If a device-storage sync
      // is in flight, stop it before taking the stream over for live capture.
      await _stopDeviceStorageSyncForCapture(adapter);
      externalDevice = ExternalAudioCaptureDevice(
        adapter: adapter,
        descriptor: descriptor,
      );
      microphone = false;
      systemAudio = false;
    }
    if (isMobileCapturePlatform) {
      // Mobile never uses desktop system-audio capture.
      systemAudio = false;
      if (!useBluetooth) microphone = true;
    }
    if (!microphone && !systemAudio && externalDevice == null) {
      throw StateError('Select at least one capture source.');
    }
    error = null;
    warning = null;
    notifyListeners();
    var ledgerStored = false;
    try {
      final settings = await _settings();
      final recordingAccountId = accountId;
      if (recordingAccountId == null) {
        throw StateError('Sign in before starting a recording.');
      }
      final deviceIdKey = 'deviceId:$recordingAccountId';
      final deviceClientUuidKey = 'deviceClientUuid:$recordingAccountId';
      final deviceId = _preferences!.getString(deviceIdKey) ?? _uuid.v4();
      final clientUuid =
          _preferences!.getString(deviceClientUuidKey) ?? _uuid.v4();
      await _preferences!.setString(deviceIdKey, deviceId);
      await _preferences!.setString(deviceClientUuidKey, clientUuid);
      final now = DateTime.now().toUtc();
      recordingStartedAt = now;
      final sessionId = _uuid.v4();
      final sourceId = _uuid.v4();
      final requestedKind = microphone && systemAudio
          ? 'combined'
          : systemAudio
          ? 'system'
          : useBluetooth
          ? 'wearable'
          : 'microphone';
      _activeSession = LocalRecordingDeclaration(
        id: sessionId,
        accountId: recordingAccountId,
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
        chunkMs:
            settings['chunkTargetMs'] as int? ??
            _fallbackSettings['chunkTargetMs']! as int,
        overlapMs:
            settings['chunkOverlapMs'] as int? ??
            _fallbackSettings['chunkOverlapMs']! as int,
        externalDevice: externalDevice,
      );
      warning = capability!.warning;
      final layout = capability!.systemAudio && capability!.microphone
          ? 'microphone_left_system_right'
          : 'mono';
      _activeSession = LocalRecordingDeclaration(
        id: sessionId,
        accountId: recordingAccountId,
        sourceId: sourceId,
        deviceId: deviceId,
        deviceClientUuid: clientUuid,
        deviceName: _deviceName,
        platform: _platform,
        startedAt: now,
        timezone: settings['timezone'] as String? ?? 'UTC',
        consentAttestedAt: now,
        sourceKind: capability!.sourceKind,
        channelLayout: layout,
        sampleRate: capability!.sampleRate,
      );
      await store.putSession(_activeSession!);
      if (_supportsDurableMobileResume) {
        await _preferences!.setString(
          _mobileCaptureIntentKey(recordingAccountId),
          capability!.sourceKind == 'wearable' ? 'bluetooth' : 'microphone',
        );
      }
      sync.pump.pump();
    } catch (exception) {
      error = exception.toString();
      // Capture never took the device, so release the claim — otherwise a failed
      // start would silently disable automatic sync for the rest of the session.
      _deviceClaimedForCapture = false;
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
      if (recorder is MobileRecallRecorder) {
        await (recorder as MobileRecallRecorder).finishBackgroundHost();
      }
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
    // The wearable is free again; automatic sweeps may resume.
    _deviceClaimedForCapture = false;
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
      final stoppingAccountId = session?.accountId ?? accountId;
      if (_supportsDurableMobileResume && stoppingAccountId != null) {
        await _preferences!.remove(_mobileCaptureIntentKey(stoppingAccountId));
      }
      _activeSession = null;
      recordingStartedAt = null;
      audioLevel = 0;
      // The background battery warning is only meaningful during active capture.
      backgroundCaptureAtRisk = false;
      sync.pump.pump();
      if (recorder is MobileRecallRecorder) {
        await (recorder as MobileRecallRecorder).finishBackgroundHost();
      }
      notifyListeners();
    } finally {
      _stoppingRecording = false;
    }
  }

  String _mobileCaptureIntentKey(String ownerAccountId) =>
      'mobileCaptureIntent:$ownerAccountId';

  /// Whether linking a known wearable should start live capture by itself, so
  /// the user does not have to open the app and press record on every reconnect.
  ///
  /// Deliberately narrow, because starting a recording unprompted is not a
  /// neutral act: only on mobile (the always-on host), only when the user
  /// already chose Bluetooth as their capture source, only once consent has been
  /// given, and only for devices that actually stream live — an offline-first
  /// recorder has nothing to stream, and its sync is the whole point. Recording
  /// stays visibly indicated exactly as a manual start does. The offline drain
  /// is unaffected and keeps running alongside on devices that support it, so a
  /// reconnect resumes the present and recovers the gap at the same time.
  bool get shouldAutoStartLiveCapture {
    if (!isMobileCapturePlatform) return false;
    if (!authenticated || !consentAccepted) return false;
    if (!preferBluetoothCapture) return false;
    if (isRecording || _resumingMobileCapture || _switchingMobileSource) {
      return false;
    }
    // Offline-first wearables record on the device itself; there is no live
    // stream to start, and claiming the channel would only stall their sync.
    if (preferredDeviceIsOfflineFirst) return false;
    return hasPreferredBluetoothDevice;
  }

  /// Guards the window between deciding to auto-start and the recorder actually
  /// reporting isRecording: a flapping link can deliver two connectedStandby
  /// events inside it, and two concurrent starts would fight over the device.
  bool _autoStartingLiveCapture = false;

  Future<void> _startLiveCaptureOnLink() async {
    if (_autoStartingLiveCapture) return;
    if (!shouldAutoStartLiveCapture) return;
    _autoStartingLiveCapture = true;
    try {
      await startRecording(microphone: false, systemAudio: false, bluetooth: true);
      ClientDiagnosticLog.instance.record(
        'device_capture',
        'live_autostarted_on_link',
        details: <String, Object?>{
          'device': audioDeviceSessions.preferredDevice?.displayName,
        },
      );
    } catch (error) {
      // A failed auto-start must never look like a crash: the user can still
      // press record, and the device keeps syncing regardless.
      ClientDiagnosticLog.instance.record(
        'device_capture',
        'live_autostart_failed',
        level: 'warning',
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _resumeMobileCaptureIfRequested() async {
    if (_resumingMobileCapture) return;
    final ownerAccountId = accountId;
    if (ownerAccountId == null ||
        !authenticated ||
        !consentAccepted ||
        isRecording) {
      return;
    }
    final mode = _preferences?.getString(
      _mobileCaptureIntentKey(ownerAccountId),
    );
    if (mode == null) return;
    _resumingMobileCapture = true;
    try {
      if (mode == 'bluetooth' && !hasPreferredBluetoothDevice) {
        warning =
            'Background capture could not resume because its Bluetooth device is not configured.';
        notifyListeners();
        return;
      }
      if (mode == 'microphone' &&
          recorder is MobileRecallRecorder &&
          !await (recorder as MobileRecallRecorder).hasAttachedUi()) {
        // The system started this process on its own (reboot or a sticky
        // restart) and denies microphone access to a process with no UI.
        // Keep the durable intent and resume when the app is opened, rather
        // than starting a capture that would record silence.
        warning =
            'Phone-microphone recording is waiting for NeoRecall to be opened. '
            'Bluetooth capture and device sync continue in the background.';
        notifyListeners();
        return;
      }
      await startRecording(
        microphone: mode == 'microphone',
        systemAudio: false,
        bluetooth: mode == 'bluetooth',
      );
      notice =
          'Background recording recovered after the app process restarted.';
      if (recorder is MobileRecallRecorder) {
        _handleDeviceTransportState(
          (recorder as MobileRecallRecorder).devices.state,
        );
      }
    } catch (exception) {
      warning = 'Background recording recovery is waiting: $exception';
      notifyListeners();
    } finally {
      _resumingMobileCapture = false;
    }
  }

  void _handleDeviceControlEvent(DeviceControlEvent event) {
    switch (event.type) {
      case DeviceControlEventType.startRecording:
        if (!isRecording && authenticated && consentAccepted) {
          unawaited(_startFromDeviceControl());
        }
      case DeviceControlEventType.stopRecording:
      case DeviceControlEventType.standby:
      case DeviceControlEventType.powerOff:
        if (isRecording) unawaited(stopRecording());
      case DeviceControlEventType.powerOn:
      case DeviceControlEventType.wake:
        unawaited(audioDeviceSessions.connectPreferred());
      case DeviceControlEventType.battery:
      case DeviceControlEventType.singlePress:
      case DeviceControlEventType.doublePress:
      case DeviceControlEventType.longPress:
      case DeviceControlEventType.buttonRelease:
      case DeviceControlEventType.custom:
        break;
    }
  }

  void _handleDeviceTransportState(DeviceTransportState state) {
    ClientDiagnosticLog.instance.record(
      'device_transport',
      'state_changed',
      level: state == DeviceTransportState.faulted ? 'warning' : 'info',
      details: <String, Object?>{
        'state': state.name,
        'device': audioDeviceSessions.preferredDevice?.displayName,
        'type': audioDeviceSessions.preferredDevice?.metadata['type'],
      },
    );
    if (state == DeviceTransportState.disconnected ||
        state == DeviceTransportState.faulted) {
      deviceStorageSync.onDeviceUnlinked();
    } else if (state == DeviceTransportState.connectedStandby) {
      // §9: after each (re)connect, pull anything the device recorded offline,
      // then keep sweeping while it stays linked so later recordings arrive on
      // their own — with or without the app open.
      deviceStorageSync.onDeviceLinked();
      // Show what the device is holding as soon as it links, so the amount is
      // known before the user decides to sync.
      unawaited(refreshDeviceStoragePending());
      unawaited(_startLiveCaptureOnLink());
    }
    final connected =
        state == DeviceTransportState.connectedStandby ||
        state == DeviceTransportState.recording;
    if (!isRecording) {
      if (_supportsDurableMobileResume && connected) {
        unawaited(_resumeMobileCaptureIfRequested());
      }
      return;
    }
    if (!isMobileCapturePlatform) {
      if ((state == DeviceTransportState.disconnected ||
              state == DeviceTransportState.faulted) &&
          capability?.sourceKind == 'wearable') {
        warning =
            'The Bluetooth audio source disconnected. Reconnect the device or stop the recording to finalize it.';
        notifyListeners();
      }
      return;
    }
    final activeKind = capability?.sourceKind;
    if ((state == DeviceTransportState.disconnected ||
            state == DeviceTransportState.faulted) &&
        activeKind == 'wearable') {
      unawaited(_restartMobileCapture(useBluetooth: false));
    } else if (connected &&
        preferBluetoothCapture &&
        activeKind == 'microphone') {
      unawaited(_restartMobileCapture(useBluetooth: true));
    }
  }

  Future<void> _restartMobileCapture({required bool useBluetooth}) async {
    if (_switchingMobileSource || !isRecording) return;
    _switchingMobileSource = true;
    try {
      await stopRecording();
      await startRecording(
        microphone: !useBluetooth,
        systemAudio: false,
        bluetooth: useBluetooth,
      );
      notice = useBluetooth
          ? 'Recording moved back to the reconnected Bluetooth device.'
          : 'Bluetooth disconnected; recording continues with the phone microphone.';
      notifyListeners();
    } catch (exception) {
      warning = 'Audio source recovery failed: $exception';
      notifyListeners();
    } finally {
      _switchingMobileSource = false;
    }
  }

  Future<void> _startFromDeviceControl() async {
    try {
      await setPreferBluetoothCapture(true);
      await startRecording(microphone: false, systemAudio: false);
    } catch (exception) {
      warning =
          'The device requested recording, but capture could not start: $exception';
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _settings() async {
    if (!authenticated || !online) {
      return Map<String, dynamic>.from(_fallbackSettings);
    }
    try {
      final payload = await api.request('GET', '/api/v1/settings') as Map;
      return Map<String, dynamic>.from(payload['settings'] as Map);
    } catch (_) {
      return Map<String, dynamic>.from(_fallbackSettings);
    }
  }

  Future<void> _refreshPending() async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null) {
      pendingAudioBytes = 0;
      needsAttentionCount = 0;
      failedUploadCount = 0;
      notifyListeners();
      return;
    }
    pendingAudioBytes = await store.pendingBytes(ownerAccountId);
    try {
      final chunks = await store.pending(ownerAccountId, limit: 500);
      needsAttentionCount = chunks
          .where((chunk) => chunk.state == LocalChunkState.needsAttention)
          .length;
      failedUploadCount = chunks
          .where((chunk) => chunk.state == LocalChunkState.failed)
          .length;
    } catch (_) {
      // Counts are best-effort UI hints; never block on them.
    }
    notifyListeners();
  }

  /// Re-queues every chunk parked as needsAttention and kicks the pump. Used by
  /// the "retry failed uploads" action so the user can recover a stuck queue.
  Future<void> retryFailedUploads() async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null) return;
    final chunks = await store.pending(ownerAccountId, limit: 500);
    for (final chunk in chunks.where(
      (chunk) => chunk.state == LocalChunkState.needsAttention,
    )) {
      await store.setState(chunk.id, LocalChunkState.ready);
    }
    sync.pump.forgetAttempts();
    await _refreshPending();
    sync.pump.pump();
  }

  /// Opens OS settings so the user can lift battery restrictions that would
  /// otherwise let the system suspend always-on background capture.
  Future<void> openBatterySettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await openAppSettings();
  }

  /// Called when the app returns to the foreground. Proactively resumes sync and
  /// refreshes data instead of waiting for the periodic timer.
  Future<void> onAppResumed() async {
    if (recorder is MobileRecallRecorder) {
      final mobile = recorder as MobileRecallRecorder;
      // Re-arm a runtime the user released from the notification, and retry a
      // microphone capture that could not resume while no UI was attached.
      await mobile.resumeBackgroundRuntime();
      if (_supportsDurableMobileResume) {
        unawaited(_resumeMobileCaptureIfRequested());
      }
    }
    if (!authenticated) return;
    sync.pump.pump();
    await _refreshPending();
    await refreshAll(silent: true);
    // Pull anything the wearable recorded while the app was backgrounded.
    unawaited(syncDeviceStorage());
  }

  /// Releases every background hold after the user tapped Stop on the
  /// notification: capture ends, the wearable is unlinked, and the host stops.
  Future<void> _releaseBackgroundRuntime(MobileRecallRecorder mobile) async {
    if (isRecording) await stopRecording();
    await mobile.pauseBackgroundRuntime();
    notice =
        'Background recording and device sync are paused. Open NeoRecall to resume them.';
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
      ClientDiagnosticLog.instance.record(
        'file_import',
        'import_started',
        details: <String, Object?>{
          'importId': importId,
          'bytes': bytes.length,
          'mime': contentType,
          'filename': filename,
          'source': 'file',
        },
      );
      await api.importAudio(
        importId: importId,
        bytes: Uint8List.fromList(bytes),
        filename: filename,
        contentType: contentType,
      );
      ClientDiagnosticLog.instance.record(
        'file_import',
        'import_accepted',
        details: <String, Object?>{'importId': importId, 'bytes': bytes.length},
      );
      notice = 'Import uploaded. Local transcription has been queued.';
    } catch (exception) {
      ClientDiagnosticLog.instance.record(
        'file_import',
        'import_failed',
        level: 'error',
        details: <String, Object?>{'error': exception.toString()},
      );
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Aborts an in-flight device-storage drain so a live capture can take over
  /// the wearable's BLE channel. Returns once the connector has stopped routing
  /// stored audio (so a subsequent live subscription can never be cross-fed).
  /// Safe to call when nothing is syncing.
  Future<void> _stopDeviceStorageSyncForCapture(
    AudioDeviceAdapter adapter,
  ) async {
    if (adapter is! StorageSyncCapableAdapter) return;
    final storage = (adapter as StorageSyncCapableAdapter).offlineSyncConnector;
    if (storage == null) return;
    // Devices that keep live audio and their storage on separate channels can
    // keep draining right through the capture — stopping it would be pure loss.
    if (storage.supportsConcurrentCapture) return;
    // Claim the device first and unconditionally: with no sweep in flight this
    // method used to return immediately, leaving the periodic poll free to start
    // one during the rest of capture setup.
    _deviceClaimedForCapture = true;
    if (!deviceStorageSync.isRunning) return;
    try {
      await storage.cancelStoredSync();
    } catch (_) {
      // Best-effort: the drain also unwinds on its own timeout/disconnect.
    }
    // Automatic sweeps run unattended, so the cancel above may land mid-drain.
    // Wait for the sweep to actually unwind before the live stream subscribes,
    // otherwise stored audio could still be routed into the live capture.
    await deviceStorageSync.activeSweep;
  }

  /// Set while a live capture is claiming the wearable's BLE channel.
  ///
  /// `isRecording` only becomes true once capture is running, so between
  /// cancelling the drain and that point an automatic sweep could still start
  /// and take the channel back. The claim closes that window.
  bool _deviceClaimedForCapture = false;

  /// Whether an automatic sweep may run right now.
  /// deviceStorageSyncAvailable already encodes whether this device may drain
  /// while recording, so recording alone no longer blocks a sweep — only a
  /// capture that is still claiming the transport does.
  bool _canSyncDeviceStorage() =>
      authenticated && !_deviceClaimedForCapture && deviceStorageSyncAvailable;

  /// Pulls recordings held on the connected wearable's on-board storage and
  /// ingests them through the durable import pipeline, deleting each file from
  /// the device only once its import is accepted. Idempotent and interruption
  /// safe: re-running re-imports the same content under the same import id.
  Future<void> syncDeviceStorage({bool userInitiated = false}) =>
      deviceStorageSync.requestSync(userInitiated: userInitiated);

  /// One sweep. Returns false only when the device was reachable and failed to
  /// answer — the scheduler turns that into a backoff instead of hammering a
  /// device that is out of range or busy. A sweep that had nothing to do (state
  /// changed between the eligibility check and the run) is not a failure.
  Future<bool> _runDeviceStorageSync({required bool userInitiated}) async {
    // Never drain on-device storage during a live recording: the two share the
    // wearable's BLE channel/buffer and would corrupt each other.
    if (!authenticated || isRecording) return true;
    final adapter = audioDeviceSessions.activeAdapter;
    if (adapter is! StorageSyncCapableAdapter) return true;
    final storage = (adapter as StorageSyncCapableAdapter).offlineSyncConnector;
    if (storage == null) return true;
    final deviceName = audioDeviceSessions.preferredDevice?.displayName ??
        'the device';

    // An automatic sweep stays invisible until it actually transfers something.
    // Showing a spinner on every poll would report activity, not progress.
    deviceStorageSyncing = userInitiated;
    deviceStorageSyncedCount = 0;
    deviceStoragePendingCount = 0;
    if (userInitiated) {
      deviceStorageSyncError = null;
      notifyListeners();
      ClientDiagnosticLog.instance.record(
        'device_sync',
        'sync_started',
        details: <String, Object?>{
          'device': deviceName,
          'type': audioDeviceSessions.preferredDevice?.metadata['type'],
          'trigger': 'manual',
        },
      );
    }
    var succeeded = false;
    // Follow the connector's own progress for as long as this sweep runs.
    await _syncProgressSub?.cancel();
    _syncProgressSub = storage.syncProgress.listen((progress) {
      deviceStorageSyncProgress = progress;
      deviceStoragePendingSeconds = progress.pendingSeconds;
      // Real transfer means the sweep is worth showing, even automatic ones.
      if (progress.transferred > 0) deviceStorageSyncing = true;
      notifyListeners();
    });
    try {
      // The connector owns its device protocol (file list/download/delete,
      // ring-buffer drain, or flash-page batch) and hands back complete
      // recordings; each is ingested through the durable import pipeline before
      // the connector removes it from the device.
      await storage.drainStoredAudio(
        (recording) async {
          // The first transferred recording makes an automatic sweep visible:
          // now there is real progress to report. It also tells the background
          // host to keep the CPU awake until the transfer finishes.
          deviceStorageSyncing = true;
          await _setBackgroundSyncActive(true);
          notifyListeners();
          await _ingestDeviceRecording(recording);
          deviceStorageSyncedCount += 1;
          notifyListeners();
        },
        minBytes: _deviceStorageMinBytes,
      );
      succeeded = true;
      if (deviceStorageSyncedCount > 0) {
        notice =
            '$deviceStorageSyncedCount device recording(s) synced and queued for transcription.';
        await refreshAll(silent: true);
      } else {
        // Reaching here with zero recordings means the device really was empty:
        // a connector that could not talk to its device throws instead (HeyPocket
        // raises on a failed handshake and on a sweep where every file failed),
        // so those surface through the catch below rather than as "nothing new".
        if (userInitiated) {
          // Only tell the user "nothing to sync" when they asked; the automatic
          // sweep stays quiet on an empty device.
          notice = 'No new recordings on $deviceName to sync.';
        }
      }
      if (succeeded) deviceStorageSyncError = null;
    } catch (error) {
      // Surface the failure so a silent no-op never masquerades as success.
      // Strip Dart's "Bad state:"/"Exception:" prefixes for a cleaner message.
      final message = error.toString().replaceFirst(
        RegExp(r'^(Bad state|StateError|Exception):\s*'),
        '',
      );
      // A single transient miss (device busy, a momentary link drop) between
      // unattended sweeps is not worth alarming anyone; a repeat is.
      if (userInitiated || _deviceSyncFailureIsPersistent) {
        deviceStorageSyncError = 'Sync of $deviceName failed: $message';
      }
    } finally {
      // Unattended polling must not flood the diagnostic ring: record a sweep
      // that did something, failed, or was asked for — not every quiet check.
      if (userInitiated || deviceStorageSyncedCount > 0 || !succeeded) {
        ClientDiagnosticLog.instance.record(
          'device_sync',
          'sync_finished',
          level: succeeded ? 'info' : 'warning',
          details: <String, Object?>{
            'device': deviceName,
            'synced': deviceStorageSyncedCount,
            'trigger': userInitiated ? 'manual' : 'auto',
            'error': deviceStorageSyncError,
            // Protocol-level facts from the connector, so a zero-recording sweep
            // can be told apart from a device that never answered.
            ...storage.syncDiagnostics,
          },
        );
      }
      await _syncProgressSub?.cancel();
      _syncProgressSub = null;
      deviceStorageSyncProgress = null;
      deviceStorageSyncing = false;
      await _setBackgroundSyncActive(false);
      notifyListeners();
      // The ring keeps filling while the sweep ran, so re-read what is left
      // instead of leaving the pre-sweep figure on screen.
      unawaited(refreshDeviceStoragePending());
    }
    return succeeded;
  }

  Future<void> _setBackgroundSyncActive(bool active) async {
    if (recorder is! MobileRecallRecorder) return;
    await (recorder as MobileRecallRecorder).setDeviceSyncActive(active);
  }

  /// True when the sweep that is failing right now is not the first one to fail.
  /// The scheduler counts a sweep only after it returns, so a non-zero count
  /// here means an earlier sweep already failed.
  bool get _deviceSyncFailureIsPersistent =>
      deviceStorageSync.consecutiveFailures >= 1;

  Future<void> _ingestDeviceRecording(WearableRecording recording) async {
    final contentHash = sha256.convert(recording.bytes).toString();
    final importId = _uuid.v5(
      Namespace.url.value,
      '$backendUrl:${username ?? ''}:device:$contentHash:${recording.bytes.length}',
    );
    ClientDiagnosticLog.instance.record(
      'device_import',
      'import_started',
      details: <String, Object?>{
        'importId': importId,
        'bytes': recording.bytes.length,
        'mime': recording.contentType,
        'filename': recording.filename,
        'capturedAt': recording.capturedAt?.toIso8601String(),
        'source': 'device',
      },
    );
    try {
      await api.importAudio(
        importId: importId,
        bytes: recording.bytes,
        filename: recording.filename,
        contentType: recording.contentType,
        captureTime: recording.capturedAt,
      );
      ClientDiagnosticLog.instance.record(
        'device_import',
        'import_accepted',
        details: <String, Object?>{
          'importId': importId,
          'bytes': recording.bytes.length,
        },
      );
    } catch (error) {
      ClientDiagnosticLog.instance.record(
        'device_import',
        'import_failed',
        level: 'error',
        details: <String, Object?>{
          'importId': importId,
          'error': error.toString(),
        },
      );
      rethrow;
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

  Future<void> deleteSpeaker(String id) async {
    await api.request(
      'DELETE',
      '/api/v1/speakers/$id',
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

  Future<void> _disposeExternalDeviceRuntime() async {
    await audioDeviceSessions.dispose();
    await audioDeviceRegistry.disposeAll();
  }

  @override
  void dispose() {
    _chunkSubscription?.cancel();
    _partialSubscription?.cancel();
    _warningSubscription?.cancel();
    _levelSubscription?.cancel();
    _networkSubscription?.cancel();
    _deviceStateSubscription?.cancel();
    _deviceControlSubscription?.cancel();
    _backgroundSubscription?.cancel();
    _syncProgressSub?.cancel();
    deviceStorageSync.dispose();
    sync.close();
    recorder.dispose();
    if (recorder is! MobileRecallRecorder) {
      unawaited(_disposeExternalDeviceRuntime());
    }
    super.dispose();
  }
}
