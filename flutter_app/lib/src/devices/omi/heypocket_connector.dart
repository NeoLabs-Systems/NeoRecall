import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'base_connector.dart';
import 'device_models.dart';
import 'offline_sync.dart';

/// A recording held in HeyPocket on-board flash, addressed by its capture date
/// and per-day file id (both echoed verbatim to the download/delete commands).
class HeyPocketStoredFile {
  const HeyPocketStoredFile({
    required this.date,
    required this.fileId,
    required this.sizeBytes,
  });

  /// `YYYY-MM-DD` as reported by the device.
  final String date;
  final String fileId;
  final int sizeBytes;

  String get id => '$date/$fileId';
  String get contentType => 'audio/mpeg';
  String get filename => 'heypocket-$date-$fileId.mp3';
  DateTime? get capturedAt => DateTime.tryParse(date)?.toUtc();
}

/// HeyPocket (also labelled PKT01 / Pocket) BLE recorder.
///
/// Control traffic is ASCII text framed with the documented prefixes
/// (`MCU&`, `APP&`, `BLE&`, `SYS&`); audio is an MP3 byte stream. Some firmware
/// variants emit binary audio on the control-notify endpoint as well, so every
/// payload is classified as control-or-audio by its *content* rather than by
/// which characteristic delivered it.
///
/// To avoid streaming (and draining the battery) while merely paired, the audio
/// notify subscription and the `APP&STA` start command are issued on
/// [startRecording] and torn down on [stopRecording], mirroring the other
/// wearable connectors.
class HeyPocketConnector extends WearableConnector with WearableOfflineSync {
  HeyPocketConnector({required super.device, required super.transport});

  static const Duration _batteryTimeout = Duration(seconds: 5);
  // Offline sync: how far back to enumerate stored files, and per-step timeouts.
  static const int _syncLookbackDays = 7;
  // A day with no files ends after this short wait; between file entries the
  // (slightly longer) quiet gap detects the end of a populated day's list.
  static const Duration _listInitialTimeout = Duration(milliseconds: 350);
  static const Duration _listQuietGap = Duration(milliseconds: 700);
  static const Duration _listOverallTimeout = Duration(seconds: 12);
  static const Duration _downloadTimeout = Duration(seconds: 90);
  static const Duration _deleteTimeout = Duration(seconds: 8);
  static const List<String> _controlPrefixes = <String>[
    'MCU&',
    'APP&',
    'BLE&',
    'SYS&',
  ];
  static const String _batteryResponsePrefix = 'MCU&BAT&';

  Completer<int>? _batteryRequest;
  // Offline-sync state. A non-null _downloadBuffer routes binary payloads to the
  // active download instead of the live-capture stream.
  List<int>? _downloadBuffer;
  Completer<void>? _downloadDone;
  Completer<bool>? _deleteAck;
  void Function(HeyPocketStoredFile file)? _onFileEntry;
  StreamSubscription<List<int>>? _syncAudioSub;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.mp3;

  @override
  Future<void> onConnected() async {
    track(
      (await transport.characteristicStream(
        WearableDeviceUuids.heyPocketService,
        WearableDeviceUuids.heyPocketControlNotify,
      )).listen(_handleControlNotification),
    );
    // Best-effort clock sync and an initial battery read. Neither may block or
    // fail capture, so both are guarded.
    await _syncTime();
    try {
      await _writeControl('APP&BAT');
    } catch (_) {
      // Battery is informational; the device still records without it.
    }
  }

  void _handleControlNotification(List<int> data) {
    if (data.isEmpty) return;
    final text = _asControlFrame(data);
    if (text != null) {
      _handleControlFrame(text);
    } else {
      _handleBinary(data);
    }
  }

