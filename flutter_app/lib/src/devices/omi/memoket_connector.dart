import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import 'base_connector.dart';
import 'device_models.dart';
import 'memoket_protocol.dart';
import 'offline_sync.dart';

/// Memoket Gem BLE recorder.
///
/// Protocol confirmed against official-app HCI captures:
/// - Handshake: ping, battery, firmware, clock, storage.
/// - Remote start `01 00 00` / stop `02 00` also starts and stops on-device
///   recording; live Opus frames arrive on [WearableDeviceUuids.memoketAudioNotify].
/// - Offline files: `03` lists, `04 <name>` downloads on the file-notify
///   characteristic, `05 <name>` deletes only after durable ingest.
class MemoketConnector extends WearableConnector with WearableOfflineSync {
  MemoketConnector({required super.device, required super.transport});

  static const Duration _replyTimeout = Duration(milliseconds: 800);
  static const Duration _listTimeout = Duration(seconds: 4);
  static const Duration _startTimeout = Duration(seconds: 3);
  static const Duration _stopTimeout = Duration(seconds: 4);
  static const Duration _downloadTimeout = Duration(seconds: 90);
  static const Duration _deleteTimeout = Duration(seconds: 3);
  static const int _downloadAttempts = 3;
  static const Duration _commandGap = Duration(milliseconds: 40);
  static const Duration _hardwareStartHoldoff = Duration(seconds: 3);

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
  final Set<String> _liveIngestedIds = <String>{};
  int _lastFilesListed = 0;
  int _lastSynced = 0;
  int _lastFailed = 0;

  Completer<List<int>>? _reply;
  int? _replyOpcode;
  Completer<void>? _listDone;
  Completer<void>? _downloadDone;
  Completer<bool>? _deleteAck;
  Completer<String>? _started;
  Completer<void>? _stopped;
  List<MemoketStoredFile>? _listed;
  List<Uint8List>? _downloadBuffer;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opus;

