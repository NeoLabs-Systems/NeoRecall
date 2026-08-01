import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import 'base_connector.dart';
import 'device_models.dart';
import 'offline_sync.dart';

/// A recording held in HeyPocket on-board flash, addressed by its capture date
/// and per-day file id (both echoed verbatim to the download/delete commands).
class HeyPocketStoredFile {
  const HeyPocketStoredFile({required this.date, required this.fileId});

  /// `YYYY-MM-DD` as reported by the device.
  final String date;

  /// Device-assigned file id (a `YYYYMMDDHHMMSS`-style stamp), echoed verbatim
  /// to the upload/delete commands.
  final String fileId;

  String get id => '$date/$fileId';
  String get contentType => 'audio/mpeg';
  String get filename => 'heypocket-$date-$fileId.mp3';
  /// When the device recorded this file, in UTC.
  ///
  /// The time lives in [fileId] (`YYYYMMDDHHMMSS`), not in [date]. Using the
  /// date alone stamped every recording of a day at local midnight — which
  /// converts to the *previous* day in UTC east of Greenwich, and collapsed
  /// every recording of one day onto a single instant. Both made a synced
  /// recording impossible to find on the timeline.
  DateTime? get capturedAt {
    final stamp = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})')
        .firstMatch(fileId);
    if (stamp != null) {
      // The device stamps its own local wall clock, which the sync preamble
      // (`APP&T&…`) sets from this phone — so it is read back as local time.
      final local = DateTime(
        int.parse(stamp.group(1)!),
        int.parse(stamp.group(2)!),
        int.parse(stamp.group(3)!),
        int.parse(stamp.group(4)!),
        int.parse(stamp.group(5)!),
        int.parse(stamp.group(6)!),
      );
      return local.toUtc();
    }
    // Firmware that numbers files sequentially instead of by timestamp: fall
    // back to the day it was listed under, at local midnight.
    return DateTime.tryParse(date)?.toUtc();
  }
}

/// HeyPocket (also labelled PKT01 / "Pocket AI") BLE recorder.
///
/// Protocol confirmed against a real PKT01 firmware capture:
/// - The device ignores every command until an **`APP&SK&<key>` session-key
///   handshake** succeeds (`MCU&SK&OK`). This was the single reason earlier
///   builds saw the device stay silent.
/// - Control replies (`MCU&…` ASCII) and binary MP3 file data arrive on the two
///   notify characteristics, but firmware variants disagree on which is which
///   (the captured unit puts control on `…a3` and data on `…a1`, the reverse of
///   the profile's names). So BOTH notify endpoints are subscribed and every
///   payload is routed by **content**: an ASCII `MCU&/APP&/BLE&/SYS&` frame is
///   control, anything else is audio/file data.
/// - Offline files: `APP&LIST&<date>` → zero or more `MCU&F&<date>&<id>&<idx>`
///   terminated by `MCU&LIST&<count>`; download `APP&U&<date>&<id>` →
///   `MCU&U&<size>` then MP3 chunks then `MCU&OFF`.
class HeyPocketConnector extends WearableConnector with WearableOfflineSync {
  HeyPocketConnector({required super.device, required super.transport});

  // Fixed session key used by the official "Pocket" app; the firmware validates
  // it before accepting any other command. Required for the device to respond.
  static const String _sessionKey = '3TMd6HawHvRl2nhg';

  static const Duration _authTimeout = Duration(seconds: 5);
  static const Duration _batteryTimeout = Duration(seconds: 5);
  static const int _syncLookbackDays = 7;
  // Each day's listing is terminated explicitly by MCU&LIST&<count>; this bounds
  // the wait if the device never answers a given day.
  static const Duration _listTimeout = Duration(seconds: 4);
  static const Duration _downloadTimeout = Duration(seconds: 90);
  // How many times to re-request a file whose transfer arrived short (dropped
  // notifications) before giving up and leaving it on the device for next sweep.
  static const int _downloadAttempts = 4;
  static const Duration _deleteTimeout = Duration(seconds: 3);
  static const Duration _commandGap = Duration(milliseconds: 120);
  static const List<String> _controlPrefixes = <String>[
    'MCU&',
    'APP&',
    'BLE&',
    'SYS&',
  ];
  static const String _batteryResponsePrefix = 'MCU&BAT&';

