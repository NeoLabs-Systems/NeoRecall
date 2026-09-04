import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import '../audio_device_adapter.dart';
import '../omi/offline_sync.dart';
import 'plaud_hardware.dart';
import 'plaud_hardware_factory.dart';
import 'plaud_session.dart';

/// Plaud Note Pro / NotePin S as an offline-first wearable.
///
/// Uses Plaud's Embedded SDK over BLE. Handshake tokens come from NeoRecall;
/// recordings are exported locally and ingested like HeyPocket files. Plaud
/// upload and transcription APIs are never called.
class PlaudAdapter implements AudioDeviceAdapter, StorageSyncCapableAdapter {
  PlaudAdapter({
    PlaudHardware? hardware,
    PlaudSessionFetcher? fetchSession,
    this.connectTimeout = const Duration(seconds: 45),
    this.fileListTimeout = const Duration(seconds: 20),
    this.exportTimeout = const Duration(minutes: 30),
    this.deleteTimeout = const Duration(seconds: 20),
  }) : _hardware = hardware ?? createPlaudHardware(),
       _fetchSession = fetchSession;

  static const String adapterId = 'plaud';

  final PlaudHardware _hardware;
  PlaudSessionFetcher? _fetchSession;
  final Duration connectTimeout;
  final Duration fileListTimeout;
  final Duration exportTimeout;
  final Duration deleteTimeout;

  final StreamController<AudioDeviceDescriptor> _discoveries =
      StreamController<AudioDeviceDescriptor>.broadcast();
  final StreamController<DeviceControlEvent> _controlEvents =
      StreamController<DeviceControlEvent>.broadcast();
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();
  final StreamController<WearableSyncProgress> _syncProgress =
      StreamController<WearableSyncProgress>.broadcast();

  final Map<String, PlaudDiscoveredDevice> _found =
      <String, PlaudDiscoveredDevice>{};
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  DeviceTransportState _state = DeviceTransportState.disconnected;
  bool _initialized = false;
  bool _drainCancelled = false;
  String? _connectedKey;
  PlaudEmbeddedSession? _session;
  int _lastFilesListed = 0;
  int _lastSynced = 0;
  int _lastFailed = 0;

  void attachSessionFetcher(PlaudSessionFetcher fetchSession) {
    _fetchSession = fetchSession;
  }

  @override
  String get id => adapterId;
  @override
  String get displayName => 'Plaud';
  @override
  String get transport => 'bluetooth_le';
  @override
  Stream<AudioDeviceDescriptor> get discoveries => _discoveries.stream;
  @override
  Stream<DeviceControlEvent> get controlEvents => _controlEvents.stream;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<DeviceTransportState> get transportStates => _states.stream;

  @override
  WearableOfflineSync? get offlineSyncConnector =>
      _state == DeviceTransportState.disconnected ? null : _Sync(this);