  void _handleAudioNotification(List<int> data) {
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
    // Offline-sync responses (§8): file-list entry, end-of-download, delete ack.
    if (text.startsWith('MCU&F&')) {
      final file = _parseFileEntry(text);
      if (file != null) _onFileEntry?.call(file);
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
    // Other acknowledgements (MCU&STE / MCU&STA / MCU&STO) are status only and
    // require no action for the streaming capture path.
  }

  /// Parses `MCU&F&<date>&<fileId>&<size>` into a stored-file descriptor.
  HeyPocketStoredFile? _parseFileEntry(String text) {
    final parts = text.split('&');
    if (parts.length < 5) return null;
    final size = int.tryParse(parts[4].trim());
    if (size == null) return null;
    return HeyPocketStoredFile(
      date: parts[2].trim(),
      fileId: parts[3].trim(),
      sizeBytes: size,
    );
  }

  @override
  Future<int> readBatteryLevel() async {
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
    trackRecording(
      (await transport.characteristicStream(
        WearableDeviceUuids.heyPocketService,
        WearableDeviceUuids.heyPocketAudioNotify,
      )).listen(_handleAudioNotification),
    );
    try {
      await _writeControl('APP&STA');
    } catch (_) {
      await cancelRecordingSubscriptions();
      rethrow;
    }
    recording = true;
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
    await cancelRecordingSubscriptions();
  }

  // --- Offline sync (WearableOfflineSync, §8) ---

  /// Sends the documented preamble so the device reports battery/firmware and
  /// aligns its clock and mode before a sync sweep. Best-effort throughout.
  Future<void> sendSyncPreamble() async {
    for (final command in <String>[
      'APP&BAT',
      'APP&FW',
      'APP&T&${_formatTimestamp(DateTime.now())}',
      'APP&STE',
    ]) {
      try {
        await _writeControl(command);
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
    // Live capture and offline sync both use the audio-notify channel and the
    // binary-routing buffer, so they must never run at the same time.
    if (recording) return 0;
    var count = 0;
    for (final file in await _listAllStoredFiles()) {
      if (file.sizeBytes < minBytes) continue;
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
      } catch (_) {
        // A single failed file (download or ingest) is left on the device for a
        // later sweep to retry, and must not abort draining the rest.
        continue;
      }
    }
    return count;
  }

  Future<List<HeyPocketStoredFile>> _listAllStoredFiles() async {
    await sendSyncPreamble();
    // Enumerate the recent days and de-duplicate by id (a day can be re-listed).
    final byId = <String, HeyPocketStoredFile>{};
    final today = DateTime.now();
    for (var back = 0; back < _syncLookbackDays; back += 1) {
      final day = today.subtract(Duration(days: back));
      for (final file in await _listStoredFilesForDate(day)) {
        if (file.sizeBytes > 0) byId[file.id] = file;
      }
    }
    return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<List<HeyPocketStoredFile>> _listStoredFilesForDate(
    DateTime date,
  ) async {
    final collector = <HeyPocketStoredFile>[];
    final done = Completer<void>();
    Timer? quiet;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // Entries stream in with no explicit terminator, so a quiet gap ends the day.
    _onFileEntry = (file) {
      collector.add(file);
      quiet?.cancel();
      quiet = Timer(_listQuietGap, finish);
    };
    try {
      await _writeControl('APP&LIST&${_formatDate(date)}');
      quiet = Timer(_listInitialTimeout, finish);
      await done.future.timeout(_listOverallTimeout, onTimeout: finish);
    } catch (_) {
      // A failed day query contributes no files rather than aborting the sweep.
    } finally {
      quiet?.cancel();
      _onFileEntry = null;
    }
    return collector;
  }

  Future<Uint8List> _downloadStoredFile(HeyPocketStoredFile file) async {
    final buffer = <int>[];
    final done = Completer<void>();
    _downloadBuffer = buffer;
    _downloadDone = done;
    await _beginSyncAudio();
    try {
      await _writeControl('APP&U&${file.date}&${file.fileId}');
      // Binary MP3 notifications accumulate into the buffer until MCU&OFF.
      await done.future.timeout(_downloadTimeout);
      return Uint8List.fromList(buffer);
    } finally {
      _downloadBuffer = null;
      _downloadDone = null;
      await _endSyncAudio();
    }
  }

  Future<bool> _deleteStoredFile(HeyPocketStoredFile file) async {
    final ack = Completer<bool>();
    _deleteAck = ack;
    try {
      await _writeControl('APP&D&${file.date}&${file.fileId}');
      return await ack.future.timeout(_deleteTimeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      if (identical(_deleteAck, ack)) _deleteAck = null;
    }
  }

  @override
  Future<void> cancelStoredSync() async {
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
    await _endSyncAudio();
  }

  Future<void> _beginSyncAudio() async {
    if (_syncAudioSub != null || recording) return;
    _syncAudioSub =
        (await transport.characteristicStream(
          WearableDeviceUuids.heyPocketService,
          WearableDeviceUuids.heyPocketAudioNotify,
        )).listen(_handleAudioNotification);
  }

  Future<void> _endSyncAudio() async {
    await _syncAudioSub?.cancel();
    _syncAudioSub = null;
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
    final request = _batteryRequest;
    if (request != null && !request.isCompleted) request.complete(-1);
    _batteryRequest = null;
    // Resolve any in-flight sync so a teardown never leaves a hung future or a
    // dangling audio subscription.
    _downloadBuffer = null;
    final download = _downloadDone;
    _downloadDone = null;
    if (download != null && !download.isCompleted) {
      download.completeError(StateError('HeyPocket disconnected during sync.'));
    }
    final delete = _deleteAck;
    _deleteAck = null;
    if (delete != null && !delete.isCompleted) delete.complete(false);
    await _endSyncAudio();
  }
}
