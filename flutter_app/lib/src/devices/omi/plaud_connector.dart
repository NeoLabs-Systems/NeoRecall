import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';
import 'offline_audio.dart';
import 'offline_sync.dart';

/// PLAUD is a button-record-on-device recorder: audio is captured to on-device
/// flash and pulled over BLE via the sync-file protocol (stop→start→syncFileStart
/// → stream chunks until the `0xFFFFFFFF` end marker). The same handshake backs
/// both live "capture" and offline [drainStoredAudio].
class PlaudConnector extends WearableConnector with WearableOfflineSync {
  PlaudConnector({required super.device, required super.transport});

  static const int _cmdGetBattery = 9;
  static const int _cmdStartRecord = 20;
  static const int _cmdStopRecord = 23;
  static const int _cmdSyncFileStart = 28;
  static const int _cmdStopSync = 30;
  static const Duration _notificationReadyDelay = Duration(seconds: 2);
  static const Duration _commandTimeout = Duration(seconds: 10);
  static const Duration _recordResetDelay = Duration(milliseconds: 500);
  static const Duration _syncReadyDelay = Duration(seconds: 1);
  static const Duration _drainTimeout = Duration(minutes: 8);

  final Map<int, Completer<List<int>>> _pending = <int, Completer<List<int>>>{};
  StreamSubscription<List<int>>? _notificationSub;
  int? _sessionId;
  Timer? _batteryTimer;

  // Offline-drain state. While _drainSink is non-null, decoded chunks go to the
  // drain assembler instead of the live capture stream.
  bool _draining = false;
  OfflineWavAssembler? _drainSink;
  Completer<void>? _drainDone;
  int _drainFrameCount = 0;

  /// The sync-file session is active for either live capture or an offline drain.
  bool get _active => recording || _draining;

  static const Duration _batteryPollInterval = Duration(seconds: 60);

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opusFs320;

  @override
  Future<void> onConnected() async {
    await Future<void>.delayed(_notificationReadyDelay);
    _notificationSub = (await transport.characteristicStream(
      WearableDeviceUuids.plaudService,
      WearableDeviceUuids.plaudNotify,
    )).listen(_handleNotification);
    track(_notificationSub!);
    // PLAUD has no battery notify characteristic, so poll it like the reference
    // to keep the battery indicator current. Best-effort; never blocks capture.
    unawaited(_pollBattery());
    _batteryTimer = Timer.periodic(
      _batteryPollInterval,
      (_) => unawaited(_pollBattery()),
    );
  }

  Future<void> _pollBattery() async {
    try {
      final level = await readBatteryLevel();
      if (level >= 0) batteryLevels.add(level);
    } catch (_) {
      // Battery telemetry is informational; a failed poll is ignored.
    }
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    if (data[0] == 2) {
      final payload = data.sublist(1);
      // The device signals end-of-file with a 0xFFFFFFFF stream position.
      if (payload.length >= 9 && _toInt32(payload.sublist(4, 8)) == 0xFFFFFFFF) {
        final done = _drainDone;
        if (done != null && !done.isCompleted) done.complete();
        return;
      }
      // Each parsed chunk is a self-contained Opus FS320 frame whose length the
      // device declares (byte 8). During an offline drain it is decoded into the
      // WAV assembler; live, it is forwarded directly (the PLAUD path has no
      // downstream frame assembler, so it must not be re-chunked). Matches Omi's
      // reference connector, which forwards each chunk as-is.
      final chunk = _parseAudioChunk(payload);
      if (chunk != null) {
        final sink = _drainSink;
        if (sink != null) {
          sink.addFrame(chunk);
          _drainFrameCount += 1;
        } else {
          audioBytes.add(chunk);
        }
      }
      return;
    }
    if (data.length >= 3) {
      final cmdId = data[1] | (data[2] << 8);
      final payload = data.length > 3 ? data.sublist(3) : <int>[];
      final pending = _pending.remove(cmdId);
      if (pending != null && !pending.isCompleted) pending.complete(payload);
    }
  }

  List<int>? _parseAudioChunk(List<int> payload) {
    if (payload.length < 9) return null;
    final position = _toInt32(payload.sublist(4, 8));
    if (position == 0xFFFFFFFF) return null;
    final length = payload[8];
    if (9 + length > payload.length) return null;
    return payload.sublist(9, 9 + length);
  }