  void _setState(DeviceTransportState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  AudioDeviceDescriptor _toDescriptor(PlaudDiscoveredDevice device) {
    return AudioDeviceDescriptor(
      adapterId: id,
      deviceKey: device.uuid.isNotEmpty ? device.uuid : device.serialNumber,
      displayName: device.name.isNotEmpty ? device.name : 'Plaud',
      transport: transport,
      supportsMicrophone: false,
      supportsHardwareButtons: true,
      metadata: <String, Object?>{
        'type': 'plaud',
        'uuid': device.uuid,
        'serialNumber': device.serialNumber,
        'rssi': device.rssi,
      },
    );
  }

  Future<bool> _ensureSession() async {
    final fetch = _fetchSession;
    if (fetch == null) return false;
    final existing = _session;
    if (existing != null && existing.isFresh) return true;
    final next = await fetch();
    if (next == null) return false;
    _session = next;
    await _hardware.initialize(
      accessToken: next.accessToken,
      customDomain: next.customDomain,
      userId: next.userId,
    );
    return true;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _subs.add(
      _hardware.scanResults.listen((devices) {
        for (final device in devices) {
          final descriptor = _toDescriptor(device);
          _found[descriptor.deviceKey] = device;
          if (!_discoveries.isClosed) _discoveries.add(descriptor);
        }
      }),
    );
    _subs.add(
      _hardware.connectUpdates.listen((update) {
        if (update.failed) {
          _setState(DeviceTransportState.faulted);
          _connectedKey = null;
        } else if (update.connected) {
          _setState(DeviceTransportState.connectedStandby);
        } else {
          _setState(DeviceTransportState.disconnected);
          _connectedKey = null;
        }
      }),
    );
    _subs.add(
      _hardware.batteryLevels.listen((level) {
        if (_controlEvents.isClosed) return;
        _controlEvents.add(
          DeviceControlEvent(
            type: DeviceControlEventType.battery,
            payload: <String, Object?>{'level': level},
          ),
        );
      }),
    );
    _initialized = true;
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await initialize();
    if (!_hardware.isAvailable) return;
    if (!await _ensureSession()) return;
    await _hardware.startScan();
    await Future<void>.delayed(timeout);
    await _hardware.stopScan();
  }

  @override
  Future<void> stopScan() => _hardware.stopScan();

  @override
  Future<void> connect(AudioDeviceDescriptor device) async {
    await initialize();
    if (device.adapterId != id) {
      throw ArgumentError.value(device.adapterId, 'device.adapterId');
    }
    if (!_hardware.isAvailable) {
      throw UnsupportedError(
        'Plaud pairing is available on iOS and Android with the Embedded SDK. Desktop and the browser cannot complete Plaud\'s encrypted handshake.',
      );
    }
    if (!await _ensureSession()) {
      throw StateError(
        'This server has no Plaud Embedded credentials. Set NEORECALL_PLAUD_CLIENT_ID and NEORECALL_PLAUD_CLIENT_SECRET.',
      );
    }
    _setState(DeviceTransportState.connecting);
    await _hardware.startScan();
    final match = await _waitForMatch(device);
    await _hardware.stopScan();
    final connected = _waitForConnected();
    await _hardware.connect(
      uuid: match.uuid.isNotEmpty ? match.uuid : null,
      serialNumber: match.serialNumber.isNotEmpty ? match.serialNumber : null,
      deviceToken: _session?.userId,
    );
    await connected.timeout(connectTimeout);
    _connectedKey = device.deviceKey;
    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'plaud_connected',
      details: <String, Object?>{
        'name': device.displayName,
        'serial': match.serialNumber,
      },
    );
  }

  Future<PlaudDiscoveredDevice> _waitForMatch(AudioDeviceDescriptor device) async {
    final existing = _found[device.deviceKey];
    if (existing != null) return existing;
    final serial = device.metadata['serialNumber'] as String?;
    final uuid = device.metadata['uuid'] as String?;
    try {
      return _found.values.firstWhere(
        (item) =>
            item.uuid == device.deviceKey ||
            (uuid != null && item.uuid == uuid) ||
            (serial != null && serial.isNotEmpty && item.serialNumber == serial),
      );
    } catch (_) {}
    final found = Completer<PlaudDiscoveredDevice>();
    late final StreamSubscription<List<PlaudDiscoveredDevice>> sub;
    sub = _hardware.scanResults.listen((devices) {
      for (final item in devices) {
        final key = item.uuid.isNotEmpty ? item.uuid : item.serialNumber;
        if (key == device.deviceKey ||
            item.uuid == uuid ||
            (serial != null && item.serialNumber == serial)) {
          if (!found.isCompleted) found.complete(item);
        }
      }
    });
    try {
      return await found.future.timeout(connectTimeout);
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _waitForConnected() async {
    if (_state == DeviceTransportState.connectedStandby) return;
    await _states.stream.firstWhere(
      (state) =>
          state == DeviceTransportState.connectedStandby ||
          state == DeviceTransportState.faulted,
    );
    if (_state == DeviceTransportState.faulted) {
      throw StateError('Plaud handshake failed. The device may already be bound to another app.');
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _hardware.disconnect();
    } finally {
      _connectedKey = null;
      _setState(DeviceTransportState.disconnected);
    }
  }

  @override
  Future<void> requestStartRecording() async {
    throw UnsupportedError(
      'Plaud records on the device. Use the pin button, then sync recordings.',
    );
  }

  @override
  Future<void> requestStopRecording() async {}

  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    _drainCancelled = false;
    _lastFilesListed = 0;
    _lastSynced = 0;
    _lastFailed = 0;
    if (_state != DeviceTransportState.connectedStandby &&
        _state != DeviceTransportState.recording) {
      throw StateError('Plaud is not connected.');
    }
    final files = await _listFiles();
    _lastFilesListed = files.length;
    var pendingSeconds = files.fold<int>(
      0,
      (sum, file) => sum + file.durationSeconds,
    );
    _syncProgress.add(
      WearableSyncProgress(
        transferred: 0,
        total: files.length,
        pendingSeconds: pendingSeconds,
      ),
    );
    var count = 0;
    var failed = 0;
    for (final file in files) {
      if (_drainCancelled) break;
      try {
        final bytes = await _hardware.exportAudio(file.sessionId).timeout(
          exportTimeout,
        );
        if (bytes.length < minBytes) continue;
        await onRecording(
          WearableRecording(
            id: 'plaud:${file.serialNumber}:${file.sessionId}',
            bytes: bytes,
            contentType: 'audio/mpeg',
            filename: 'plaud-${file.sessionId}.mp3',
            capturedAt: _capturedAt(file.sessionId),
          ),
        );
        await _deleteAfterIngest(file.sessionId);
        count += 1;
        pendingSeconds = (pendingSeconds - file.durationSeconds).clamp(0, pendingSeconds);
        _syncProgress.add(
          WearableSyncProgress(
            transferred: count,
            total: files.length,
            pendingSeconds: pendingSeconds,
          ),
        );
      } catch (error) {
        failed += 1;
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'plaud_file_failed',
          level: 'warning',
          details: <String, Object?>{
            'sessionId': file.sessionId,
            'error': error.toString(),
          },
        );
      }
    }
    _lastSynced = count;
    _lastFailed = failed;
    if (count == 0 && failed > 0) {
      throw StateError(
        'Found $failed recording(s) on the Plaud but none could be transferred. Keep it close and try again.',
      );
    }
    return count;
  }

