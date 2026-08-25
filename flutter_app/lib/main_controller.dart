import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'src/api_client.dart';
import 'src/auth/webauthn_client.dart';
import 'src/background/background_capture_service.dart';
import 'src/capture/capture_pipeline.dart';
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
import 'src/recording/recording_schedule.dart';
import 'src/sync/chunk_store.dart';
import 'src/sync/pending_audio_preview.dart';
import 'src/sync/processing_status.dart';
import 'src/sync/storage_capacity_error.dart';
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
    'uploadOnlyOnUnmetered': true,
    'recordingScheduleEnabled': false,
    'recordingStartMinute': 0,
    'recordingEndMinute': 0,
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
  final WebAuthnClient _webAuthn = createWebAuthnClient();
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
  StreamSubscription<NetworkState>? _networkSubscription;
  StreamSubscription<dynamic>? _deviceStateSubscription;
  StreamSubscription<DeviceControlEvent>? _deviceControlSubscription;
  StreamSubscription<BackgroundCaptureEvent>? _backgroundSubscription;
  StreamSubscription<CapturePipelineInterruption>?
  _mobileInterruptionSubscription;
  SharedPreferences? _preferences;
  bool initialized = false;
  bool loading = false;
  bool online = true;
  bool consentAccepted = false;
  bool _stoppingRecording = false;
  bool _resumingMobileCapture = false;
  bool _switchingMobileSource = false;
  Future<bool>? _widgetPhoneRecordingOperation;
  Future<void> _watchImport = Future<void>.value();
  Timer? _mobileCaptureRecoveryTimer;
  Timer? _recordingScheduleTimer;
  int _mobileCaptureRecoveryAttempts = 0;
  Map<String, dynamic> _cachedSettings = Map<String, dynamic>.from(
    _fallbackSettings,
  );
  bool cachedData = false;
  bool autostartEnabled = false;
  bool preferBluetoothCapture = true;
  String? preferredDeviceLabel;
  // Latest battery percentage reported by the connected wearable, if any.
  // Cleared whenever the link drops or a different device is preferred, since
  // a stale reading would otherwise linger in the UI.
  int? preferredDeviceBatteryLevel;
  String? error;
  String? _notice;
  Timer? _noticeTimer;
  bool _liveStatusScheduled = false;
  bool _storageExhausted = false;
  static const Duration _noticeLifetime = Duration(seconds: 5);

  @override
  void notifyListeners() {
    super.notifyListeners();
    _scheduleLiveStatusUpdate();
  }

  void _scheduleLiveStatusUpdate() {
    if (!isMobileCapturePlatform || recorder is! MobileRecallRecorder) return;
    if (_liveStatusScheduled) return;
    _liveStatusScheduled = true;
    scheduleMicrotask(() {
      _liveStatusScheduled = false;
      unawaited(_pushLiveStatus());
    });
  }

  Future<void> _pushLiveStatus() async {
    if (recorder is! MobileRecallRecorder) return;
    final mobile = recorder as MobileRecallRecorder;
    await mobile.background.updateLiveStatus(_buildLiveStatus(mobile));
  }

  BackgroundLiveStatus _buildLiveStatus(MobileRecallRecorder mobile) {
    final processing = processingStatus;
    final issue = processing.issues.isEmpty
        ? null
        : processing.issues.first.message;
    final etaSeconds = processing.eta?.inSeconds;
    final facts = <String>[
      if (processing.pendingBytes > 0) _compactBytes(processing.pendingBytes),
      if (processing.totalAudioDuration > Duration.zero)
        _compactDuration(processing.totalAudioDuration),
      if (etaSeconds != null && etaSeconds > 0)
        'about ${_compactDuration(processing.eta!)} left',
    ];
    String detail(String fallback) =>
        facts.isEmpty ? fallback : '$fallback · ${facts.join(' · ')}';

    if (_storageExhausted) {
      return BackgroundLiveStatus(
        phase: BackgroundLivePhase.storageFull,
        title: 'Storage full — recording stopped',
        detail: 'Free device storage, then reopen NeoRecall to resume safely.',
        pendingBytes: processing.pendingBytes,
        pendingAudioSeconds: processing.totalAudioDuration.inSeconds,
        issue: 'No local space remains for another durable audio block.',
      );
    }
    if (isRecording) {
      final source = capability?.sourceKind == 'wearable'
          ? preferredDeviceLabel ?? 'Bluetooth device'
          : 'Phone microphone';
      return BackgroundLiveStatus(
        phase: BackgroundLivePhase.recording,
        title: 'Recording from $source',
        detail: detail(
          processing.uploading > 0
              ? 'Recording safely · uploading in background'
              : 'Recording safely to this device',
        ),
        recordingStartedAt: recordingStartedAt,
        pendingBytes: processing.pendingBytes,
        pendingAudioSeconds: processing.totalAudioDuration.inSeconds,
        etaSeconds: etaSeconds,
        issue: issue,
      );
    }

    final (phase, title, fallback) = switch (processing.activeStage) {
      ProcessingPipelineStage.watchTransfer => (
        BackgroundLivePhase.watchTransfer,
        'Downloading from watch',
        'Audio is moving into protected phone storage',
      ),
      ProcessingPipelineStage.upload => (
        BackgroundLivePhase.uploading,
        'Uploading recordings',
        'Local originals stay protected until processing is verified',
      ),
      ProcessingPipelineStage.transcription => (
        BackgroundLivePhase.transcribing,
        'Transcribing on server',
        'Audio is safely stored while the transcript is created',
      ),
      ProcessingPipelineStage.finalizing => (
        BackgroundLivePhase.finalizing,
        'Finalizing transcript',
        'Waiting for verified persistence and server audio deletion',
      ),
      ProcessingPipelineStage.phoneQueue ||
      ProcessingPipelineStage.serverQueue => (
        BackgroundLivePhase.queued,
        'Recordings safely queued',
        issue ?? 'Waiting for the next processing step',
      ),
      ProcessingPipelineStage.complete =>
        mobile.background.active.isNotEmpty
            ? (
                BackgroundLivePhase.connected,
                'NeoRecall stays connected',
                mobile.background.active.statusDetail,
              )
            : (
                BackgroundLivePhase.idle,
                'NeoRecall is ready',
                'No recording or processing is active',
              ),
    };
    return BackgroundLiveStatus(
      phase: phase,
      title: title,
      detail: detail(fallback),
      progress: processing.watchFraction,
      pendingBytes: processing.pendingBytes,
      pendingAudioSeconds: processing.totalAudioDuration.inSeconds,
      etaSeconds: etaSeconds,
      issue: issue,
    );
  }

  static String _compactBytes(int bytes) {
    if (bytes < 1024) return '$bytes B queued';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB queued';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB queued';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB queued';
  }

  static String _compactDuration(Duration value) {
    if (value.inHours > 0) {
      final minutes = value.inMinutes.remainder(60);
      return minutes == 0
          ? '${value.inHours}h'
          : '${value.inHours}h ${minutes}m';
    }
    if (value.inMinutes > 0) return '${value.inMinutes}m';
    return '${value.inSeconds.clamp(1, 59)}s';
  }

  String? get notice => _notice;
  set notice(String? value) {
    _noticeTimer?.cancel();
    _notice = value;
    if (value == null) return;
    _noticeTimer = Timer(_noticeLifetime, () {
      if (_notice != value) return;
      _notice = null;
      notifyListeners();
    });
  }

  String? accountId;
  String? username;
  String? warning;
  bool isConfiguringTwoFactor = false;
  Map<String, dynamic> accountTwoFactor = const <String, dynamic>{};
  List<Map<String, dynamic>> securityKeys = const <Map<String, dynamic>>[];
  RecallPage page = RecallPage.record;
  List<RecordingSession> recordings = <RecordingSession>[];
  List<TranscriptSegment> transcript = <TranscriptSegment>[];
  /// Where the transcript page ended, so older segments can be pulled in on
  /// demand. The timeline shows the most recent recordings first; without a way
  /// to reach further back, a long history would simply stop at the page edge.
  String? _transcriptCursor;
  bool isLoadingOlderTranscript = false;
  bool get hasOlderTranscript => _transcriptCursor != null;
  List<RecallMemory> memories = <RecallMemory>[];
  List<MiniMemory> miniMemories = <MiniMemory>[];
  List<RecallSpeaker> speakers = <RecallSpeaker>[];
  List<Map<String, dynamic>> devices = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[];
  /// Why the timeline looks the way it does. Empty means nothing is wrong; an
  /// entry means something is holding recordings up and the user should be told
  /// rather than left staring at a screen that says there is nothing here.
  List<Map<String, dynamic>> processingIssues = <Map<String, dynamic>>[];
  String processingSummary = '';
  int audioStillOnDevice = 0;
  List<Map<String, dynamic>> dailySummaries = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> searchResults = <Map<String, dynamic>>[];
  String? askAnswer;
  List<Map<String, dynamic>> askCitations = <Map<String, dynamic>>[];
  int pendingAudioBytes = 0;
  // Recording sessions containing a chunk parked after repeated server-side
  // permanent failures; surfaced without exposing transport chunk counts.
  int needsAttentionCount = 0;
  // Recording sessions with a transiently failing chunk; still auto-retried.
  int failedUploadCount = 0;
  ProcessingStatusSnapshot processingLedgerStatus =
      const ProcessingStatusSnapshot();
  int _watchImportingCount = 0;
  int _watchDownloadingCount = 0;
  String? _watchTransferError;

  ProcessingStatusSnapshot get processingStatus {
    final progress = deviceStorageSyncProgress;
    final remainingTransferUnits = progress == null
        ? 0
        : (progress.total - progress.transferred)
              .clamp(0, progress.total)
              .toInt();
    final transferIssues = <ProcessingIssue>[
      ...processingLedgerStatus.issues,
      if (deviceStorageSyncError?.trim().isNotEmpty == true)
        ProcessingIssue(message: deviceStorageSyncError!),
      if (_watchTransferError?.trim().isNotEmpty == true)
        ProcessingIssue(message: _watchTransferError!),
    ];
    final nativeWatchPending = _watchDownloadingCount > _watchImportingCount
        ? _watchDownloadingCount
        : _watchImportingCount;
    return processingLedgerStatus.copyWithTransfer(
      active:
          deviceStorageSyncing ||
          _watchDownloadingCount > 0 ||
          _watchImportingCount > 0,
      pending: nativeWatchPending + remainingTransferUnits,
      pendingSeconds: deviceStoragePendingSeconds,
      transferred: progress?.transferred ?? 0,
      total: progress?.total ?? 0,
      issues: transferIssues,
    );
  }

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
  bool _pendingSecurityKeyLogin = false;
  bool _securityKeyDismissed = false;
  bool _initializing = false;
  bool _syncInitialized = false;
  bool _deviceRuntimeInitialized = false;
  bool _runtimeSubscriptionsReady = false;
  String? initializationError;

  static const Duration _mobileCaptureRecoveryInitialDelay = Duration(
    seconds: 2,
  );
  static const Duration _mobileCaptureRecoveryMaximumDelay = Duration(
    minutes: 2,
  );

  bool get authenticated => api.token != null && accountId != null;
  bool get isRecording => recorder.isRecording;

  RecordingSchedule get _recordingSchedule => RecordingSchedule(
    enabled: _cachedSettings['recordingScheduleEnabled'] as bool? ?? false,
    startMinute:
        _cachedSettings['recordingStartMinute'] as int? ??
        _fallbackSettings['recordingStartMinute']! as int,
    endMinute:
        _cachedSettings['recordingEndMinute'] as int? ??
        _fallbackSettings['recordingEndMinute']! as int,
  );

  Future<bool> _uploadsAllowed() async {
    if (!(_cachedSettings['uploadOnlyOnUnmetered'] as bool? ?? true)) {
      return true;
    }
    final state = await currentNetworkState();
    return state.connected && state.unmetered;
  }

  String _settingsCacheKey(String ownerAccountId) =>
      'userSettings:$ownerAccountId';

  Future<void> _loadCachedSettings(String? ownerAccountId) async {
    _cachedSettings = Map<String, dynamic>.from(_fallbackSettings);
    if (ownerAccountId == null || _preferences == null) return;
    final encoded = _preferences!.getString(_settingsCacheKey(ownerAccountId));
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) {
        _cachedSettings.addAll(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupt preferences must not block capture; server defaults remain.
    }
  }

  Future<void> _cacheSettings(Map<String, dynamic> value) async {
    _cachedSettings = <String, dynamic>{..._fallbackSettings, ...value};
    final ownerAccountId = accountId;
    if (ownerAccountId != null && _preferences != null) {
      await _preferences!.setString(
        _settingsCacheKey(ownerAccountId),
        jsonEncode(_cachedSettings),
      );
    }
  }

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
      await _loadCachedSettings(accountId);
      sync.pump.uploadAllowed = _uploadsAllowed;
      sync.pump.onUploadActivity = _setBackgroundUploadActive;
      sync.pump.onTerminalReceipt = _forwardWatchTerminalReceipt;
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
          await api.discoverServerCapabilities();
          await _loadCachedSettings(accountId);
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
          _mobileInterruptionSubscription = mobile.interruptions.listen(
            (event) => unawaited(_recoverInterruptedMobileCapture(event)),
          );
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
              case BackgroundCaptureEventType.phoneRecordingRequested:
                unawaited(_startPhoneRecordingFromWidget());
              case BackgroundCaptureEventType.watchTransferStarted:
                _watchDownloadingCount += 1;
                _watchTransferError = null;
                notifyListeners();
              case BackgroundCaptureEventType.watchTransferFinished:
                _watchDownloadingCount = (_watchDownloadingCount - 1)
                    .clamp(0, _watchDownloadingCount)
                    .toInt();
                if (event.message?.trim().isNotEmpty == true) {
                  _watchTransferError =
                      'Watch download failed: ${event.message!.trim()}';
                }
                notifyListeners();
              case BackgroundCaptureEventType.watchRecordingAvailable:
                _queueWatchImport(mobile.background);
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
      if (authenticated) {
        await _settings();
        sync.pump.pump();
        await refreshAll(silent: true);
      }
      if (_supportsDurableMobileResume) {
        // A widget tap is persisted natively before the Activity launches, so
        // claiming it here also covers a cold Flutter engine whose event was
        // emitted before this subscription existed.
        unawaited(_resumeMobileCaptureAfterWidgetCheck());
      }
      if (recorder is MobileRecallRecorder) {
        _queueWatchImport((recorder as MobileRecallRecorder).background);
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
        _storageExhausted = isStorageCapacityError(exception);
        warning = _storageExhausted
            ? 'Device storage is full. Recording stopped; all previously queued audio remains protected.'
            : 'Local audio could not be stored. Recording is stopping without deleting queued audio.';
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
        _storageExhausted = isStorageCapacityError(exception);
        warning = _storageExhausted
            ? 'Device storage is full. Recording stopped; all previously queued audio remains protected.'
            : 'The active audio block could not be written to durable storage.';
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
    _networkSubscription = networkAvailability().listen((state) {
      online = state.connected;
      if (state.connected) sync.pump.pump();
      unawaited(_refreshPending());
      notifyListeners();
    });
  }

  void _queueWatchImport(BackgroundCaptureService background) {
    _watchImport = _watchImport
        .then((_) => _importPendingWatchRecordings(background))
        .catchError((Object exception) {
          debugPrint('Wear OS inbox import deferred: $exception');
        });
  }

  Future<void> _importPendingWatchRecordings(
    BackgroundCaptureService background,
  ) async {
    final owner = accountId;
    if (owner == null) return;
    // Drain in bounded native batches. Each row is claimed only after both the
    // session declaration and audio are durable in ChunkStore.
    try {
      while (true) {
        final recordings = await background.takePendingWatchRecordings();
        if (recordings.isEmpty) break;
        _watchImportingCount = recordings.length;
        notifyListeners();
        for (final row in recordings) {
          final recordingId = row['recordingId'] as String;
          final sessionId = row['sessionId'] as String;
          final sourceId = row['sourceId'] as String;
          final watchDeviceId = row['watchDeviceId'] as String;
          final watchName = row['watchName'] as String;
          final sequence = (row['sequence'] as num).toInt();
          final sessionStartedAt = DateTime.fromMillisecondsSinceEpoch(
            (row['sessionStartedAtMs'] as num).toInt(),
            isUtc: true,
          );
          final startedAt = DateTime.fromMillisecondsSinceEpoch(
            (row['startedAtMs'] as num).toInt(),
            isUtc: true,
          );
          final durationMs = (row['durationMs'] as num).toInt();
          final isFinal = row['isFinal'] as bool;
          final digest = row['sha256'] as String;
          final bytes = row['bytes'];
          if (bytes is! Uint8List) {
            throw const FormatException('Wear OS audio payload is not binary.');
          }
          await store.putSession(
            LocalRecordingDeclaration(
              id: sessionId,
              accountId: owner,
              sourceId: sourceId,
              deviceId: watchDeviceId,
              deviceClientUuid: watchDeviceId,
              deviceName: watchName,
              platform: 'wearos',
              startedAt: sessionStartedAt,
              timezone: _cachedSettings['timezone'] as String? ?? 'UTC',
              // Pressing Start on the watch is the user's direct attestation.
              consentAttestedAt: sessionStartedAt,
              sourceKind: 'microphone',
              channelLayout: 'mono',
              sampleRate: (row['sampleRate'] as num).toInt(),
              endedAt: isFinal
                  ? startedAt.add(Duration(milliseconds: durationMs))
                  : null,
              finalSequence: isFinal ? sequence : null,
            ),
          );
          final alreadyStored = await store.hasMatchingChunk(
            recordingId,
            digest,
          );
          if (!alreadyStored) {
            await store.put(
              AudioChunk(
                id: recordingId,
                sessionId: sessionId,
                sourceId: sourceId,
                sequence: sequence,
                startedAt: startedAt,
                monotonicOffsetMs: (row['monotonicOffsetMs'] as num).toInt(),
                durationMs: durationMs,
                overlapMs: 0,
                channelLayout: 'mono',
                container: row['container'] as String,
                codec: row['codec'] as String,
                sha256: digest,
                state: LocalChunkState.ready,
                createdAt: DateTime.now().toUtc(),
                isFinal: isFinal,
              ),
              bytes,
            );
          }
          await background.markWatchRecordingImported(recordingId);
          _watchImportingCount = (_watchImportingCount - 1)
              .clamp(0, recordings.length)
              .toInt();
          notifyListeners();
        }
        await _refreshPending();
        sync.pump.pump();
        if (recordings.length < 20) break;
      }
    } finally {
      _watchImportingCount = 0;
      notifyListeners();
    }
  }

  Future<bool> _forwardWatchTerminalReceipt(
    AudioChunk chunk,
    Map<String, dynamic> receipt,
  ) async {
    if (recorder is! MobileRecallRecorder) return true;
    return (recorder as MobileRecallRecorder).background
        .acknowledgeWatchRecording(chunk.id, receipt);
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
        _pendingSecurityKeyLogin = false;
      },
    );
  }

  bool get supportsSecurityKeys => _webAuthn.isSupported;

  /// Signs in with a security key. A key that verifies the user with a PIN or a
  /// fingerprint covers the second factor too, so no code is asked for; a
  /// presence-only key falls back to the two-factor step.
  Future<bool> signInWithSecurityKey({
    String? account,
    String? twoFactorCode,
  }) async {
    final signedIn = await _run(
      () async {
        final start =
            await api.request(
                  'POST',
                  '/api/v1/auth/webauthn/options',
                  body: <String, dynamic>{'account': ?account},
                )
                as Map;
        final assertion = await _webAuthn.getAssertion(
          Map<String, dynamic>.from(start['options'] as Map),
        );
        final payload =
            await api.request(
                  'POST',
                  '/api/v1/auth/webauthn/verify',
                  body: <String, dynamic>{
                    'challengeId': start['challengeId'],
                    'response': assertion,
                    'twoFactorCode': ?twoFactorCode,
                  },
                )
                as Map;
        await _acceptSession(payload);
        _pendingAccount = null;
        _pendingSecurityKeyLogin = false;
        await refreshAll(silent: true);
      },
      onTwoFactor: () {
        _pendingAccount = account;
        _pendingPassword = null;
        _pendingSecurityKeyLogin = true;
      },
    );
    // Dismissing the browser prompt is a deliberate choice, not a failure worth
    // reporting back on the sign-in card.
    if (!signedIn && _securityKeyDismissed) {
      _securityKeyDismissed = false;
      error = null;
      notifyListeners();
    }
    return signedIn;
  }

  Future<void> fetchSecurityKeys() async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response =
          await api.request('GET', '/api/v1/settings/security-keys') as Map;
      securityKeys = _securityKeyList(response);
    } catch (_) {
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<bool> registerSecurityKey(String label) async {
    final registered = await _run(() async {
      final start =
          await api.request('POST', '/api/v1/settings/security-keys/options')
              as Map;
      final attestation = await _webAuthn.createCredential(
        Map<String, dynamic>.from(start['options'] as Map),
      );
      final response =
          await api.request(
                'POST',
                '/api/v1/settings/security-keys',
                body: <String, dynamic>{
                  'challengeId': start['challengeId'],
                  'response': attestation,
                  'label': label,
                },
              )
              as Map;
      securityKeys = _securityKeyList(response);
      notice = 'Security key added.';
    });
    if (!registered && _securityKeyDismissed) {
      _securityKeyDismissed = false;
      error = null;
      notifyListeners();
    }
    return registered;
  }

  Future<bool> renameSecurityKey(String id, String label) => _run(() async {
    final response =
        await api.request(
              'PUT',
              '/api/v1/settings/security-keys/$id',
              body: <String, dynamic>{'label': label},
            )
            as Map;
    securityKeys = _securityKeyList(response);
  });

  Future<bool> removeSecurityKey(String id) => _run(() async {
    final response =
        await api.request('DELETE', '/api/v1/settings/security-keys/$id')
            as Map;
    securityKeys = _securityKeyList(response);
  });

  List<Map<String, dynamic>> _securityKeyList(Map response) {
    final rows = response['credentials'];
    if (rows is! List) return const <Map<String, dynamic>>[];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<bool> completeTwoFactor(String code) => _pendingSecurityKeyLogin
      ? signInWithSecurityKey(account: _pendingAccount, twoFactorCode: code)
      : login(
          _pendingAccount ?? '',
          _pendingPassword ?? '',
          twoFactorCode: code,
        );
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
    await api.discoverServerCapabilities();
    await _loadCachedSettings(accountId);
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
    await _settings();
    sync.pump.start();
    await _refreshPending();
    if (recorder is MobileRecallRecorder) {
      _queueWatchImport((recorder as MobileRecallRecorder).background);
    }
  }

  Future<void> logout() async {
    final signingOutAccountId = accountId;
    _cancelMobileCaptureRecovery();
    _recordingScheduleTimer?.cancel();
    _recordingScheduleTimer = null;
    if (isRecording) await stopRecording();
    if (_supportsDurableMobileResume && signingOutAccountId != null) {
      await _preferences?.remove(_mobileCaptureIntentKey(signingOutAccountId));
    }
    await audioDeviceSessions.bindAccount(null);
    await ClientDiagnosticLog.instance.bindAccount(null);
    preferredDeviceLabel = null;
    preferredDeviceBatteryLevel = null;
    try {
      await api.request('POST', '/api/v1/auth/logout');
    } catch (_) {}
    _stopForegroundRefresh();
    sync.pump.accountId = null;
    api.token = null;
    accountId = null;
    username = null;
    _cachedSettings = Map<String, dynamic>.from(_fallbackSettings);
    pendingAudioBytes = 0;
    needsAttentionCount = 0;
    failedUploadCount = 0;
    processingLedgerStatus = const ProcessingStatusSnapshot();
    await _secureStorage.delete(key: 'sessionToken');
    await _preferences?.remove('accountId');
    await _preferences?.remove('username');
    accountTwoFactor = const <String, dynamic>{};
    securityKeys = const <Map<String, dynamic>>[];
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
      final response = await api.request(
        'POST',
        '/api/v1/settings/2fa/enable',
        body: {'code': code},
      );
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

  Future<void> disableTwoFactor({
    required String password,
    String? code,
  }) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      await api.request(
        'DELETE',
        '/api/v1/settings/2fa',
        body: {'password': password, 'code': ?code},
      );
      await fetchTwoFactorStatus();
    } catch (e) {
      error = e.toString();
    } finally {
      isConfiguringTwoFactor = false;
      notifyListeners();
    }
  }

  Future<List<String>> regenerateTwoFactorCodes({
    required String password,
    required String code,
  }) async {
    isConfiguringTwoFactor = true;
    notifyListeners();
    try {
      final response = await api.request(
        'POST',
        '/api/v1/settings/2fa/recovery-codes',
        body: {'password': password, 'code': code},
      );
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
    } on WebAuthnException catch (exception) {
      _securityKeyDismissed = exception.cancelled;
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
    // The freshly connected device hasn't pushed a battery reading yet.
    preferredDeviceBatteryLevel = null;
    notifyListeners();
  }

  Future<void> clearPreferredBluetoothDevice() async {
    await audioDeviceSessions.clearPreferred();
    preferredDeviceLabel = null;
    preferredDeviceBatteryLevel = null;
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
      final schedule = RecordingSchedule(
        enabled: settings['recordingScheduleEnabled'] as bool? ?? false,
        startMinute: settings['recordingStartMinute'] as int? ?? 0,
        endMinute: settings['recordingEndMinute'] as int? ?? 0,
      );
      if (!schedule.allows(DateTime.now())) {
        _armRecordingSchedule();
        throw StateError(
          'Recording is outside the configured daily recording window.',
        );
      }
      final recordingAccountId = accountId;
      if (recordingAccountId == null) {
        throw StateError('Sign in before starting a recording.');
      }
      final identity = await _deviceIdentity(recordingAccountId);
      final deviceId = identity.id;
      final clientUuid = identity.clientUuid;
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
      _armRecordingSchedule();
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
      if (recorder is MobileRecallRecorder && !_switchingMobileSource) {
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
    if (_storageExhausted) _storageExhausted = false;
    _sequence = sequence + 1;
    // Opening the audio API is not enough to prove recovery. A full scheduled
    // chunk durably stored on disk is; a short final tail from another failure
    // must not reset exponential retry delay.
    if (!recorded.isFinal) _mobileCaptureRecoveryAttempts = 0;
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
    if (_storageExhausted) _storageExhausted = false;
    await _refreshPending();
  }

  Future<void> stopRecording({
    bool interrupted = false,
    bool preserveMobileIntent = false,
  }) async {
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
          interrupted: interrupted,
          synced: false,
        );
        await store.putSession(_activeSession!);
      }
      final stoppingAccountId = session?.accountId ?? accountId;
      if (_supportsDurableMobileResume &&
          stoppingAccountId != null &&
          !_switchingMobileSource &&
          !preserveMobileIntent) {
        await _preferences!.remove(_mobileCaptureIntentKey(stoppingAccountId));
      }
      _activeSession = null;
      recordingStartedAt = null;
      audioLevel = 0;
      // The background battery warning is only meaningful during active capture.
      backgroundCaptureAtRisk = false;
      sync.pump.pump();
      if (recorder is MobileRecallRecorder && !_switchingMobileSource) {
        await (recorder as MobileRecallRecorder).finishBackgroundHost();
      }
      _armRecordingSchedule();
      notifyListeners();
    } finally {
      _stoppingRecording = false;
    }
  }

  void _applyRecordingSchedule() {
    final schedule = _recordingSchedule;
    if (isRecording && !schedule.allows(DateTime.now())) {
      unawaited(_pauseRecordingForSchedule());
      return;
    }
    _armRecordingSchedule();
  }

  void _armRecordingSchedule() {
    _recordingScheduleTimer?.cancel();
    _recordingScheduleTimer = null;
    final schedule = _recordingSchedule;
    if (!schedule.enabled || schedule.startMinute == schedule.endMinute) return;
    final now = DateTime.now();
    final boundary = schedule.nextBoundary(now);
    final delay = boundary.difference(now);
    _recordingScheduleTimer = Timer(delay, () {
      _recordingScheduleTimer = null;
      if (_recordingSchedule.allows(DateTime.now())) {
        unawaited(_resumeMobileCaptureIfRequested());
      } else if (isRecording) {
        unawaited(_pauseRecordingForSchedule());
      } else {
        _armRecordingSchedule();
      }
    });
  }

  Future<void> _pauseRecordingForSchedule() async {
    if (!isRecording || _recordingSchedule.allows(DateTime.now())) {
      _armRecordingSchedule();
      return;
    }
    await stopRecording(preserveMobileIntent: _supportsDurableMobileResume);
    warning =
        'Recording paused at the end of its daily window. Android may require '
        'NeoRecall to be opened before phone-microphone recording resumes.';
    notifyListeners();
  }

  String _mobileCaptureIntentKey(String ownerAccountId) =>
      'mobileCaptureIntent:$ownerAccountId';

  Future<void> _resumeMobileCaptureAfterWidgetCheck() async {
    if (!await _startPhoneRecordingFromWidget()) {
      await _resumeMobileCaptureIfRequested();
    }
  }

  Future<bool> _startPhoneRecordingFromWidget() {
    final current = _widgetPhoneRecordingOperation;
    if (current != null) return current;
    final operation = _consumeWidgetPhoneRecordingRequest();
    _widgetPhoneRecordingOperation = operation;
    return operation.whenComplete(() {
      if (identical(_widgetPhoneRecordingOperation, operation)) {
        _widgetPhoneRecordingOperation = null;
      }
    });
  }

  Future<bool> _consumeWidgetPhoneRecordingRequest() async {
    if (recorder is! MobileRecallRecorder) return false;
    final mobile = recorder as MobileRecallRecorder;
    if (!await mobile.background.takePendingWidgetPhoneRecordingRequest()) {
      return false;
    }
    final wasAlreadyRecording = isRecording;
    try {
      if (!authenticated) {
        warning =
            'Sign in before starting recording from the home-screen widget.';
        notifyListeners();
        return true;
      }
      if (!consentAccepted) {
        warning =
            'Accept the recording consent notice before using the home-screen widget.';
        notifyListeners();
        return true;
      }

      await setPreferBluetoothCapture(false);
      if (isRecording) {
        if (capability?.sourceKind != 'microphone') {
          await _restartMobileCapture(useBluetooth: false);
        }
      } else {
        await startRecording(
          microphone: true,
          systemAudio: false,
          bluetooth: false,
        );
      }
      notice = 'Phone recording started from the home-screen widget.';
      ClientDiagnosticLog.instance.record(
        'widget_capture',
        'phone_recording_started',
        details: <String, Object?>{'alreadyRecording': wasAlreadyRecording},
      );
      notifyListeners();
      return true;
    } catch (exception) {
      warning = 'The home-screen widget could not start recording: $exception';
      ClientDiagnosticLog.instance.record(
        'widget_capture',
        'phone_recording_failed',
        level: 'warning',
        details: <String, Object?>{'error': exception.toString()},
      );
      notifyListeners();
      return true;
    }
  }

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
    if (isRecording ||
        _stoppingRecording ||
        _resumingMobileCapture ||
        _switchingMobileSource) {
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
      await startRecording(
        microphone: false,
        systemAudio: false,
        bluetooth: true,
      );
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
    if (!_recordingSchedule.allows(DateTime.now())) {
      warning = 'Recording is waiting for the next configured daily window.';
      _armRecordingSchedule();
      notifyListeners();
      return;
    }
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
        final level = event.payload['level'];
        if (level is int && level >= 0) {
          preferredDeviceBatteryLevel = level.clamp(0, 100);
          notifyListeners();
        }
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
      preferredDeviceBatteryLevel = null;
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
      _scheduleMobileCaptureRecovery(
        useBluetooth: useBluetooth,
        reason: exception.toString(),
      );
    } finally {
      if (_mobileCaptureRecoveryTimer == null) {
        _switchingMobileSource = false;
      }
    }
  }

  Future<void> _recoverInterruptedMobileCapture(
    CapturePipelineInterruption interruption,
  ) async {
    if (_switchingMobileSource || _stoppingRecording || !isRecording) return;
    final useBluetooth = capability?.sourceKind == 'wearable';
    _switchingMobileSource = true;
    try {
      // Finalize the already-buffered tail before retrying. While switching,
      // stopRecording deliberately preserves both the durable capture intent
      // and the foreground-service hold across the retry delay.
      await stopRecording(interrupted: true);
      _scheduleMobileCaptureRecovery(
        useBluetooth: useBluetooth,
        reason: interruption.reason,
      );
    } catch (exception) {
      _switchingMobileSource = false;
      warning =
          'Interrupted recording could not be finalized safely: $exception';
      notifyListeners();
    }
  }

  void _scheduleMobileCaptureRecovery({
    required bool useBluetooth,
    required String reason,
  }) {
    _mobileCaptureRecoveryTimer?.cancel();
    final mobile = recorder is MobileRecallRecorder
        ? recorder as MobileRecallRecorder
        : null;
    if (!authenticated ||
        !consentAccepted ||
        mobile == null ||
        mobile.backgroundPaused) {
      _switchingMobileSource = false;
      return;
    }
    final ownerAccountId = accountId!;
    final intent = _preferences?.getString(
      _mobileCaptureIntentKey(ownerAccountId),
    );
    if (intent == null) {
      _switchingMobileSource = false;
      return;
    }

    var delayMs = _mobileCaptureRecoveryInitialDelay.inMilliseconds;
    for (
      var step = 0;
      step < _mobileCaptureRecoveryAttempts &&
          delayMs < _mobileCaptureRecoveryMaximumDelay.inMilliseconds;
      step += 1
    ) {
      delayMs = (delayMs * 2).clamp(
        _mobileCaptureRecoveryInitialDelay.inMilliseconds,
        _mobileCaptureRecoveryMaximumDelay.inMilliseconds,
      );
    }
    _mobileCaptureRecoveryAttempts += 1;
    final delay = Duration(milliseconds: delayMs);
    warning =
        'Audio capture was interrupted ($reason). The durable tail was saved; '
        'capture will retry in ${delay.inSeconds} seconds.';
    notifyListeners();
    _mobileCaptureRecoveryTimer = Timer(delay, () async {
      _mobileCaptureRecoveryTimer = null;
      if (!authenticated ||
          accountId != ownerAccountId ||
          mobile.backgroundPaused) {
        _switchingMobileSource = false;
        return;
      }
      try {
        await startRecording(
          microphone: !useBluetooth,
          systemAudio: false,
          bluetooth: useBluetooth,
        );
        _switchingMobileSource = false;
        notice = 'Audio capture recovered after an interruption.';
        notifyListeners();
      } catch (exception) {
        _scheduleMobileCaptureRecovery(
          useBluetooth: useBluetooth,
          reason: exception.toString(),
        );
      }
    });
  }

  void _cancelMobileCaptureRecovery() {
    _mobileCaptureRecoveryTimer?.cancel();
    _mobileCaptureRecoveryTimer = null;
    _mobileCaptureRecoveryAttempts = 0;
    _switchingMobileSource = false;
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
      return Map<String, dynamic>.from(_cachedSettings);
    }
    try {
      final payload = await api.request('GET', '/api/v1/settings') as Map;
      final value = Map<String, dynamic>.from(payload['settings'] as Map);
      await _cacheSettings(value);
      return Map<String, dynamic>.from(_cachedSettings);
    } catch (_) {
      return Map<String, dynamic>.from(_cachedSettings);
    }
  }

  Future<void> _refreshPending() async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null) {
      pendingAudioBytes = 0;
      needsAttentionCount = 0;
      failedUploadCount = 0;
      processingLedgerStatus = const ProcessingStatusSnapshot();
      notifyListeners();
      return;
    }
    pendingAudioBytes = await store.pendingBytes(ownerAccountId);
    try {
      final chunks = await store.pending(ownerAccountId, limit: 2000);
      needsAttentionCount = chunks
          .where((chunk) => chunk.state == LocalChunkState.needsAttention)
          .map((chunk) => chunk.sessionId)
          .toSet()
          .length;
      failedUploadCount = chunks
          .where((chunk) => chunk.state == LocalChunkState.failed)
          .map((chunk) => chunk.sessionId)
          .toSet()
          .length;
      final byteCounts = await Future.wait(chunks.map(store.storedBytes));
      var localUploadBytes = 0;
      for (var index = 0; index < chunks.length; index += 1) {
        if (<LocalChunkState>{
          LocalChunkState.ready,
          LocalChunkState.uploading,
          LocalChunkState.failed,
        }.contains(chunks[index].state)) {
          localUploadBytes += byteCounts[index];
        }
      }
      var connected = online;
      var unmetered = true;
      try {
        final network = await currentNetworkState();
        connected = network.connected;
        unmetered = network.unmetered;
      } catch (_) {
        // The status remains conservative when Android cannot classify the
        // active network: upload policy still performs its own authoritative check.
      }
      processingLedgerStatus = ProcessingStatusSnapshot.fromChunks(
        chunks: chunks,
        pendingBytes: pendingAudioBytes,
        localUploadBytes: localUploadBytes,
        uploadEta: sync.pump.estimateUploadDuration(localUploadBytes),
        offline: !connected,
        unmeteredOnly:
            (_cachedSettings['uploadOnlyOnUnmetered'] as bool? ?? true) &&
            !sync.pump.meteredUploadOverrideActive,
        networkUnmetered: unmetered,
        deviceIssue: sync.pump.processingIssue,
      );
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
      await sync.pump.retry(chunk);
    }
    await _refreshPending();
    sync.pump.pump();
  }

  /// Drains only the uploadable audio that is queued at the moment of the
  /// request over the current metered network. The saved Wi-Fi-only preference
  /// remains unchanged, so later recordings continue to wait for Wi-Fi.
  Future<void> uploadQueuedAudioOnMobileDataOnce() async {
    final ownerAccountId = accountId;
    final recordingCount = ownerAccountId == null
        ? 0
        : (await store.pending(ownerAccountId, limit: 2000))
              .where(
                (chunk) => <LocalChunkState>{
                  LocalChunkState.ready,
                  LocalChunkState.uploading,
                  LocalChunkState.failed,
                }.contains(chunk.state),
              )
              .map((chunk) => chunk.sessionId)
              .toSet()
              .length;
    final chunkCount = await sync.pump.uploadQueuedAudioOnMeteredOnce();
    notice = chunkCount == 0
        ? 'There is no queued audio ready to upload.'
        : 'Uploading $recordingCount queued recording${recordingCount == 1 ? '' : 's'} using mobile data.';
    await _refreshPending();
    notifyListeners();
  }

  static const int _pendingAudioReviewPartLimit = 2000;

  Future<List<PendingAudioRecording>> loadPendingAudioRecordings() async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null) return const <PendingAudioRecording>[];
    final chunks =
        (await store.pending(
          ownerAccountId,
          limit: _pendingAudioReviewPartLimit,
        )).where(
          (chunk) =>
              chunk.state != LocalChunkState.capturing &&
              chunk.state != LocalChunkState.released,
        );
    final grouped = <String, List<AudioChunk>>{};
    for (final chunk in chunks) {
      grouped.putIfAbsent(chunk.sessionId, () => <AudioChunk>[]).add(chunk);
    }

    final recordings = await Future.wait(
      grouped.entries.map((entry) async {
        final parts = entry.value
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
        final sizes = await Future.wait(parts.map(store.storedBytes));
        final durationMs = parts.fold<int>(
          0,
          (total, chunk) => total + chunk.durationMs,
        );
        return PendingAudioRecording(
          id: entry.key,
          startedAt: parts.first.startedAt,
          duration: Duration(milliseconds: durationMs),
          byteSize: sizes.fold<int>(0, (total, size) => total + size),
          stage: _pendingPlaybackStage(parts),
          parts: parts
              .map(
                (chunk) => PendingAudioPart(
                  id: chunk.id,
                  duration: Duration(milliseconds: chunk.durationMs),
                  mimeType: _audioMimeType(chunk.container),
                ),
              )
              .toList(growable: false),
        );
      }),
    );
    recordings.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return recordings;
  }

  PendingAudioPlaybackStage _pendingPlaybackStage(List<AudioChunk> chunks) {
    if (chunks.any(
      (chunk) =>
          chunk.state == LocalChunkState.needsAttention ||
          chunk.state == LocalChunkState.failed,
    )) {
      return PendingAudioPlaybackStage.needsAttention;
    }
    if (chunks.any((chunk) => chunk.state == LocalChunkState.ready)) {
      return PendingAudioPlaybackStage.onDevice;
    }
    if (chunks.any((chunk) => chunk.state == LocalChunkState.uploading)) {
      return PendingAudioPlaybackStage.uploading;
    }
    if (chunks.any((chunk) => chunk.state == LocalChunkState.uploaded)) {
      return PendingAudioPlaybackStage.serverProcessing;
    }
    return PendingAudioPlaybackStage.finalizing;
  }

  String _audioMimeType(String container) => switch (container.toLowerCase()) {
    'wav' => 'audio/wav',
    'mp3' || 'mpeg' => 'audio/mpeg',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' || 'adts' => 'audio/aac',
    'webm' => 'audio/webm',
    'ogg' || 'opus' => 'audio/ogg',
    _ => 'application/octet-stream',
  };

  Future<Uint8List> readPendingAudioPart(String partId) async {
    final ownerAccountId = accountId;
    if (ownerAccountId == null) {
      throw StateError('Sign in to review retained audio.');
    }
    final chunks = await store.pending(
      ownerAccountId,
      limit: _pendingAudioReviewPartLimit,
    );
    final matches = chunks.where(
      (chunk) =>
          chunk.id == partId &&
          chunk.state != LocalChunkState.capturing &&
          chunk.state != LocalChunkState.released,
    );
    if (matches.isEmpty) {
      throw StateError(
        'This audio finished processing and is no longer retained locally.',
      );
    }
    return store.readBytes(matches.first);
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
    _cancelMobileCaptureRecovery();
    if (isRecording) await stopRecording();
    await mobile.pauseBackgroundRuntime();
    notice =
        'Background recording and device sync are paused. Open NeoRecall to resume them.';
    notifyListeners();
  }

  /// How often an open, authenticated app re-reads server-side results.
  ///
  /// A recording can run for hours, and its transcript, live conversation
  /// insight and memories all appear while it is still going. Without a
  /// foreground poll the screen would only change when the user pulled to
  /// refresh or returned to the app, which is exactly the case this exists for.
  static const Duration _foregroundRefreshInterval = Duration(seconds: 60);
  Timer? _foregroundRefreshTimer;
  bool _refreshing = false;

  void _startForegroundRefresh() {
    if (_foregroundRefreshTimer != null || !authenticated) return;
    _foregroundRefreshTimer = Timer.periodic(
      _foregroundRefreshInterval,
      (_) => unawaited(refreshAll(silent: true)),
    );
  }

  void _stopForegroundRefresh() {
    _foregroundRefreshTimer?.cancel();
    _foregroundRefreshTimer = null;
  }

  /// Stops foreground polling when the app leaves the screen. Capture, upload
  /// and device sync are owned by the background runtime and keep running.
  void onAppPaused() => _stopForegroundRefresh();

  Future<void> refreshAll({bool silent = false}) async {
    if (!authenticated) {
      _stopForegroundRefresh();
      return;
    }
    _startForegroundRefresh();
    // Eight requests go out per refresh. On a slow or distant server one can
    // outlast the interval, and a periodic timer would then stack refreshes
    // until they starve everything else the app is doing.
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) {
      loading = true;
      notifyListeners();
    }
    try {
      // Each section is fetched independently on purpose. These used to share a
      // single Future.wait, so one endpoint failing threw away all nine
      // responses and the whole app came up empty — a day of recordings could
      // be perfectly safe on the server and still show as nothing at all.
      //
      // What you have should never depend on what you cannot have: if writing up
      // memories is broken, the transcripts are still there and still worth
      // showing.
      final failures = <String>[];
      Future<Map<String, dynamic>?> section(String path) async {
        try {
          return Map<String, dynamic>.from(await api.request('GET', path) as Map);
        } catch (exception) {
          failures.add(path);
          return null;
        }
      }

      final results = await Future.wait<Map<String, dynamic>?>(<Future<Map<String, dynamic>?>>[
        section('/api/v1/recordings'),
        section('/api/v1/memories?archived=all&limit=200'),
        section('/api/v1/mini-memories?limit=200'),
        section('/api/v1/speakers'),
        section('/api/v1/devices'),
        section('/api/v1/transcripts?limit=250'),
        section('/api/v1/conversations?limit=100'),
        section('/api/v1/daily-summaries?limit=100'),
        section('/api/v1/processing-status'),
      ]);
      List<Map<String, dynamic>> rows(int index, String key) =>
          ((results[index]?[key] as List?) ?? <dynamic>[])
              .cast<Map>()
              .map(Map<String, dynamic>.from)
              .toList();
      // A section that failed keeps whatever it had rather than being blanked.
      if (results[0] != null) {
        recordings = rows(0, 'items')
            .map(RecordingSession.fromJson)
            .toList();
      }
      if (results[1] != null) {
        memories = rows(1, 'items').map(RecallMemory.fromJson).toList();
      }
      if (results[2] != null) {
        miniMemories = rows(2, 'items').map(MiniMemory.fromJson).toList();
      }
      if (results[3] != null) {
        speakers = rows(3, 'speakers').map(RecallSpeaker.fromJson).toList();
      }
      if (results[4] != null) devices = rows(4, 'devices');
      if (results[5] != null) {
        transcript = rows(5, 'items').map(TranscriptSegment.fromJson).toList();
        _transcriptCursor = results[5]?['nextCursor']?.toString();
      }
      if (results[6] != null) conversations = rows(6, 'items');
      if (results[7] != null) dailySummaries = rows(7, 'items');
      final processing = results[8];
      if (processing != null) {
        processingIssues = rows(8, 'issues');
        processingSummary = processing['summary']?.toString() ?? '';
        audioStillOnDevice =
            ((processing['audio'] as Map?)?['stillOnYourDevice'] as num?)
                ?.toInt() ??
            0;
      }
      cachedData = failures.isNotEmpty;
      // Only worth interrupting for when nothing at all came back. A partial
      // refresh has already shown what it could, and the status card explains
      // anything genuinely wrong far better than a failed request URL would.
      error = (!silent && failures.length == results.length)
          ? 'Could not reach NeoRecall. Showing what was loaded last.'
          : null;
    } catch (exception) {
      cachedData = true;
      error = silent ? null : exception.toString();
    } finally {
      _refreshing = false;
      loading = false;
      notifyListeners();
    }
  }

  /// Pulls in the page of transcript before the oldest one on screen. Failing
  /// here leaves what is already shown untouched: reaching further back is a
  /// convenience, and losing today's timeline to fetch yesterday's would be a
  /// poor trade.
  Future<void> loadOlderTranscript() async {
    final cursor = _transcriptCursor;
    if (cursor == null || isLoadingOlderTranscript) return;
    isLoadingOlderTranscript = true;
    notifyListeners();
    try {
      final payload = Map<String, dynamic>.from(
        await api.request('GET', '/api/v1/transcripts?limit=250&before=$cursor') as Map,
      );
      final older = ((payload['items'] as List?) ?? <dynamic>[])
          .cast<Map>()
          .map((row) => TranscriptSegment.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      final known = transcript.map((segment) => segment.id).toSet();
      transcript = <TranscriptSegment>[
        ...transcript,
        ...older.where((segment) => !known.contains(segment.id)),
      ];
      _transcriptCursor = payload['nextCursor']?.toString();
    } catch (exception) {
      warning = 'Older transcript could not be loaded just now.';
    } finally {
      isLoadingOlderTranscript = false;
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
    final deviceName =
        audioDeviceSessions.preferredDevice?.displayName ?? 'the device';

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
      await storage.drainStoredAudio((recording) async {
        // The first transferred recording makes an automatic sweep visible:
        // now there is real progress to report. It also tells the background
        // host to keep the CPU awake until the transfer finishes.
        deviceStorageSyncing = true;
        await _setBackgroundSyncActive(true);
        notifyListeners();
        await _ingestDeviceRecording(recording);
        deviceStorageSyncedCount += 1;
        notifyListeners();
      }, minBytes: _deviceStorageMinBytes);
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

  Future<void> _setBackgroundUploadActive(bool active) async {
    if (recorder is! MobileRecallRecorder) return;
    await (recorder as MobileRecallRecorder).setUploadActive(active);
  }

  /// True when the sweep that is failing right now is not the first one to fail.
  /// The scheduler counts a sweep only after it returns, so a non-zero count
  /// here means an earlier sweep already failed.
  bool get _deviceSyncFailureIsPersistent =>
      deviceStorageSync.consecutiveFailures >= 1;

  /// This client's durable device identity for [accountId], created once and
  /// reused by recording and by device imports alike.
  ///
  /// Generating it here rather than at each call site is what keeps a drained
  /// wearable recording attributable to the same device the live capture uses.
  Future<({String id, String clientUuid})> _deviceIdentity(
    String accountId,
  ) async {
    final idKey = 'deviceId:$accountId';
    final clientUuidKey = 'deviceClientUuid:$accountId';
    final id = _preferences!.getString(idKey) ?? _uuid.v4();
    final clientUuid = _preferences!.getString(clientUuidKey) ?? _uuid.v4();
    await _preferences!.setString(idKey, id);
    await _preferences!.setString(clientUuidKey, clientUuid);
    return (id: id, clientUuid: clientUuid);
  }

  /// Registers this client as a device so an import can be attributed to it, or
  /// null when that is not possible.
  ///
  /// A failure here must not fail the import: an unattributed recording still
  /// reaches the timeline, it just cannot be joined to the sweep before it.
  Future<String?> _registeredDeviceId() async {
    final account = accountId;
    if (account == null || _preferences == null) return null;
    try {
      final identity = await _deviceIdentity(account);
      return await api.registerDevice(
        id: identity.id,
        clientUuid: identity.clientUuid,
        name: _deviceName,
        platform: _platform,
      );
    } catch (_) {
      return null;
    }
  }

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
        // A wearable is drained every few seconds, so consecutive sweeps are
        // stretches of one recording. Naming the device lets the server keep
        // them in one stream instead of one conversation per sweep.
        deviceId: await _registeredDeviceId(),
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
    await api.request('DELETE', '/api/v1/speakers/$id');
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

  Future<void> bulkDeleteSpeakers(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/speakers/bulk',
      body: <String, dynamic>{'ids': ids, 'action': 'delete'},
    );
    await refreshAll(silent: true);
  }

  Future<void> mergeSpeakers(String targetId, List<String> sourceIds) async {
    if (sourceIds.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/speakers/merge',
      body: <String, dynamic>{'targetId': targetId, 'sourceIds': sourceIds},
    );
    await refreshAll(silent: true);
  }

  Future<Map<String, dynamic>> loadSettings() => _settings();
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    final payload =
        await api.request('PUT', '/api/v1/settings', body: changes) as Map;
    await _cacheSettings(Map<String, dynamic>.from(payload['settings'] as Map));
    // Status is derived from the cached policy, so refresh it before returning
    // to a settings screen that may have just changed the network rule.
    await _refreshPending();
    sync.pump.pump();
    _applyRecordingSchedule();
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

  Future<void> deleteMiniMemory(String id) async {
    await api.request('DELETE', '/api/v1/mini-memories/$id');
    miniMemories = miniMemories.where((mini) => mini.id != id).toList();
    notifyListeners();
  }

  /// Full memory detail including linked transcript segments and mini-memories.
  Future<Map<String, dynamic>> loadMemoryDetail(String id) async {
    final payload =
        await api.request('GET', '/api/v1/memories/$id')
            as Map<dynamic, dynamic>;
    return Map<String, dynamic>.from(payload);
  }

  Future<Map<String, dynamic>> loadMiniMemoryDetail(String id) async {
    final payload =
        await api.request('GET', '/api/v1/mini-memories/$id')
            as Map<dynamic, dynamic>;
    return Map<String, dynamic>.from(payload);
  }

  Future<void> renameMemory(String id, String title) async {
    await api.request(
      'PATCH',
      '/api/v1/memories/$id',
      body: <String, dynamic>{'titleEn': title},
    );
    await refreshAll(silent: true);
  }

  Future<void> updateMemory(String id, {bool? pinned, bool? archived}) async {
    final body = <String, dynamic>{};
    if (pinned != null) body['pinned'] = pinned;
    if (archived != null) body['archived'] = archived;
    if (body.isEmpty) return;
    await api.request('PATCH', '/api/v1/memories/$id', body: body);
    await refreshAll(silent: true);
  }

  Future<void> deleteMemory(String id) async {
    await api.request('DELETE', '/api/v1/memories/$id');
    memories = memories.where((memory) => memory.id != id).toList();
    notifyListeners();
  }

  /// Mass pin / archive / delete for the consumer multi-select bar.
  Future<void> bulkMemories(List<String> ids, String action) async {
    if (ids.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/memories/bulk',
      body: <String, dynamic>{'ids': ids, 'action': action},
    );
    await refreshAll(silent: true);
  }

  /// Merge two or more memories into one with a rewritten title and summary.
  Future<Map<String, dynamic>> mergeMemories(List<String> ids) async {
    if (ids.length < 2) {
      throw StateError('Select at least two memories to merge.');
    }
    final payload =
        await api.request(
              'POST',
              '/api/v1/memories/merge',
              body: <String, dynamic>{'ids': ids},
            )
            as Map<dynamic, dynamic>;
    await refreshAll(silent: true);
    return Map<String, dynamic>.from(payload);
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
    _stopForegroundRefresh();
    _cancelMobileCaptureRecovery();
    _recordingScheduleTimer?.cancel();
    _noticeTimer?.cancel();
    _chunkSubscription?.cancel();
    _partialSubscription?.cancel();
    _warningSubscription?.cancel();
    _levelSubscription?.cancel();
    _networkSubscription?.cancel();
    _deviceStateSubscription?.cancel();
    _deviceControlSubscription?.cancel();
    _backgroundSubscription?.cancel();
    _mobileInterruptionSubscription?.cancel();
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
