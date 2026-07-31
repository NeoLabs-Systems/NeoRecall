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
  static const Duration _handshakeTimeout = Duration(seconds: 6);
  static const Duration _handshakeChunkGap = Duration(milliseconds: 250);

  /// Session preamble the official PLAUD app sends before any command.
  ///
  /// Captured from a btsnoop HCI log of the official app driving this exact
  /// NotePin: three chunks framed `[0x10][0xfe][total=3][index]` carrying a
  /// fixed 256-byte credential, answered by the device with `[0x12][0xfe]…`.
  /// The bytes were **byte-identical across all six observed connections**, so
  /// this is a fixed app credential rather than a per-session key exchange —
  /// the same shape as HeyPocket's fixed `APP&SK&…` key, which is likewise
  /// mandatory before the device answers anything.
  static const List<String> _handshakeChunksHex = <String>[
    '10fe03005518b7d8fa9fa6c60a3c409c260dc76b17470e2d44ad4936e93291ddc7'
        '7fc1f60e250f6b995a619ae7054d897daf61b45c06ef89a5a2565b40b0e3daa5b'
        '0a3537fb91fe9f2b1f98aa2a07d0ffdd61f3fa065a932be6823705d577c1cfa59'
        'd98d8619bf25',
    '10fe0301b24e4a4f8a4b3b219fd4c9a8f7093eabc480e083e0edfbf42d5484201f3'
        'a56eba30971c392ace5e7ab5a5b7045416636c3f5d087d121b590b20dc5a0341b'
        '01dc6413728b03d2374853a113aefcff4f37498c42b1e56d556c88c648c195912'
        '0716a14134d',
    '10fe0302dba0bda131ebdc77e2139f1d23137645e6e3878d3bcec908b1d9b1abeff'
        '4ab3a392df046a4bbece5f331f2f19284c88bfe5e618fca7a1eda',
  ];

  static const int _handshakeReplyMarker0 = 0x12;
  static const int _handshakeReplyMarker1 = 0xfe;

  final Map<int, Completer<List<int>>> _pending = <int, Completer<List<int>>>{};
  StreamSubscription<List<int>>? _notificationSub;
  int? _sessionId;
  Timer? _batteryTimer;
  Completer<bool>? _handshakeAck;
  bool _handshakeCompleted = false;

  /// Whether the device acknowledged the session preamble on this connection.
  /// Exposed so the controller can surface a precise reason when a PLAUD sync
  /// finds nothing: an unacknowledged preamble means the firmware never opened
  /// its command channel, which is a very different failure from "no recordings".
  bool get handshakeCompleted => _handshakeCompleted;

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
    // The firmware ignores every command until the session preamble is
    // acknowledged, so it has to run before anything else on this connection.
    await _performHandshake();
    // PLAUD has no battery notify characteristic, so poll it like the reference
    // to keep the battery indicator current. Best-effort; never blocks capture.
    unawaited(_pollBattery());
    _batteryTimer = Timer.periodic(
      _batteryPollInterval,
      (_) => unawaited(_pollBattery()),
    );
  }

  /// Sends the fixed session preamble and waits for the device to acknowledge it.
  ///
  /// Best-effort: a device/firmware that does not require the preamble simply
  /// never answers, and the reference command sequence is still attempted. Each
  /// chunk is written on its own because the framing carries an explicit index.
  Future<bool> _performHandshake() async {
    if (_handshakeCompleted) return true;
    final ack = Completer<bool>();
    _handshakeAck = ack;
    try {
      for (final hex in _handshakeChunksHex) {
        await transport.writeCharacteristic(
          WearableDeviceUuids.plaudService,
          WearableDeviceUuids.plaudWrite,
          _decodeHex(hex),
        );
        await Future<void>.delayed(_handshakeChunkGap);
      }
      _handshakeCompleted = await ack.future.timeout(
        _handshakeTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      _handshakeCompleted = false;
    } finally {
      _handshakeAck = null;
    }
    return _handshakeCompleted;
  }

  static List<int> _decodeHex(String hex) => <int>[
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

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
    // The session preamble is acknowledged with `[0x12][0xfe][total][index]`.
    // It must be matched before the generic command decoding below, which would
    // otherwise read these bytes as a bogus command id.
    if (data.length >= 2 &&
        data[0] == _handshakeReplyMarker0 &&
        data[1] == _handshakeReplyMarker1) {
      final pending = _handshakeAck;
      if (pending != null && !pending.isCompleted) pending.complete(true);
      return;
    }
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
    // A drain can start before/after the connect-time preamble (reconnects, or
    // a sync triggered the moment the link comes up), so make sure it ran.
    if (!_handshakeCompleted) await _performHandshake();
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
  Map<String, Object?> get syncDiagnostics => <String, Object?>{
    // Distinguishes "device has nothing stored" from "device never opened its
    // command channel" — the two look identical from the sync result alone.
    'handshakeAcknowledged': _handshakeCompleted,
    'sessionEstablished': _sessionId != null,
    'framesReceived': _drainFrameCount,
  };

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
    // The preamble is per-connection: a reconnect must send it again.
    _handshakeCompleted = false;
    final ack = _handshakeAck;
    if (ack != null && !ack.isCompleted) ack.complete(false);
    _handshakeAck = null;
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