  @override
  bool get supportsConcurrentCapture => false;

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
    await _handshake();
  }

  Future<void> _handshake() async {
    await _command(MemoketProtocol.ping, MemoketProtocol.opPing);
    final battery = await readBatteryLevel();
    if (battery >= 0) batteryLevels.add(battery);
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
    final reply = await _command(
      MemoketProtocol.batteryQuery,
      MemoketProtocol.opBattery,
    );
    final level = reply == null ? null : MemoketProtocol.batteryLevel(reply);
    if (level != null) _lastBattery = level;
    return _lastBattery;
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
    _holdHardwareStart();
    _liveFilename = null;
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
    if (filename != null) {
      _liveIngestedIds.add(filename);
      await _deleteStoredFile(
        MemoketStoredFile(
          filename: filename,
          durationSeconds: 0,
          byteLength: 0,
        ),
      );
    }
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
        final level = MemoketProtocol.batteryLevel(data);
        if (level != null) {
          _lastBattery = level;
          batteryLevels.add(level);
        }
      case MemoketProtocol.opFirmware:
        _firmware = MemoketProtocol.firmwareVersion(data);
      case MemoketProtocol.opRecordStart:
        _deviceLive = true;
        final name = MemoketProtocol.recordingFilename(data);
        if (name != null) _liveFilename = name;
        final started = _started;
        if (started != null && !started.isCompleted) {
          started.complete(name ?? '');
        } else if (!recording && !_holdingHardwareStart) {
          _emitDeviceControl(WearableControlCodes.startRecording);
        }
      case MemoketProtocol.opRecordStop:
        _deviceLive = false;
        _holdHardwareStart();
        final name = MemoketProtocol.recordingFilename(data);
        if (name != null) _liveFilename = name;
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
    if ((!recording && !_deviceLive) || _downloadBuffer != null) return;
    final frame = MemoketProtocol.liveOpusFrame(data);
    if (frame != null) audioBytes.add(frame);
  }

  void _emitDeviceControl(int code) {
    if (buttonEvents.isClosed) return;
    buttonEvents.add(<int>[code]);
  }

  void _holdHardwareStart() {
    _holdHardwareStartUntil = DateTime.now().add(_hardwareStartHoldoff);
  }

  bool get _holdingHardwareStart =>
      _holdHardwareStartUntil != null &&
      DateTime.now().isBefore(_holdHardwareStartUntil!);

  void _handleFileChunk(List<int> data) {
    final buffer = _downloadBuffer;
    if (buffer == null || data.isEmpty) return;
    buffer.add(Uint8List.fromList(data));
  }

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
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
    final files = (await _listStoredFiles())
        .where((file) => !_liveIngestedIds.contains(file.id))
        .toList();
    _lastFilesListed = files.length;
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      'memoket_sync_listed',
      details: <String, Object?>{
        'files': files.length,
        'deviceResponded': _sawControl,
      },
    );
    var count = 0;
    var failed = 0;
    for (var i = 0; i < files.length; i += 1) {
      if (_drainCancelled) break;
      final file = files[i];
      _publishProgress(transferred: i, total: files.length, pending: files);
      try {
        final frames = await _downloadStoredFile(file);
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
        await _deleteStoredFile(file);
        count += 1;
      } catch (error) {
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'memoket_file_failed',
          level: 'warning',
          details: <String, Object?>{'id': file.id, 'error': error.toString()},
        );
        failed += 1;
      }
    }
    _lastSynced = count;
    _lastFailed = failed;
    _publishProgress(
      transferred: count,
      total: files.length,
      pending: const [],
    );
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
    if (count == 0 && failed > 0) {
      throw StateError(
        'Found $failed recording(s) on the device but none could be '
        'transferred. Keep the device close and try again.',
      );
    }
    return count;
  }

  @override
  Future<WearableSyncProgress?> peekPending() async {
    if (recording || _deviceLive) return null;
    try {
      final files = await _listStoredFiles();
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
    final done = _downloadDone;
    _downloadBuffer = null;
    _downloadDone = null;
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
    for (var attempt = 0; attempt < _downloadAttempts; attempt += 1) {
      final buffer = <Uint8List>[];
      final done = Completer<void>();
      _downloadBuffer = buffer;
      _downloadDone = done;
      try {
        await _write(
          MemoketProtocol.fileCommand(
            MemoketProtocol.opDownload,
            file.filename,
          ),
        );
        await done.future.timeout(_downloadTimeout);
        for (
          var i = 0;
          i < 40 && _chunkBytes(buffer) < file.byteLength;
          i += 1
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } finally {
        _downloadBuffer = null;
        _downloadDone = null;
      }
      final bytes = _chunkBytes(buffer);
      if (bytes > bestBytes) {
        best = buffer;
        bestBytes = bytes;
      }
      if (file.byteLength <= 0 || bestBytes >= file.byteLength) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (file.byteLength > 0 && bestBytes < file.byteLength) {
      throw StateError(
        'Memoket download incomplete after $_downloadAttempts attempts: '
        '$bestBytes/${file.byteLength} bytes',
      );
    }
    if (best.isEmpty) {
      throw StateError('Memoket download produced no audio for ${file.id}.');
    }
    return best;
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

  Future<void> _write(List<int> value) async {
    await transport.writeCharacteristic(
      WearableDeviceUuids.memoketService,
      WearableDeviceUuids.memoketControlWrite,
      value,
    );
    await Future<void>.delayed(_commandGap);
  }

  void _publishProgress({
    required int transferred,
    required int total,
    required List<MemoketStoredFile> pending,
  }) {
    if (_progress.isClosed) return;
    _progress.add(
      WearableSyncProgress(
        transferred: transferred,
        total: total,
        pendingSeconds: pending.fold<int>(
          0,
          (sum, file) => sum + file.durationSeconds,
        ),
      ),
    );
  }

  static int _chunkBytes(List<Uint8List> frames) =>
      frames.fold<int>(0, (sum, frame) => sum + frame.length);

  @override
  Future<void> dispose() async {
    await super.dispose();
    final reply = _reply;
    _reply = null;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(StateError('disconnected'));
    }
    final list = _listDone;
    _listDone = null;
    if (list != null && !list.isCompleted) list.complete();
    final download = _downloadDone;
    _downloadBuffer = null;
    _downloadDone = null;
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
    await _progress.close();
  }
}
