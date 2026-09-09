import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import '../live_coverage.dart';
import '../wearable_ingested_files.dart';
import 'base_connector.dart';
import 'device_models.dart';
import 'memoket_protocol.dart';
import 'offline_sync.dart';

/// Memoket Gem BLE recorder.
///
/// Protocol confirmed against official-app HCI captures:
/// - Handshake: ping, firmware, clock, storage. Battery is the standard
///   180F/2A19 characteristic (HCI handle 0x0012), with vendor `e1` as fallback.
/// - Remote start `01 00 00` / stop `02 00` also starts and stops on-device
///   recording; live Opus frames arrive on [WearableDeviceUuids.memoketAudioNotify].
/// - Offline files: `03` lists, `04 <name>` downloads on the file-notify
///   characteristic, `05 <name>` deletes only after durable ingest.
class MemoketConnector extends WearableConnector with WearableOfflineSync {
  MemoketConnector({
    required super.device,
    required super.transport,
    Duration liveJoinTimeout = const Duration(seconds: 5),
    Duration idleJoinTimeout = const Duration(milliseconds: 400),
  }) : _liveJoinTimeout = liveJoinTimeout,
       _idleJoinTimeout = idleJoinTimeout;

  static const Duration _replyTimeout = Duration(milliseconds: 800);
  static const Duration _listTimeout = Duration(seconds: 4);
  static const Duration _startTimeout = Duration(seconds: 3);
  static const Duration _stopTimeout = Duration(seconds: 4);
  static const Duration _downloadStallTimeout = Duration(seconds: 20);
  static const Duration _deleteTimeout = Duration(seconds: 3);
  static const int _downloadAttempts = 3;
  static const Duration _commandGap = Duration(milliseconds: 80);
  static const Duration _subscribeSettle = Duration(milliseconds: 250);
  final Duration _liveJoinTimeout;
  final Duration _idleJoinTimeout;
  static const Duration _writeRetryDelay = Duration(milliseconds: 200);
  static const int _writeAttempts = 3;
  // Long enough that a stop notify plus the follow-up list/delete traffic
  // cannot be mistaken for the user starting a new take from the Gem.
  static const Duration _hardwareStartHoldoff = Duration(seconds: 10);
  static const Duration _progressMinInterval = Duration(milliseconds: 200);

  final StreamController<WearableSyncProgress> _progress =
      StreamController<WearableSyncProgress>.broadcast();

  bool _ready = false;
  bool _sawControl = false;
  bool _drainCancelled = false;
  bool _deviceLive = false;
  DateTime? _holdHardwareStartUntil;
  String? _firmware;
  int _lastBattery = -1;
  String? _liveFilename;
  String? _lastTakeFilename;
  int _liveEmittedFrames = 0;

  /// Filename of the most recent on-device take this phone has seen, kept after
  /// stop so a later drain can target that file without touching others.
  String? get lastTakeFilename => _lastTakeFilename;

  // How much of the current device take actually arrived over the live stream.
  // The device keeps its own copy, and that copy is only redundant if the live
  // audio covers it — a stream that dies mid-take leaves the device holding the
  // only recording of everything said afterwards.
  final LiveCoverage _liveCoverage = LiveCoverage();
  DateTime? _takeStartedAt;
  int _persistedLiveSeconds = -1;
  int _lastFilesListed = 0;

  /// Whether the last sync was an empty no-op that has already been reported.
  bool _idleSyncReported = false;
  int _lastSynced = 0;
  int _lastFailed = 0;
  bool _batterySubscribed = false;
  Future<void> _writeQueue = Future<void>.value();

  Completer<List<int>>? _reply;
  int? _replyOpcode;
  Completer<void>? _listDone;
  Completer<void>? _downloadDone;
  Timer? _downloadStall;
  MemoketStoredFile? _downloadingFile;
  Completer<bool>? _deleteAck;
  Completer<String>? _started;
  Completer<void>? _stopped;
  Completer<void>? _liveJoined;
  List<MemoketStoredFile>? _listed;
  List<Uint8List>? _downloadBuffer;
  int _syncFileIndex = 0;
  int _syncFileCount = 0;
  int _syncExpectedBytes = 0;
  List<MemoketStoredFile> _syncRemaining = const <MemoketStoredFile>[];
  DateTime? _lastProgressAt;
  double _lastPublishedFraction = -1;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opus;

  @override
  bool get supportsConcurrentCapture => false;

  @override
  bool get stopDeviceOnDisconnect => false;

  @override
  Stream<WearableSyncProgress> get syncProgress => _progress.stream;

