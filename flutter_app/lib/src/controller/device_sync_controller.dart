part of '../../main_controller.dart';

/// Draining a wearable's on-board storage into the ingest pipeline.
///
/// Distinct from live capture even though both produce audio: this runs on a
/// schedule against a device that recorded while nothing was connected, has to
/// stand down when live capture claims the device, and reports its own progress
/// and failures.
mixin DeviceSyncController on ChangeNotifier {
  NeoRecallApiClient get api;
  ChunkStore get store;
  RecallRecorder get recorder;
  SyncCoordinator get sync;
  AudioDeviceAdapterRegistry get audioDeviceRegistry;
  DeviceSessionController get audioDeviceSessions;
  SharedPreferences? get _preferences;
  Uuid get _uuid;
  String get _platform;
  String get _deviceName;
  bool get deviceStorageSyncAvailable;
  bool get isRecording;
  bool get online;
  String? get error;
  set error(String? value);

  // --- declared by the controller ---
  String? get accountId;
  String? get username;
  bool get authenticated;
  String get backendUrl;
  String? get notice;
  set notice(String? value);
  Future<void> refreshAll({bool silent});
  DeviceStorageSyncScheduler get deviceStorageSync;

  // --- owned here ---
  bool deviceStorageSyncing = false;
  int deviceStorageSyncedCount = 0;
  int deviceStoragePendingCount = 0;
  String? deviceStorageSyncError;
  static const int _deviceStorageMinBytes = 2048;

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
      final message = error is TimeoutException
          ? '$deviceName did not respond in time. Keep it nearby and awake, then try again.'
          : error.toString().replaceFirst(
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
}
