import 'dart:typed_data';

/// One Plaud recorder seen during a BLE scan.
class PlaudDiscoveredDevice {
  const PlaudDiscoveredDevice({
    required this.name,
    required this.uuid,
    required this.serialNumber,
    required this.rssi,
  });

  final String name;
  final String uuid;
  final String serialNumber;
  final int rssi;
}

class PlaudStoredFile {
  const PlaudStoredFile({
    required this.sessionId,
    required this.size,
    required this.durationSeconds,
    this.serialNumber = '',
  });

  final int sessionId;
  final int size;
  final int durationSeconds;
  final String serialNumber;
}

class PlaudConnectUpdate {
  const PlaudConnectUpdate({required this.connected, required this.failed});

  final bool connected;
  final bool failed;
}

class PlaudExportUpdate {
  const PlaudExportUpdate({
    required this.sessionId,
    required this.progress,
  });

  final int sessionId;
  final int progress;
}

/// The subset of Plaud Embedded this adapter needs: scan, bind, list, export,
/// delete. Implementations must not call Plaud upload or transcription APIs.
abstract class PlaudHardware {
  bool get isAvailable;

  Stream<List<PlaudDiscoveredDevice>> get scanResults;
  Stream<PlaudConnectUpdate> get connectUpdates;
  Stream<List<PlaudStoredFile>> get fileLists;
  Stream<PlaudExportUpdate> get exportProgress;
  Stream<int> get batteryLevels;
  Stream<({int sessionId, bool ok})> get deleteResults;

  Future<void> initialize({
    required String accessToken,
    required String customDomain,
    required String userId,
  });
  Future<void> startScan();
  Future<void> stopScan();
  Future<void> connect({String? uuid, String? serialNumber, String? deviceToken});
  Future<void> disconnect();
  Future<void> getFileList({int startSessionId = 0});
  Future<Uint8List> exportAudio(int sessionId);
  Future<void> deleteFile(int sessionId);
}

class UnavailablePlaudHardware implements PlaudHardware {
  @override
  bool get isAvailable => false;

  @override
  Stream<List<PlaudDiscoveredDevice>> get scanResults =>
      const Stream<List<PlaudDiscoveredDevice>>.empty();
  @override
  Stream<PlaudConnectUpdate> get connectUpdates =>
      const Stream<PlaudConnectUpdate>.empty();
  @override
  Stream<List<PlaudStoredFile>> get fileLists =>
      const Stream<List<PlaudStoredFile>>.empty();
  @override
  Stream<PlaudExportUpdate> get exportProgress =>
      const Stream<PlaudExportUpdate>.empty();
  @override
  Stream<int> get batteryLevels => const Stream<int>.empty();
  @override
  Stream<({int sessionId, bool ok})> get deleteResults =>
      const Stream<({int sessionId, bool ok})>.empty();

  @override
  Future<void> initialize({
    required String accessToken,
    required String customDomain,
    required String userId,
  }) async {}

  @override
  Future<void> startScan() async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect({
    String? uuid,
    String? serialNumber,
    String? deviceToken,
  }) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> getFileList({int startSessionId = 0}) async {}
  @override
  Future<Uint8List> exportAudio(int sessionId) async => Uint8List(0);
  @override
  Future<void> deleteFile(int sessionId) async {}
}