  DateTime? _capturedAt(int sessionId) {
    if (sessionId <= 0) return null;
    final millis = sessionId > 1000000000000 ? sessionId : sessionId * 1000;
    final time = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (time.year < 2015 || time.year > 2100) return null;
    return time;
  }

  Future<List<PlaudStoredFile>> _listFiles() async {
    final completer = Completer<List<PlaudStoredFile>>();
    late final StreamSubscription<List<PlaudStoredFile>> sub;
    sub = _hardware.fileLists.listen((files) {
      if (!completer.isCompleted) completer.complete(files);
    });
    try {
      await _hardware.getFileList();
      return await completer.future.timeout(fileListTimeout);
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _deleteAfterIngest(int sessionId) async {
    final done = Completer<void>();
    late final StreamSubscription<({int sessionId, bool ok})> sub;
    sub = _hardware.deleteResults.listen((result) {
      if (result.sessionId == sessionId && !done.isCompleted) {
        done.complete();
      }
    });
    try {
      await _hardware.deleteFile(sessionId);
      await done.future.timeout(deleteTimeout, onTimeout: () {});
    } finally {
      await sub.cancel();
    }
  }

  Future<void> cancelStoredSync() async {
    _drainCancelled = true;
  }

  Future<WearableSyncProgress?> peekPending() async {
    if (_state != DeviceTransportState.connectedStandby) return null;
    try {
      final files = await _listFiles();
      final seconds = files.fold<int>(0, (sum, file) => sum + file.durationSeconds);
      return WearableSyncProgress(
        transferred: 0,
        total: files.length,
        pendingSeconds: seconds,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> get syncDiagnostics => <String, Object?>{
    'filesListed': _lastFilesListed,
    'synced': _lastSynced,
    'failed': _lastFailed,
    'cancelled': _drainCancelled,
    'connected': _connectedKey != null,
  };

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await disconnect();
    await _discoveries.close();
    await _controlEvents.close();
    await _pcm.close();
    await _states.close();
    await _syncProgress.close();
  }
}

class _Sync with WearableOfflineSync {
  _Sync(this._adapter);
  final PlaudAdapter _adapter;

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) {
    return _adapter.drainStoredAudio(onRecording, minBytes: minBytes);
  }

  @override
  Future<void> cancelStoredSync() => _adapter.cancelStoredSync();

  @override
  Stream<WearableSyncProgress> get syncProgress => _adapter._syncProgress.stream;

  @override
  Future<WearableSyncProgress?> peekPending() => _adapter.peekPending();

  @override
  Map<String, Object?> get syncDiagnostics => _adapter.syncDiagnostics;
}