  Future<List<int>?> _sendCommand(int cmdId, List<int> payload) async {
    final existing = _pending[cmdId];
    if (existing != null) {
      return existing.future;
    }
    final pending = Completer<List<int>>();
    _pending[cmdId] = pending;
    final command = <int>[1, cmdId & 0xFF, (cmdId >> 8) & 0xFF, ...payload];
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.plaudService,
        WearableDeviceUuids.plaudWrite,
        command,
      );
      return await pending.future.timeout(_commandTimeout);
    } on TimeoutException {
      return null;
    } finally {
      if (identical(_pending[cmdId], pending)) _pending.remove(cmdId);
    }
  }

  @override
  Future<int> readBatteryLevel() async {
    final response = await _sendCommand(_cmdGetBattery, const <int>[]);
    if (response != null && response.length >= 2) return response[1];
    return -1;
  }

  @override
  Future<void> startRecording() async {
    if (_active) return;
    recording = true;
    // Await the first setup attempt so the caller (and tests) observe the
    // session sync write. If the device does not respond, keep retrying in the
    // background without blocking the caller.
    final established = await _attemptSessionSetup();
    if (!established && recording) {
      unawaited(_retrySessionSetup());
    }
  }

  Future<void> _retrySessionSetup() async {
    while (recording) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!recording) return;
      if (await _attemptSessionSetup()) return;
    }
  }

  /// Runs one stop→start→sync handshake. Returns true once the device confirms
  /// the sync-file-start command, echoing back its session id and start time.
  Future<bool> _attemptSessionSetup() async {
    if (!_active) return false;
    await _sendCommand(_cmdStopRecord, <int>[
      ..._toBytes32(0),
      ..._toBytes32(0),
    ]);
    await Future<void>.delayed(_recordResetDelay);
    if (!_active) return false;
    final response = await _sendCommand(_cmdStartRecord, <int>[
      ..._toBytes32(1),
      ..._toBytes32(0),
      ..._toBytes32(0),
    ]);
    if (response == null || response.length < 10) return false;
    final sessionId = _toInt32(response.sublist(0, 4));
    final startTime = _toInt32(response.sublist(4, 8));
    await Future<void>.delayed(_syncReadyDelay);
    if (!_active) return false;
    final syncResponse = await _sendCommand(_cmdSyncFileStart, <int>[
      ..._toBytes64(sessionId),
      ..._toBytes64(startTime),
      ..._toBytes64(0x7FFFFFFF),
    ]);
    if (syncResponse != null && _active) {
      _sessionId = sessionId;
      return true;
    }
    return false;
  }

  // --- Offline drain (WearableOfflineSync) ---

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    if (_active) return 0;
    final assembler = OfflineWavAssembler(
      codec: WearableAudioCodec.opusFs320,
      stripBleHeader: false,
    );
    if (!await assembler.ensureSupported()) {
      assembler.dispose();
      return 0;
    }
    _draining = true;
    _drainSink = assembler;
    _drainFrameCount = 0;
    final done = Completer<void>();
    _drainDone = done;
    try {
      if (await _attemptSessionSetup()) {
        // Chunks stream into the assembler until the 0xFFFFFFFF end marker.
        await done.future.timeout(_drainTimeout, onTimeout: () {});
      }
      await _stopSync();
    } finally {
      _draining = false;
      _drainSink = null;
      _drainDone = null;
      _sessionId = null;
    }
    final pcmBytes = assembler.pcmByteLength;
    final wav = assembler.toWav();
    assembler.dispose();
    if (_drainFrameCount == 0 || pcmBytes < minBytes) return 0;
    await onRecording(
      WearableRecording(
        id: 'plaud-offline',
        bytes: wav,
        contentType: 'audio/wav',
        filename: 'plaud-offline.wav',
      ),
    );
    return 1;
  }

  @override
  Future<void> cancelStoredSync() async {
    final done = _drainDone;
    _drainSink = null;
    _drainDone = null;
    _draining = false;
    if (done != null && !done.isCompleted) done.complete();
    await _stopSync();
  }

  Future<void> _stopSync() async {
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.plaudService,
        WearableDeviceUuids.plaudWrite,
        <int>[1, _cmdStopSync & 0xff, (_cmdStopSync >> 8) & 0xff, 1],
      );
    } catch (_) {
      // Best-effort; the session ends on disconnect regardless.
    }
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.plaudService,
        WearableDeviceUuids.plaudWrite,
        <int>[1, _cmdStopSync & 0xFF, (_cmdStopSync >> 8) & 0xFF, 1],
      );
      if (_sessionId != null) {
        await _sendCommand(_cmdStopRecord, <int>[
          ..._toBytes32(_sessionId!),
          ..._toBytes32(0),
        ]);
      }
    } finally {
      recording = false;
      _sessionId = null;
    }
  }

  int _toInt32(List<int> bytes) =>
      bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);

  List<int> _toBytes32(int value) => <int>[
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ];

  List<int> _toBytes64(int value) => <int>[
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
    (value >> 32) & 0xFF,
    (value >> 40) & 0xFF,
    (value >> 48) & 0xFF,
    (value >> 56) & 0xFF,
  ];

  @override
  Future<void> dispose() async {
    _batteryTimer?.cancel();
    _batteryTimer = null;
    await super.dispose();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        // Resolve (not error) in-flight commands on teardown: a disconnect or
        // reconnect mid-handshake should read as "no response" so the setup
        // simply fails and retries, never as a fatal user-facing exception.
        pending.complete(const <int>[]);
      }
    }
    _pending.clear();
  }
}
