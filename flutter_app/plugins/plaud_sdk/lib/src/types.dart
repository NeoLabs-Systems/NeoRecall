/// Typed payloads for the Plaud SDK bridge. Shapes mirror the React Native
/// demo's `PlaudSdk.types.ts` so both demos speak the same contract.
library;

Map<String, Object?> _asMap(Object? raw) =>
    (raw as Map).map((k, v) => MapEntry(k as String, v));

int _asInt(Object? v) => (v as num?)?.toInt() ?? 0;
double _asDouble(Object? v) => (v as num?)?.toDouble() ?? 0;
bool _asBool(Object? v) => v == true || v == 1;

/// A Plaud recorder discovered during a BLE scan.
class PlaudScanDevice {
  const PlaudScanDevice({
    required this.name,
    required this.uuid,
    required this.serialNumber,
    required this.rssi,
    required this.supportWiFi,
  });

  factory PlaudScanDevice.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudScanDevice(
      name: m['name'] as String? ?? '',
      uuid: m['uuid'] as String? ?? '',
      serialNumber: m['serialNumber'] as String? ?? '',
      rssi: _asDouble(m['rssi']),
      supportWiFi: _asBool(m['supportWiFi']),
    );
  }

  final String name;
  final String uuid;
  final String serialNumber;
  final double rssi;
  final bool supportWiFi;
}

/// A recording stored on the connected device.
class PlaudFile {
  const PlaudFile({
    required this.sn,
    required this.sessionId,
    required this.size,
    required this.scenes,
    required this.channels,
    required this.isOgg,
    required this.isMusic,
    required this.duration,
  });

  factory PlaudFile.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudFile(
      sn: m['sn'] as String? ?? '',
      sessionId: _asInt(m['sessionId']),
      size: _asInt(m['size']),
      scenes: _asInt(m['scenes']),
      channels: _asInt(m['channels']),
      isOgg: _asBool(m['isOgg']),
      isMusic: _asBool(m['isMusic']),
      duration: _asInt(m['duration']),
    );
  }

  final String sn;
  final int sessionId;

  /// Bytes.
  final int size;
  final int scenes;
  final int channels;
  final bool isOgg;
  final bool isMusic;

  /// Seconds.
  final int duration;
}

/// `connectState` event — 1 = connected, 0 = disconnected, {2, -1, -2} = failure.
class PlaudConnectState {
  const PlaudConnectState({
    required this.connected,
    required this.failed,
    required this.state,
  });

  factory PlaudConnectState.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudConnectState(
      connected: _asBool(m['connected']),
      failed: _asBool(m['failed']),
      state: _asInt(m['state']),
    );
  }

  final bool connected;
  final bool failed;
  final int state;
}

/// `recordStart` / `recordResume` events (device-initiated: button press / VAD).
class PlaudRecordStart {
  const PlaudRecordStart({
    required this.sessionId,
    required this.start,
    required this.status,
    required this.scene,
    required this.startTime,
    this.reason,
  });

  factory PlaudRecordStart.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudRecordStart(
      sessionId: _asInt(m['sessionId']),
      start: _asInt(m['start']),
      status: _asInt(m['status']),
      scene: _asInt(m['scene']),
      startTime: _asInt(m['startTime']),
      reason: m.containsKey('reason') ? _asInt(m['reason']) : null,
    );
  }

  final int sessionId;
  final int start;
  final int status;
  final int scene;
  final int startTime;
  final int? reason;
}

/// `recordStop` / `recordPause` events.
class PlaudRecordStop {
  const PlaudRecordStop({
    required this.sessionId,
    required this.reason,
    required this.fileExist,
    required this.fileSize,
  });

  factory PlaudRecordStop.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudRecordStop(
      sessionId: _asInt(m['sessionId']),
      reason: _asInt(m['reason']),
      fileExist: _asBool(m['fileExist']),
      fileSize: _asInt(m['fileSize']),
    );
  }

  final int sessionId;
  final int reason;
  final bool fileExist;
  final int fileSize;
}

/// `exportProgress` event emitted while `exportAudio` runs.
class PlaudExportProgress {
  const PlaudExportProgress({
    required this.sessionId,
    required this.progress,
    required this.message,
  });

  factory PlaudExportProgress.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudExportProgress(
      sessionId: _asInt(m['sessionId']),
      progress: _asInt(m['progress']),
      message: m['message'] as String? ?? '',
    );
  }

  final int sessionId;

  /// 0–100.
  final int progress;
  final String message;
}

/// Resolution of `exportAudio` — the decoded file on local disk.
class PlaudExportResult {
  const PlaudExportResult({required this.sessionId, required this.outputPath});

  factory PlaudExportResult.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudExportResult(
      sessionId: _asInt(m['sessionId']),
      outputPath: m['outputPath'] as String? ?? '',
    );
  }

  final int sessionId;
  final String outputPath;
}

/// Audio formats supported by `exportAudio`.
enum PlaudAudioFormat {
  pcm,
  mp3,
  wav,
  opus;

  String get wireName => name;
}

class PlaudDeleteResult {
  const PlaudDeleteResult({required this.sessionId, required this.status});

  factory PlaudDeleteResult.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudDeleteResult(
      sessionId: _asInt(m['sessionId']),
      status: _asInt(m['status']),
    );
  }

  final int sessionId;
  final int status;

  bool get ok => status == 0;
}

class PlaudChargingState {
  const PlaudChargingState({required this.isCharging, required this.level});

  factory PlaudChargingState.fromMap(Object? raw) {
    final m = _asMap(raw);
    return PlaudChargingState(
      isCharging: _asBool(m['isCharging']),
      level: _asInt(m['level']),
    );
  }

  final bool isCharging;
  final int level;
}