  @override
  Map<String, Object?> get syncDiagnostics => <String, Object?>{
    'deviceResponded': _sawControl,
    'ready': _ready,
    'firmware': _firmware,
    'filesListed': _lastFilesListed,
    'filesSynced': _lastSynced,
    'filesFailed': _lastFailed,
    'lastTakeFilename': _lastTakeFilename,
  };

  @override
  Future<void> onConnected() async {
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketControlNotify,
      )).listen(_handleControl),
    );
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketAudioNotify,
      )).listen(_handleLiveAudio),
    );
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.memoketService,
        WearableDeviceUuids.memoketFileNotify,
      )).listen(_handleFileChunk),
    );
    await WearableIngestedFiles.hydrate(device.id);
    await _subscribeStandardBattery();
    // CCCD writes must finish before the first control write. Android's GATT
    // queue drops overlapping writes as a pigeon channel-error.
    await Future<void>.delayed(_subscribeSettle);
    // A Gem that is already recording streams live frames as soon as we
    // subscribe. Handshake writes on that same control characteristic have
    // stopped the take; skip them and join the stream instead.
    await _waitForLive(
      resumeLiveOnConnect ? _liveJoinTimeout : _idleJoinTimeout,
    );
    if (_deviceLive || recording) {
      _ready = true;
      _sawControl = true;
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'handshake_skipped_live',
        details: const <String, Object?>{
          'reason': 'Gem was already recording when the link came up.',
        },
      );
      return;
    }
    if (resumeLiveOnConnect) {
      // The take is still on flash even when live notifies have not resumed
      // yet. Handshake writes would stop it.
      _ready = true;
      _sawControl = true;
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'handshake_skipped_resume',
        details: const <String, Object?>{
          'reason': 'Reconnecting an in-progress take; control writes held.',
        },
      );
      return;
    }
    await _handshake();
  }

  void _markDeviceLive() {
    _deviceLive = true;
    final joined = _liveJoined;
    if (joined != null && !joined.isCompleted) joined.complete();
  }

  Future<void> _waitForLive(Duration window) async {
    if (_deviceLive || window <= Duration.zero) return;
    final joined = Completer<void>();
    _liveJoined = joined;
    try {
      await joined.future.timeout(window);
    } on TimeoutException {
      // No live frames in the join window; handshake (or resume) continues.
    } finally {
      if (identical(_liveJoined, joined)) _liveJoined = null;
    }
  }

  Future<void> _handshake() async {
    await _command(MemoketProtocol.ping, MemoketProtocol.opPing);
    if (_deviceLive || recording) {
      _ready = _sawControl;
      return;
    }
    await readBatteryLevel();
    final fw = await _command(
      MemoketProtocol.firmwareQuery,
      MemoketProtocol.opFirmware,
    );
    if (fw != null) _firmware = MemoketProtocol.firmwareVersion(fw);
    await _command(MemoketProtocol.timeQuery, MemoketProtocol.opTimeQuery);
    await _command(
      MemoketProtocol.setTime(DateTime.now()),
      MemoketProtocol.opSetTime,
    );
    await _command(MemoketProtocol.storageQuery, MemoketProtocol.opStorage);
    _ready = _sawControl;
    if (!_ready) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_handshake_silent',
        level: 'warning',
        details: const <String, Object?>{
          'hint': 'Gem did not answer the control handshake.',
        },
      );
    }
  }

  @override
  Future<int> readBatteryLevel() async {
    // The vendor `e1` write shares the control characteristic with start/stop.
    // Doing that while live has stopped the Gem mid-take.
    if (recording || _deviceLive) return _lastBattery;
    final reply = await _command(
      MemoketProtocol.batteryQuery,
      MemoketProtocol.opBattery,
    );
    final parsed = reply == null ? null : MemoketProtocol.parseBattery(reply);
    if (parsed != null) {
      _publishBattery(parsed);
      return parsed.percent;
    }
    final standard = await _readStandardBattery();
    if (standard != null) _publishStandardBattery(standard);
    return _lastBattery;
  }

  Future<void> _subscribeStandardBattery() async {
    if (_batterySubscribed) return;
    if (!transport.hasCharacteristic(
      WearableDeviceUuids.batteryService,
      WearableDeviceUuids.batteryLevel,
    )) {
      return;
    }
    try {
      track(
        (await transport.characteristicStream(
          WearableDeviceUuids.batteryService,
          WearableDeviceUuids.batteryLevel,
        )).listen((value) {
          if (value.isEmpty || value.first > 100) return;
          _publishStandardBattery(MemoketBattery(percent: value.first));
        }),
      );
      _batterySubscribed = true;
    } catch (error) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_battery_subscribe',
        level: 'warning',
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<MemoketBattery?> _readStandardBattery() async {
    if (!transport.hasCharacteristic(
      WearableDeviceUuids.batteryService,
      WearableDeviceUuids.batteryLevel,
    )) {
      return null;
    }
    try {
      final raw = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (raw.isEmpty || raw.first > 100) return null;
      return MemoketBattery(percent: raw.first);
    } catch (_) {
      return null;
    }
  }

  void _publishBattery(MemoketBattery battery) {
    _lastBattery = battery.percent;
    if (!batteryLevels.isClosed) batteryLevels.add(battery.percent);
  }

  /// 180F on this firmware reports 100 as a placeholder. A real vendor reading
  /// (or a still-unknown gauge the UI is already showing) must not be replaced.
  void _publishStandardBattery(MemoketBattery battery) {
    if (battery.percent == 100 && _lastBattery != 100) return;
    _publishBattery(battery);
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    if (!_sawControl) {
      throw StateError(
        'The device did not answer the connection handshake, so recording could '
        'not be started. Reconnect it and try again.',
      );
    }
    // Hardware already started the take — do not send 01 again.
    if (_deviceLive) {
      recording = true;
      _holdHardwareStart();
      return;
    }
    recording = true;
    _clearPendingHardwareStart();
    _holdHardwareStart();
    _liveFilename = null;
    _liveEmittedFrames = 0;
    _takeStartedAt = DateTime.now();
    final started = Completer<String>();
    _started = started;
    try {
      await _write(MemoketProtocol.recordStart);
      try {
        final resolved = await started.future.timeout(_startTimeout);
        if (resolved.isNotEmpty) _liveFilename = resolved;
      } on TimeoutException {
        // Live frames can still arrive; the filename is only needed so stop
        // can delete the on-device copy and avoid a duplicate import.
      }
    } catch (_) {
      recording = false;
      rethrow;
    } finally {
      if (identical(_started, started)) _started = null;
    }
  }

  @override
  Future<void> stopRecording() async {
    if (!recording && !_deviceLive) return;
    recording = false;
    _clearPendingHardwareStart();
    _holdHardwareStart();
    final needRemoteStop = _deviceLive;
    _deviceLive = false;
    if (needRemoteStop) {
      final stopped = Completer<void>();
      _stopped = stopped;
      try {
        await _write(MemoketProtocol.recordStop);
        await stopped.future.timeout(_stopTimeout, onTimeout: () {});
      } catch (_) {
        // Best-effort; notifications drop once we unsubscribe on disconnect.
      } finally {
        if (identical(_stopped, stopped)) _stopped = null;
      }
    }
    final filename = _liveFilename;
    _liveFilename = null;
    // Drop the on-device copy only when the live stream carried the whole take.
    //
    // "Any live frame at all" used to be the test, and it cost recordings: a
    // stream that delivered thirty seconds and then stalled marked a take of
    // several hours as captured, and this deleted the device's copy of every
    // minute the phone never received. The device is the backup precisely for
    // the case where the link fails, so it is only cleared when the phone can
    // show it holds the same span of audio.
    final liveSeconds = _liveCoverageSeconds;
    final int? takeSeconds = _takeSeconds;
    if (filename != null && _liveEmittedFrames > 0) {
      await _rememberLiveIngested(filename, liveSeconds);
      final stalled = _liveCoverage.stalledAt(DateTime.now());
      if (stalled) {
        await WearableIngestedFiles.markIncomplete(device.id, filename);
      }
      final covered =
          !stalled &&
          WearableIngestedFiles.coversSpan(
            liveSeconds: liveSeconds,
            takeSeconds: takeSeconds,
          );
      if (covered) {
        await _deleteStoredFile(
          MemoketStoredFile(
            filename: filename,
            durationSeconds: 0,
            byteLength: 0,
          ),
        );
      } else {
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'memoket_kept_stored_take',
          level: 'warn',
          details: <String, Object?>{
            'id': filename,
            'liveSeconds': liveSeconds,
            'takeSeconds': takeSeconds,
          },
        );
      }
    }
    _liveCoverage.reset();
    _takeStartedAt = null;
    _liveEmittedFrames = 0;
  }

  void _handleControl(List<int> data) {
    if (data.isEmpty) return;
    _sawControl = true;
    final opcode = data.first;
    final waiting = _reply;
    if (waiting != null && _replyOpcode == opcode && !waiting.isCompleted) {
      waiting.complete(List<int>.from(data));
    }
    switch (opcode) {
      case MemoketProtocol.opBattery:
        final parsed = MemoketProtocol.parseBattery(data);
        if (parsed != null) _publishBattery(parsed);
      case MemoketProtocol.opFirmware:
        _firmware = MemoketProtocol.firmwareVersion(data);
      case MemoketProtocol.opRecordStart:
        _markDeviceLive();
        final name = MemoketProtocol.recordingFilename(data);
        // A reconnect start notify for the same take must not zero the frame
        // count — stop uses that to know the live path already ingested it.
        if (name != null && name != _liveFilename) {
          _liveEmittedFrames = 0;
          _liveFilename = name;
          _lastTakeFilename = name;
          // A take the device started on its own (hardware button) has its own
          // clock, and it is the one the coverage check has to measure against.
          _takeStartedAt = DateTime.now();
        } else if (name != null) {
          _liveFilename = name;
          _lastTakeFilename = name;
        }
        final started = _started;
        if (started != null && !started.isCompleted) {
          started.complete(name ?? '');
        } else if (!recording && !_holdingHardwareStart) {
          // Armed, not emitted. A start notify on its own is not proof the Gem
          // is recording — it also answers control traffic with one — and
          // acting on it opened takes the user never began. Live frames are the
          // proof, and they follow a real start within about 120 ms.
          _armPendingHardwareStart();
        } else if (!recording && _holdingHardwareStart) {
          ClientDiagnosticLog.instance.record(
            'bluetooth_audio',
            'hardware_start_held',
            details: <String, Object?>{
              'filename': name,
              'holdoffSeconds': _hardwareStartHoldoff.inSeconds,
            },
          );
        }
      case MemoketProtocol.opRecordStop:
        _deviceLive = false;
        _clearPendingHardwareStart();
        _holdHardwareStart();
        final name = MemoketProtocol.recordingFilename(data);
        if (name != null) {
          _liveFilename = name;
          _lastTakeFilename = name;
        }
        final stopped = _stopped;
        if (stopped != null && !stopped.isCompleted) {
          stopped.complete();
        } else if (recording) {
          _emitDeviceControl(WearableControlCodes.stopRecording);
        }
      case MemoketProtocol.opListFiles:
        if (MemoketProtocol.isListEnd(data)) {
          final done = _listDone;
          if (done != null && !done.isCompleted) done.complete();
        } else {
          final file = MemoketProtocol.parseListEntry(data);
          if (file != null) _listed?.add(file);
        }
      case MemoketProtocol.opDownload:
        if (MemoketProtocol.isDownloadComplete(data)) {
          final file = _downloadingFile;
          final buffer = _downloadBuffer;
          if (file != null &&
              buffer != null &&
              !_downloadMeetsExpectation(buffer, file)) {
            _armDownloadStall();
            break;
          }
          final done = _downloadDone;
          if (done != null && !done.isCompleted) done.complete();
        }
      case MemoketProtocol.opDelete:
        final ack = _deleteAck;
        if (ack != null && !ack.isCompleted) {
          ack.complete(MemoketProtocol.isDeleteAck(data));
        }
    }
  }

  void _handleLiveAudio(List<int> data) {
    if (_downloadBuffer != null) return;
    final payload = MemoketProtocol.liveOpusFrame(data);
    if (payload == null) return;
    // The start opcode can be missed after a background reconnect. Live frames
    // are proof the Gem is recording — treat it as live so list/battery/handshake
    // writes cannot stop the take.
    if (!_deviceLive && !recording) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'live_audio_inferred',
        details: const <String, Object?>{
          'hint': 'Gem is recording; control writes are held.',
        },
      );
    }
    _markDeviceLive();
    if (_pendingHardwareStart && !recording) {
      // Audio is here, so the earlier start notify was a real take.
      _clearPendingHardwareStart();
      _emitDeviceControl(WearableControlCodes.startRecording);
    }
    for (final frame in MemoketProtocol.splitPackedOpusFrames(payload)) {
      _liveEmittedFrames += 1;
      audioBytes.add(frame);
    }
    final liveName = _liveFilename;
    if (liveName != null && _liveEmittedFrames > 0) {
      if (_liveCoverage.fileId != liveName) _persistedLiveSeconds = -1;
      _liveCoverage.frame(liveName, DateTime.now());
      final seconds = _liveCoverageSeconds;
      // Persisted as it grows, not only at the end: a take interrupted by a
      // crash or a dead battery must still be able to say how much of it the
      // phone already holds.
      if (seconds >= _persistedLiveSeconds + 10 || _persistedLiveSeconds < 0) {
        _persistedLiveSeconds = seconds;
        unawaited(_rememberLiveIngested(liveName, seconds));
      }
    }
  }

  /// Seconds of live audio actually received for the current device take.
  int get _liveCoverageSeconds => _liveCoverage.seconds;

  /// How long the take has been running, by the clock, or null when this phone
  /// did not see it start — joining a take already in progress says nothing
  /// about the minutes recorded before the phone was listening.
  int? get _takeSeconds {
    final started = _takeStartedAt;
    if (started == null) return null;
    return DateTime.now().difference(started).inSeconds;
  }

  Future<void> _rememberLiveIngested(String fileId, int liveSeconds) async {
    await WearableIngestedFiles.remember(device.id, fileId, liveSeconds);
  }

  void _emitDeviceControl(int code) {
    if (buttonEvents.isClosed) return;
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      code == WearableControlCodes.startRecording
          ? 'hardware_start'
          : code == WearableControlCodes.stopRecording
          ? 'hardware_stop'
          : 'hardware_control',
      details: <String, Object?>{
        'code': code,
        'recording': recording,
        'deviceLive': _deviceLive,
      },
    );
    buttonEvents.add(<int>[code]);
  }

  void _holdHardwareStart([Duration window = _hardwareStartHoldoff]) {
    final until = DateTime.now().add(window);
    final current = _holdHardwareStartUntil;
    // Never shorten a holdoff that is already running: the stop window has to
    // outlive the short one every control write arms.
    if (current != null && current.isAfter(until)) return;
    _holdHardwareStartUntil = until;
  }

  /// A start notify arrived unprompted and is waiting for live audio to
  /// confirm the Gem really is recording.
  bool _pendingHardwareStart = false;
  Timer? _pendingHardwareStartTimer;

  /// How long an unconfirmed start notify may hold the device "live".
  static const Duration _hardwareStartConfirm = Duration(seconds: 5);

  void _armPendingHardwareStart() {
    _pendingHardwareStart = true;
    _pendingHardwareStartTimer?.cancel();
    _pendingHardwareStartTimer = Timer(_hardwareStartConfirm, () {
      _pendingHardwareStartTimer = null;
      if (!_pendingHardwareStart) return;
      // No audio ever followed, so nothing was recording. Releasing the live
      // flag matters as much as never reporting the start: while it is set,
      // every automatic sweep skips the device and its files stay there.
      _pendingHardwareStart = false;
      if (!recording) _deviceLive = false;
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'hardware_start_unconfirmed',
        details: <String, Object?>{
          'hint': 'Start notify carried no audio; treated as a control echo.',
        },
      );
    });
  }

  void _clearPendingHardwareStart() {
    _pendingHardwareStart = false;
    _pendingHardwareStartTimer?.cancel();
    _pendingHardwareStartTimer = null;
  }

  bool get _holdingHardwareStart =>
      _holdHardwareStartUntil != null &&
      DateTime.now().isBefore(_holdHardwareStartUntil!);

  void _handleFileChunk(List<int> data) {
    final buffer = _downloadBuffer;
    if (buffer == null || data.isEmpty) return;
    buffer.add(Uint8List.fromList(data));
    _armDownloadStall();
    _publishFileProgress(_chunkBytes(buffer));
    _finishDownloadIfComplete();
  }

  /// The Gem's 0x02 complete notify can lag a large copy. Stop waiting once
  /// the announced payload has actually arrived.
  void _finishDownloadIfComplete() {
    final file = _downloadingFile;
    final buffer = _downloadBuffer;
    final done = _downloadDone;
    if (file == null || buffer == null || done == null || done.isCompleted) {
      return;
    }
    if (file.byteLength > 0 && _chunkBytes(buffer) >= file.byteLength) {
      done.complete();
    }
  }

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
    bool Function(String fileId)? shouldTransfer,
  }) async {
    if (recording || _deviceLive) return 0;
    _drainCancelled = false;
    _lastFilesListed = 0;
    _lastSynced = 0;
    _lastFailed = 0;
    if (!_sawControl) {
      await _handshake();
    }
    if (!_sawControl) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_no_response',
        level: 'warning',
        details: const <String, Object?>{
          'hint':
              'Control handshake was not acknowledged; the Gem accepts no commands.',
        },
      );
      throw StateError(
        'The device did not answer the connection handshake. Reconnect it and '
        'try syncing again.',
      );
    }
    await WearableIngestedFiles.hydrate(device.id);
    final listed = MemoketProtocol.uniqueStoredFiles(await _listStoredFiles());
    // Only a file the live stream actually covered is redundant. One that was
    // live for part of its length is transferred in full: the server drops
    // audio it has already heard from this device, and no client-side guess is
    // worth deleting the only copy of the rest.
    final already = listed
        .where(
          (file) => WearableIngestedFiles.covers(
            device.id,
            file.id,
            file.durationSeconds,
          ),
        )
        .toList();
    for (final file in already) {
      if (shouldTransfer != null && !shouldTransfer(file.id)) continue;
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_skip_already_ingested',
        details: <String, Object?>{'id': file.id},
      );
      await _deleteStoredFile(file);
    }
    final files = listed
        .where(
          (file) => !WearableIngestedFiles.covers(
            device.id,
            file.id,
            file.durationSeconds,
          ),
        )
        .toList();
    _lastFilesListed = files.length;
    // An idle poll every few seconds is the healthy steady state, and recording
    // each one evicted everything else from the diagnostic ring — a report from
    // a stuck phone held nothing but empty listings. Report the first idle poll,
    // then stay quiet until something actually changes.
    final idleSync = files.isEmpty && already.isEmpty && _sawControl;
    final reportSync = !idleSync || !_idleSyncReported;
    _idleSyncReported = idleSync;
    if (reportSync) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_sync_listed',
        details: <String, Object?>{
          'files': files.length,
          'deviceResponded': _sawControl,
          'entries': files
              .map(
                (file) => <String, Object?>{
                  'id': file.id,
                  'durationSeconds': file.durationSeconds,
                  'bytes': file.byteLength,
                },
              )
              .toList(growable: false),
        },
      );
    }
    var count = 0;
    var failed = 0;
    _syncFileCount = files.length;
    _syncFileIndex = 0;
    _syncRemaining = files;
    _publishProgress(
      transferred: 0,
      total: files.length,
      pending: files,
      completeFraction: files.isEmpty ? 1.0 : 0.0,
      force: true,
    );
    for (var i = 0; i < files.length; i += 1) {
      if (_drainCancelled) break;
      final file = files[i];
      if (shouldTransfer != null && !shouldTransfer(file.id)) {
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'memoket_skip_unselected',
          details: <String, Object?>{'id': file.id},
        );
        continue;
      }
      _syncFileIndex = i;
      _syncExpectedBytes = MemoketProtocol.expectedAudioBytes(
        durationSeconds: file.durationSeconds,
        announcedBytes: file.byteLength,
      );
      _syncRemaining = files.sublist(i);
      _publishFileProgress(0, force: true);
      try {
        final chunks = await _downloadStoredFile(file);
        final frames = <Uint8List>[
          for (final chunk in chunks)
            ...MemoketProtocol.splitPackedOpusFrames(chunk),
        ];
        final opusMs = MemoketProtocol.opusFramesDurationMs(frames);
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'memoket_file_wrapped',
          details: <String, Object?>{
            'id': file.id,
            'listedSeconds': file.durationSeconds,
            'announcedBytes': file.byteLength,
            'notifyCount': chunks.length,
            'frameCount': frames.length,
            'opusDurationMs': opusMs,
            'toc': frames.isEmpty ? null : frames.first.first,
          },
        );
        final bytes = MemoketProtocol.wrapOpusFramesAsOgg(frames);
        if (bytes.length < minBytes) continue;
        await onRecording(
          WearableRecording(
            id: file.id,
            bytes: bytes,
            contentType: file.contentType,
            filename: file.importFilename,
            capturedAt: file.capturedAt,
          ),
        );
        // Transferred in full, so the phone now holds every second of it and
        // the device's copy can go.
        await _rememberLiveIngested(file.id, file.durationSeconds);
        await _deleteStoredFile(file);
        count += 1;
        _publishProgress(
          transferred: i + 1,
          total: files.length,
          pending: files.sublist(i + 1),
          completeFraction: (i + 1) / files.length,
          force: true,
        );
      } catch (error) {
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'memoket_file_failed',
          level: 'warning',
          details: <String, Object?>{
            'id': file.id,
            'error': error.toString(),
            'listedSeconds': file.durationSeconds,
            'announcedBytes': file.byteLength,
            'expectedBytes': _syncExpectedBytes,
          },
        );
        failed += 1;
      }
    }
    _lastSynced = count;
    _lastFailed = failed;
    _syncExpectedBytes = 0;
    _syncRemaining = const <MemoketStoredFile>[];
    _publishProgress(
      transferred: count,
      total: files.length,
      pending: const [],
      completeFraction: files.isEmpty ? 1.0 : count / files.length,
      force: true,
    );
    if (reportSync) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'memoket_sync_done',
        details: <String, Object?>{
          'synced': count,
          'available': files.length,
          'failed': failed,
          'cancelled': _drainCancelled,
        },
      );
    }
    if (failed > 0) {
      throw StateError(
        count == 0
            ? 'Found $failed recording(s) on the device but none could be '
                  'transferred. Keep the device close and try again.'
            : 'Synced $count recording(s), but $failed stayed on the device. '
                  'Keep it close and try again.',
      );
    }
    return count;
  }

  @override
  Future<WearableSyncProgress?> peekPending() async {
    if (recording || _deviceLive) return null;
    try {
      final files = MemoketProtocol.uniqueStoredFiles(await _listStoredFiles());
      return WearableSyncProgress(
        pendingSeconds: files.fold<int>(
          0,
          (sum, file) => sum + file.durationSeconds,
        ),
        total: files.length,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> cancelStoredSync() async {
    _drainCancelled = true;
    _stopDownloadStall();
    final done = _downloadDone;
    _downloadBuffer = null;
    _downloadDone = null;
    _downloadingFile = null;
    if (done != null && !done.isCompleted) {
      done.completeError(StateError('Memoket sync cancelled.'));
    }
  }

  Future<List<MemoketStoredFile>> _listStoredFiles() async {
    final collector = <MemoketStoredFile>[];
    final done = Completer<void>();
    _listed = collector;
    _listDone = done;
    try {
      await _write(MemoketProtocol.listFiles);
      await done.future.timeout(_listTimeout, onTimeout: () {});
    } finally {
      _listed = null;
      _listDone = null;
    }
    return collector;
  }

  Future<List<Uint8List>> _downloadStoredFile(MemoketStoredFile file) async {
    List<Uint8List> best = const <Uint8List>[];
    var bestBytes = 0;
    final expected = MemoketProtocol.expectedAudioBytes(
      durationSeconds: file.durationSeconds,
      announcedBytes: file.byteLength,
    );
    Object? lastError;
    for (var attempt = 0; attempt < _downloadAttempts; attempt += 1) {
      final buffer = <Uint8List>[];
      final done = Completer<void>();
      _downloadBuffer = buffer;
      _downloadDone = done;
      _downloadingFile = file;
      _armDownloadStall();
      try {
        await _write(
          MemoketProtocol.fileCommand(
            MemoketProtocol.opDownload,
            file.filename,
          ),
        );
        await done.future.timeout(MemoketProtocol.downloadBudget(expected));
        for (var i = 0; i < 40 && _chunkBytes(buffer) < expected; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } catch (error) {
        lastError = error;
      } finally {
        _stopDownloadStall();
        _downloadBuffer = null;
        _downloadDone = null;
        _downloadingFile = null;
      }
      final bytes = _chunkBytes(buffer);
      if (bytes > bestBytes) {
        best = buffer;
        bestBytes = bytes;
      }
      if (_downloadMeetsExpectation(best, file)) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (!_downloadMeetsExpectation(best, file)) {
      throw StateError(
        lastError is TimeoutException
            ? 'Memoket download stalled at $bestBytes/$expected bytes for ${file.id}.'
            : 'Memoket download incomplete after $_downloadAttempts attempts: '
                  '$bestBytes/$expected bytes',
      );
    }
    if (best.isEmpty) {
      throw StateError('Memoket download produced no audio for ${file.id}.');
    }
    return best;
  }

  bool _downloadMeetsExpectation(
    List<Uint8List> buffer,
    MemoketStoredFile file,
  ) {
    final bytes = _chunkBytes(buffer);
    if (bytes <= 0) return false;
    final expected = MemoketProtocol.expectedAudioBytes(
      durationSeconds: file.durationSeconds,
      announcedBytes: file.byteLength,
    );
    return expected <= 0 || bytes >= (expected * 0.8).round();
  }

  void _armDownloadStall() {
    _downloadStall?.cancel();
    _downloadStall = Timer(_downloadStallTimeout, () {
      final done = _downloadDone;
      if (done != null && !done.isCompleted) {
        done.completeError(TimeoutException('Memoket download stalled'));
      }
    });
  }

  void _stopDownloadStall() {
    _downloadStall?.cancel();
    _downloadStall = null;
  }

  Future<bool> _deleteStoredFile(MemoketStoredFile file) async {
    final ack = Completer<bool>();
    _deleteAck = ack;
    var ok = false;
    try {
      await _write(
        MemoketProtocol.fileCommand(MemoketProtocol.opDelete, file.filename),
      );
      ok = await ack.future.timeout(_deleteTimeout, onTimeout: () => false);
    } catch (_) {
      ok = false;
    } finally {
      if (identical(_deleteAck, ack)) _deleteAck = null;
    }
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      ok ? 'memoket_deleted' : 'memoket_delete_unacked',
      level: ok ? 'info' : 'warning',
      details: <String, Object?>{'id': file.id},
    );
    return ok;
  }

  Future<List<int>?> _command(Uint8List value, int opcode) async {
    final reply = Completer<List<int>>();
    _reply = reply;
    _replyOpcode = opcode;
    try {
      await _write(value);
      return await reply.future.timeout(_replyTimeout);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (identical(_reply, reply)) {
        _reply = null;
        _replyOpcode = null;
      }
    }
  }

  Future<void> _write(List<int> value) {
    final previous = _writeQueue;
    final gate = Completer<void>();
    _writeQueue = gate.future;
    return () async {
      await previous;
      try {
        await _writeNow(value);
      } finally {
        gate.complete();
      }
    }();
  }

  Future<void> _writeNow(List<int> value) async {
    Object? lastError;
    for (var attempt = 0; attempt < _writeAttempts; attempt += 1) {
      try {
        await transport.writeCharacteristic(
          WearableDeviceUuids.memoketService,
          WearableDeviceUuids.memoketControlWrite,
          value,
        );
        await Future<void>.delayed(_commandGap);
        return;
      } catch (error) {
        lastError = error;
        if (_shouldTryWriteWithoutResponse(error)) {
          try {
            await transport.writeCharacteristic(
              WearableDeviceUuids.memoketService,
              WearableDeviceUuids.memoketControlWrite,
              value,
              withoutResponse: true,
            );
            await Future<void>.delayed(_commandGap);
            return;
          } catch (fallback) {
            lastError = fallback;
          }
        }
        await Future<void>.delayed(_writeRetryDelay * (attempt + 1));
      }
    }
    throw StateError(_friendlyWriteError(lastError));
  }

  static bool _shouldTryWriteWithoutResponse(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('withresponse') ||
        text.contains('does not support write') ||
        text.contains('writevalue') ||
        text.contains('channel');
  }

  static String _friendlyWriteError(Object? error) {
    final text = error?.toString() ?? '';
    if (text.toLowerCase().contains('channel') ||
        text.toLowerCase().contains('writevalue') ||
        text.toLowerCase().contains('disconnected')) {
      return 'Could not reach the Gem over Bluetooth. Keep it close, close the '
          'official Memoket app, and reconnect.';
    }
    return 'The Gem did not accept a command. Keep it close and try again.';
  }

  void _publishFileProgress(int bytes, {bool force = false}) {
    if (_syncFileCount <= 0) return;
    final expected = _syncExpectedBytes <= 0 ? bytes : _syncExpectedBytes;
    final fileFrac = expected <= 0 ? 0.0 : (bytes / expected).clamp(0.0, 0.99);
    final overall = (_syncFileIndex + fileFrac) / _syncFileCount;
    _publishProgress(
      transferred: _syncFileIndex,
      total: _syncFileCount,
      pending: _syncRemaining,
      completeFraction: overall,
      force: force,
    );
  }

  void _publishProgress({
    required int transferred,
    required int total,
    required List<MemoketStoredFile> pending,
    double? completeFraction,
    bool force = false,
  }) {
    if (_progress.isClosed) return;
    final fraction =
        completeFraction ?? (total > 0 ? transferred / total : null);
    final now = DateTime.now();
    if (!force &&
        fraction != null &&
        _lastPublishedFraction >= 0 &&
        (fraction - _lastPublishedFraction).abs() < 0.02 &&
        _lastProgressAt != null &&
        now.difference(_lastProgressAt!) < _progressMinInterval) {
      return;
    }
    _lastPublishedFraction = fraction ?? _lastPublishedFraction;
    _lastProgressAt = now;
    _progress.add(
      WearableSyncProgress(
        transferred: transferred,
        total: total,
        pendingSeconds: pending.fold<int>(
          0,
          (sum, file) => sum + file.durationSeconds,
        ),
        completeFraction: completeFraction,
      ),
    );
  }

  static int _chunkBytes(List<Uint8List> frames) =>
      frames.fold<int>(0, (sum, frame) => sum + frame.length);

  @override
  Future<void> dispose() async {
    await super.dispose();
    _clearPendingHardwareStart();
    final reply = _reply;
    _reply = null;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(StateError('disconnected'));
    }
    final list = _listDone;
    _listDone = null;
    if (list != null && !list.isCompleted) list.complete();
    _stopDownloadStall();
    final download = _downloadDone;
    _downloadBuffer = null;
    _downloadDone = null;
    _downloadingFile = null;
    if (download != null && !download.isCompleted) {
      download.completeError(StateError('Memoket disconnected during sync.'));
    }
    final delete = _deleteAck;
    _deleteAck = null;
    if (delete != null && !delete.isCompleted) delete.complete(false);
    final started = _started;
    _started = null;
    if (started != null && !started.isCompleted) {
      started.completeError(StateError('disconnected'));
    }
    final stopped = _stopped;
    _stopped = null;
    if (stopped != null && !stopped.isCompleted) stopped.complete();
    final liveJoined = _liveJoined;
    _liveJoined = null;
    if (liveJoined != null && !liveJoined.isCompleted) liveJoined.complete();
    await _progress.close();
  }
}
