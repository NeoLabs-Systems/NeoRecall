import 'dart:io';
import 'dart:typed_data';

import 'package:plaud_sdk/plaud_sdk.dart' as sdk;

import 'plaud_hardware.dart';

PlaudHardware createPlaudHardware() =>
    sdk.isPlaudSdkAvailable ? PluginPlaudHardware() : UnavailablePlaudHardware();

class PluginPlaudHardware implements PlaudHardware {
  @override
  bool get isAvailable => sdk.isPlaudSdkAvailable;

  @override
  Stream<List<PlaudDiscoveredDevice>> get scanResults =>
      sdk.PlaudSdk.onScanResult.map(
        (devices) => [
          for (final device in devices)
            PlaudDiscoveredDevice(
              name: device.name,
              uuid: device.uuid,
              serialNumber: device.serialNumber,
              rssi: device.rssi.round(),
            ),
        ],
      );

  @override
  Stream<PlaudConnectUpdate> get connectUpdates =>
      sdk.PlaudSdk.onConnectState.map(
        (state) => PlaudConnectUpdate(
          connected: state.connected,
          failed: state.failed,
        ),
      );

  @override
  Stream<List<PlaudStoredFile>> get fileLists => sdk.PlaudSdk.onFileList.map(
    (files) => [
      for (final file in files)
        PlaudStoredFile(
          sessionId: file.sessionId,
          size: file.size,
          durationSeconds: file.duration,
          serialNumber: file.sn,
        ),
    ],
  );

  @override
  Stream<PlaudExportUpdate> get exportProgress =>
      sdk.PlaudSdk.onExportProgress.map(
        (progress) => PlaudExportUpdate(
          sessionId: progress.sessionId,
          progress: progress.progress,
        ),
      );

  @override
  Stream<int> get batteryLevels =>
      sdk.PlaudSdk.onChargingState.map((state) => state.level);

  @override
  Stream<({int sessionId, bool ok})> get deleteResults =>
      sdk.PlaudSdk.onDeleteFile.map(
        (result) => (sessionId: result.sessionId, ok: result.ok),
      );

  @override
  Future<void> initialize({
    required String accessToken,
    required String customDomain,
    required String userId,
  }) {
    return sdk.PlaudSdk.initSDK(
      userAccessToken: accessToken,
      customDomain: customDomain,
      userId: userId,
    );
  }

  @override
  Future<void> startScan() => sdk.PlaudSdk.startScan();

  @override
  Future<void> stopScan() => sdk.PlaudSdk.stopScan();

  @override
  Future<void> connect({
    String? uuid,
    String? serialNumber,
    String? deviceToken,
  }) {
    return sdk.PlaudSdk.connectBleDevice(
      uuid: uuid,
      serialNumber: serialNumber,
      deviceToken: deviceToken,
    );
  }

  @override
  Future<void> disconnect() => sdk.PlaudSdk.disconnect();

  @override
  Future<void> getFileList({int startSessionId = 0}) =>
      sdk.PlaudSdk.getFileList(startSessionId: startSessionId);

  @override
  Future<Uint8List> exportAudio(int sessionId) async {
    final exported = await sdk.PlaudSdk.exportAudio(
      sessionId: sessionId,
      format: sdk.PlaudAudioFormat.mp3,
    );
    if (exported.outputPath.isEmpty) {
      throw StateError('Plaud export produced no file.');
    }
    final file = File(exported.outputPath);
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // Best-effort: ingest already has the bytes.
    }
    return bytes;
  }

  @override
  Future<void> deleteFile(int sessionId) =>
      sdk.PlaudSdk.deleteFile(sessionId: sessionId);
}