  bool _authenticated = false;
  /// Set by cancelStoredSync so the sweep stops between files. Aborting only
  /// the in-flight download let the loop continue with the next file, so a
  /// cancel issued to free the channel for live capture never actually ended
  /// the sweep.
  bool _drainCancelled = false;
  int _lastFilesListed = 0;
  int _lastSynced = 0;
  int _lastFailed = 0;
  Completer<bool>? _authRequest;
  Completer<int>? _batteryRequest;
  // True once the device has answered ANY MCU&… frame this sweep — lets a sync
  // distinguish "no files" from "device never replied".
  bool _sawControlResponse = false;
  // Offline-sync state. A non-null _downloadBuffer routes binary payloads to the
  // active download instead of the live-capture stream.
  List<int>? _downloadBuffer;
  // Byte count the device announces for the current download (MCU&U&<size>);
  // used to wait out trailing MP3 chunks that can arrive just after MCU&OFF.
  int? _expectedDownloadBytes;
  Completer<void>? _downloadDone;
  Completer<void>? _listDone;
  Completer<bool>? _deleteAck;
  void Function(HeyPocketStoredFile file)? _onFileEntry;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.mp3;

  @override
  Future<void> onConnected() async {
    // Subscribe BOTH notify characteristics and route by content (see class
    // doc): the firmware's control/data channel assignment is not fixed.
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.heyPocketService,
        WearableDeviceUuids.heyPocketControlNotify,
      )).listen(_handleNotification),
    );
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.heyPocketService,
        WearableDeviceUuids.heyPocketAudioNotify,
      )).listen(_handleNotification),
    );
    // The device ignores everything until the session key is accepted.
    final authed = await _authenticate();
    if (!authed) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'heypocket_auth_failed',
        level: 'warning',
        details: <String, Object?>{
          'hint': 'No MCU&SK&OK for APP&SK; the device will ignore commands.',
        },
      );
    }
    await _syncTime();
    try {
      await _writeControl('APP&BAT');
    } catch (_) {
      // Battery is informational; the device still records without it.
    }
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    final text = _asControlFrame(data);
    if (text != null) {
      _handleControlFrame(text);
    } else {
      _handleBinary(data);
    }
  }

  /// Routes a binary (non-control) payload. An in-flight offline download claims
  /// it; otherwise it is live-capture audio (only while recording). This keeps
  /// the two paths from ever cross-feeding each other.
  void _handleBinary(List<int> data) {
    final buffer = _downloadBuffer;
    if (buffer != null) {
      buffer.addAll(data);
    } else if (recording) {
      audioBytes.add(data);
    }
  }

  /// Returns the decoded control string when [data] is a printable-ASCII frame
  /// beginning with a documented prefix, otherwise null (i.e. binary audio).
  /// MP3 frames start with a 0xFF sync byte, so they never satisfy this test.
  String? _asControlFrame(List<int> data) {
    for (final byte in data) {
      if (byte < 0x20 || byte > 0x7e) return null;
    }
    final text = ascii.decode(data);
    for (final prefix in _controlPrefixes) {
      if (text.startsWith(prefix)) return text;
    }
    return null;
  }

  void _handleControlFrame(String text) {
    if (text.startsWith('MCU&')) _sawControlResponse = true;
    if (text.startsWith('MCU&SK&OK')) {
      _authenticated = true;
      final request = _authRequest;
      if (request != null && !request.isCompleted) request.complete(true);
      return;
    }
    if (text.startsWith(_batteryResponsePrefix)) {
      final level = int.tryParse(
        text.substring(_batteryResponsePrefix.length).trim(),
      );
      if (level != null) {
        batteryLevels.add(level);
        final request = _batteryRequest;
        if (request != null && !request.isCompleted) request.complete(level);
      }
      return;
    }
    // Offline-sync responses: file entry, end-of-list, end-of-download, del ack.
    if (text.startsWith('MCU&F&')) {
      final file = _parseFileEntry(text);
      if (file != null) _onFileEntry?.call(file);
      return;
    }
    if (text.startsWith('MCU&LIST&')) {
      final done = _listDone;
      if (done != null && !done.isCompleted) done.complete();
      return;
    }
    if (text.startsWith('MCU&U&')) {
      // Download size announcement (distinct from MCU&USB&…).
      _expectedDownloadBytes = int.tryParse(
        text.substring('MCU&U&'.length).trim(),
      );
      return;
    }
    if (text.startsWith('MCU&OFF')) {
      final done = _downloadDone;
      if (done != null && !done.isCompleted) done.complete();
      return;
    }
    if (text.startsWith('MCU&D')) {
      final ack = _deleteAck;
      if (ack != null && !ack.isCompleted) ack.complete(true);
      return;
    }
    // Other acknowledgements (MCU&STE / MCU&STA / MCU&STO / MCU&REC …) are
    // status only and need no action here.
  }

  /// Parses `MCU&F&<date>&<fileId>&<index>`. The list does not report a byte
  /// size (that arrives as `MCU&U&<size>` at download time), so none is stored.
  HeyPocketStoredFile? _parseFileEntry(String text) {
    final parts = text.split('&');
    if (parts.length < 4) return null;
    final date = parts[2].trim();
    final fileId = parts[3].trim();
    if (date.isEmpty || fileId.isEmpty) return null;
    return HeyPocketStoredFile(date: date, fileId: fileId);
  }

  /// Sends the session key and waits for `MCU&SK&OK`. Idempotent per connection.
  Future<bool> _authenticate() async {
    if (_authenticated) return true;
    final existing = _authRequest;
    if (existing != null) {
      return existing.future.timeout(_authTimeout, onTimeout: () => false);
    }
    final request = Completer<bool>();
    _authRequest = request;
    try {
      await _writeControl('APP&SK&$_sessionKey');
      return await request.future.timeout(_authTimeout);
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    } finally {
      if (identical(_authRequest, request)) _authRequest = null;
    }
  }

  @override
  Future<int> readBatteryLevel() async {
    if (!await _authenticate()) return -1;
    final existing = _batteryRequest;
    if (existing != null) {
      return existing.future.timeout(_batteryTimeout, onTimeout: () => -1);
    }
    final request = Completer<int>();
    _batteryRequest = request;
    try {
      await _writeControl('APP&BAT');
      return await request.future.timeout(_batteryTimeout);
    } on TimeoutException {
      return -1;
    } catch (_) {
      return -1;
    } finally {
      if (identical(_batteryRequest, request)) _batteryRequest = null;
    }
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    // The firmware answers nothing until the session key is accepted, so a
    // failed handshake means APP&STA cannot start anything. Reporting
    // "recording" then would show a live capture that can never produce audio.
    if (!await _authenticate()) {
      throw StateError(
        'The device did not answer the connection handshake, so recording could '
        'not be started. Reconnect it and try again.',
      );
    }
    recording = true;
    try {
      // Binary MP3 then flows on a notify channel and is routed to audioBytes
      // (both channels are already subscribed from onConnected).
      await _writeControl('APP&STA');
    } catch (_) {
      recording = false;
      rethrow;
    }
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    recording = false;
    try {
      await _writeControl('APP&STO');
    } catch (_) {
      // Best-effort; the device stops streaming once notifications are dropped.
    }
  }

  // --- Offline sync (WearableOfflineSync) ---

  /// Sends the documented pre-list sequence the official app uses; best-effort.
  /// `APP&REC&SECEN` in particular precedes listing in the reference capture.
  Future<void> _sendSyncPreamble() async {
    for (final command in <String>[
      'APP&GET&USB',
      'APP&BAT',
      'APP&FW',
      'APP&MAC',
      'APP&SPACE',
      'APP&T&${_formatTimestamp(DateTime.now())}',
      'APP&REC&SECEN',
      'APP&STE',
    ]) {
      try {
        await _writeControl(command);
        await Future<void>.delayed(_commandGap);
      } catch (_) {
        // Preamble is informational; listing still works without it.
      }
    }
  }

  @override
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  }) async {
    // Live capture and offline sync share the notify channels and the binary
    // routing buffer, so they must never run at the same time.
    if (recording) return 0;
    _sawControlResponse = false;
    _drainCancelled = false;
    _lastFilesListed = 0;
    _lastSynced = 0;
    _lastFailed = 0;
    if (!await _authenticate()) {
      ClientDiagnosticLog.instance.record(
        'bluetooth_audio',
        'heypocket_no_response',
        level: 'warning',
        details: <String, Object?>{
          'hint': 'Session-key handshake (APP&SK) not acknowledged; the device '
              'accepts no commands. Check the device is on and in range.',
        },
      );
      // Surface this instead of returning a silent empty sync: a failed
      // handshake is a real error the user needs to see (reconnect / retry).
      throw StateError(
        'The device did not answer the connection handshake. Reconnect it and '
        'try syncing again.',
      );
    }
    var count = 0;
    var failed = 0;
    final files = await _listAllStoredFiles();
    _lastFilesListed = files.length;
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      'heypocket_sync_listed',
      details: <String, Object?>{
        'files': files.length,
        'deviceResponded': _sawControlResponse,
      },
    );
    for (final file in files) {
      // A cancel must end the whole sweep, not just the file in flight.
      if (_drainCancelled) break;
      try {
        final bytes = await _downloadStoredFile(file);
        if (bytes.length < minBytes) continue;
        await onRecording(
          WearableRecording(
            id: file.id,
            bytes: bytes,
            contentType: file.contentType,
            filename: file.filename,
            capturedAt: file.capturedAt,
          ),
        );
        // Delete from the device only after the recording is durably ingested.
        await _deleteStoredFile(file);
        count += 1;
      } catch (error) {
        // A single failed file is left on the device for a later sweep to retry
        // and must not abort draining the rest.
        ClientDiagnosticLog.instance.record(
          'bluetooth_audio',
          'heypocket_file_failed',
          level: 'warning',
          details: <String, Object?>{'id': file.id, 'error': error.toString()},
        );
        failed += 1;
        continue;
      }
    }
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      'heypocket_sync_done',
      details: <String, Object?>{
        'synced': count,
        'available': files.length,
        'failed': failed,
        'cancelled': _drainCancelled,
      },
    );
    _lastSynced = count;
    _lastFailed = failed;
    // Every file failing is not an empty device. Surfacing it keeps the sweep
    // from reporting "no new recordings" when nothing could be pulled at all.
    if (count == 0 && failed > 0) {
      throw StateError(
        'Found $failed recording(s) on the device but none could be '
        'transferred. Keep the device close and try again.',
      );
    }
    return count;
  }

  Future<List<HeyPocketStoredFile>> _listAllStoredFiles() async {
    await _sendSyncPreamble();
    // Enumerate recent days, de-duplicating by id (a day can be re-listed).
    final byId = <String, HeyPocketStoredFile>{};
    final today = DateTime.now();
    for (var back = 0; back < _syncLookbackDays; back += 1) {
      final day = today.subtract(Duration(days: back));
      for (final file in await _listStoredFilesForDate(day)) {
        byId[file.id] = file;
      }
    }
    return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<List<HeyPocketStoredFile>> _listStoredFilesForDate(
    DateTime date,
  ) async {
    final collector = <HeyPocketStoredFile>[];
    final done = Completer<void>();
    _listDone = done;
    _onFileEntry = collector.add;
    try {
      await _writeControl('APP&LIST&${_formatDate(date)}');
      // The device ends each day's listing with MCU&LIST&<count>.
      await done.future.timeout(_listTimeout, onTimeout: () {});
    } catch (_) {
      // A failed day query contributes no files rather than aborting the sweep.
    } finally {
      _onFileEntry = null;
      _listDone = null;
    }
    return collector;
  }

  Future<Uint8List> _downloadStoredFile(HeyPocketStoredFile file) async {
    // A single BLE transfer can arrive short when notifications are dropped
    // (common on Web Bluetooth). The device re-sends the whole file on each
    // APP&U, so retry until the full announced byte count (MCU&U&<size>) has
    // arrived — verified against real hardware, where one file needed a retry.
    List<int> best = const <int>[];
    // Sticky across attempts. A retry whose MCU&U announcement is dropped must
    // NOT read as "size unknown": that switched the completeness check off, so a
    // short transfer was accepted as final, ingested, and then deleted from the
    // device — a corrupt import plus permanent loss of the original.
    int? announced;
    for (var attempt = 0; attempt < _downloadAttempts; attempt += 1) {
      final buffer = <int>[];
      final done = Completer<void>();
      _downloadBuffer = buffer;
      _downloadDone = done;
      _expectedDownloadBytes = null;
      try {
        await _writeControl('APP&U&${file.date}&${file.fileId}');
        await done.future.timeout(_downloadTimeout);
        // Keep the first size the device ever reported for this file.
        announced ??= _expectedDownloadBytes;
        // MCU&OFF (control channel) can land just before the last MP3 chunks
        // (data channel); when a size is known, wait briefly for the tail.
        final expected = announced;
        if (expected != null) {
          for (var i = 0; i < 100 && buffer.length < expected; i += 1) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      } finally {
        _downloadBuffer = null;
        _downloadDone = null;
        _expectedDownloadBytes = null;
      }
      if (buffer.length > best.length) best = buffer;
      if (announced != null) {
        if (best.length >= announced) break;
      } else if (best.isNotEmpty) {
        // Firmware that never announces a size: nothing to verify against, so
        // accept the first non-empty transfer as before.
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // Never ingest a truncated recording: if it never reached the announced size
    // it stays on the device for a later sweep rather than being stored corrupt.
    if (announced != null && best.length < announced) {
      throw StateError(
        'HeyPocket download incomplete after $_downloadAttempts attempts: '
        '${best.length}/$announced bytes',
      );
    }
    return Uint8List.fromList(best);
  }

  Future<bool> _deleteStoredFile(HeyPocketStoredFile file) async {
    final ack = Completer<bool>();
    _deleteAck = ack;
    var ok = false;
    try {
      await _writeControl('APP&D&${file.date}&${file.fileId}');
      ok = await ack.future.timeout(_deleteTimeout, onTimeout: () => false);
    } catch (_) {
      ok = false;
    } finally {
      if (identical(_deleteAck, ack)) _deleteAck = null;
    }
    // Surface whether the device actually acknowledged the delete (MCU&D): if it
    // does not, the file is re-listed next sweep (re-download is idempotent, so
    // no duplicate transcript — just wasted transfer, visible here).
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      ok ? 'heypocket_deleted' : 'heypocket_delete_unacked',
      level: ok ? 'info' : 'warning',
      details: <String, Object?>{'id': file.id},
    );
    return ok;
  }

  @override
  Map<String, Object?> get syncDiagnostics => <String, Object?>{
    // Separates "device is empty" from "device never answered" and from
    // "files were found but none could be transferred".
    'deviceResponded': _sawControlResponse,
    'authenticated': _authenticated,
    'filesListed': _lastFilesListed,
    'filesSynced': _lastSynced,
    'filesFailed': _lastFailed,
  };

  @override
  Future<void> cancelStoredSync() async {
    // Stop the sweep itself, not just the transfer in flight: without this the
    // loop simply moved on to the next file and kept the channel busy.
    _drainCancelled = true;
    try {
      await _writeControl('APP&SHUT');
    } catch (_) {
      // Best-effort abort.
    }
    final done = _downloadDone;
    _downloadBuffer = null;
    _downloadDone = null;
    if (done != null && !done.isCompleted) {
      done.completeError(StateError('HeyPocket sync cancelled.'));
    }
  }

  static String _formatDate(DateTime time) {
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}-'
        '${pad(time.month)}-${pad(time.day)}';
  }

  Future<void> _syncTime() async {
    try {
      await _writeControl('APP&T&${_formatTimestamp(DateTime.now())}');
    } catch (_) {
      // A missed clock sync only affects device-side file timestamps.
    }
  }

  Future<void> _writeControl(String command) {
    return transport.writeCharacteristic(
      WearableDeviceUuids.heyPocketService,
      WearableDeviceUuids.heyPocketControlWrite,
      ascii.encode(command),
    );
  }

  static String _formatTimestamp(DateTime time) {
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    return '${pad(time.year, 4)}${pad(time.month, 2)}${pad(time.day, 2)}'
        '${pad(time.hour, 2)}${pad(time.minute, 2)}${pad(time.second, 2)}';
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    final auth = _authRequest;
    if (auth != null && !auth.isCompleted) auth.complete(false);
    _authRequest = null;
    final battery = _batteryRequest;
    if (battery != null && !battery.isCompleted) battery.complete(-1);
    _batteryRequest = null;
    // Resolve any in-flight sync so a teardown never leaves a hung future.
    _downloadBuffer = null;
    final download = _downloadDone;
    _downloadDone = null;
    if (download != null && !download.isCompleted) {
      download.completeError(StateError('HeyPocket disconnected during sync.'));
    }
    final list = _listDone;
    _listDone = null;
    if (list != null && !list.isCompleted) list.complete();
    final delete = _deleteAck;
    _deleteAck = null;
    if (delete != null && !delete.isCompleted) delete.complete(false);
  }
}
