/// Flutter bridge for the Plaud iOS and Android device SDKs.
///
/// Mirrors the React Native demo's `plaud-sdk` Expo module: the same nine
/// methods and twelve events over `PlaudDeviceAgent`. Physical phones only —
/// there is no Plaud desktop or web SDK, and simulators cannot complete BLE.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'src/types.dart';

export 'src/types.dart';

/// Whether the native Plaud SDK can exist on this platform.
bool get isPlaudSdkAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

class PlaudSdk {
  PlaudSdk._();

  static const _methods = MethodChannel('plaud_sdk/methods');
  static const _events = EventChannel('plaud_sdk/events');

  static Stream<Map<String, Object?>>? _eventStream;

  /// Raw event stream — every native delegate callback arrives here as a map
  /// with an `event` key naming it.
  static Stream<Map<String, Object?>> get events {
    return _eventStream ??= _events.receiveBroadcastStream().map(
      (raw) => (raw as Map).map((k, v) => MapEntry(k as String, v)),
    ).asBroadcastStream();
  }

  static Stream<Map<String, Object?>> _on(String name) =>
      events.where((e) => e['event'] == name);

  /// `scanResult` — devices discovered so far (cumulative list per emission).
  static Stream<List<PlaudScanDevice>> get onScanResult => _on('scanResult').map(
        (e) => [
          for (final d in (e['devices'] as List? ?? const []))
            PlaudScanDevice.fromMap(d),
        ],
      );

  /// `scanTimeout` — the SDK gave up scanning. `reason` is
  /// `bluetoothNotPoweredOn` when Bluetooth never became available.
  static Stream<String?> get onScanTimeout =>
      _on('scanTimeout').map((e) => e['reason'] as String?);

  /// `connectState` — connection lifecycle.
  static Stream<PlaudConnectState> get onConnectState =>
      _on('connectState').map(PlaudConnectState.fromMap);

  /// `penState` — device handshake state (raw map, informational).
  static Stream<Map<String, Object?>> get onPenState => _on('penState');

  /// `bind` — device ↔ user binding result (raw map, informational).
  static Stream<Map<String, Object?>> get onBind => _on('bind');

  /// `fileList` — recordings on the connected device.
  static Stream<List<PlaudFile>> get onFileList => _on('fileList').map(
        (e) => [
          for (final f in (e['files'] as List? ?? const []))
            PlaudFile.fromMap(f),
        ],
      );

  /// `exportProgress` — progress while `exportAudio` decodes a recording.
  static Stream<PlaudExportProgress> get onExportProgress =>
      _on('exportProgress').map(PlaudExportProgress.fromMap);

  /// Device-initiated recording lifecycle (physical button / VAD).
  static Stream<PlaudRecordStart> get onRecordStart =>
      _on('recordStart').map(PlaudRecordStart.fromMap);
  static Stream<PlaudRecordStart> get onRecordResume =>
      _on('recordResume').map(PlaudRecordStart.fromMap);
  static Stream<PlaudRecordStop> get onRecordStop =>
      _on('recordStop').map(PlaudRecordStop.fromMap);
  static Stream<PlaudRecordStop> get onRecordPause =>
      _on('recordPause').map(PlaudRecordStop.fromMap);

  /// `depair` — pairing cleared (device side or via [depair]).
  static Stream<int> get onDepair =>
      _on('depair').map((e) => (e['status'] as num?)?.toInt() ?? 0);

  // ---- Methods ----

  /// Initialise the SDK with a per-user JWT. `customDomain` is the bare host
  /// (e.g. `platform-us.plaud.ai`, no `https://`). `userId` is remembered and
  /// used as the default `deviceToken` when connecting.
  static Future<void> initSDK({
    required String userAccessToken,
    required String customDomain,
    String? userId,
  }) {
    return _methods.invokeMethod('initSDK', {
      'userAccessToken': userAccessToken,
      'customDomain': customDomain,
      'userId': userId,
    });
  }

  /// Start a BLE scan. Results stream in via [onScanResult]; the native side
  /// waits (up to ~18 s) for Bluetooth to power on before actually scanning.
  static Future<void> startScan() => _methods.invokeMethod('startScan');

  static Future<void> stopScan() => _methods.invokeMethod('stopScan');

  /// Connect to a device from a prior scan, identified by `uuid` (preferred)
  /// or `serialNumber`. Progress arrives via [onConnectState].
  static Future<void> connectBleDevice({
    String? uuid,
    String? serialNumber,
    String? deviceToken,
  }) {
    return _methods.invokeMethod('connectBleDevice', {
      'uuid': uuid,
      'serialNumber': serialNumber,
      'deviceToken': deviceToken,
    });
  }

  static Future<void> disconnect() => _methods.invokeMethod('disconnect');

  /// Unpair. With `clear`, local pairing state is wiped too. Completion is
  /// signalled by [onDepair].
  static Future<void> depair({bool clear = true}) =>
      _methods.invokeMethod('depair', {'clear': clear});

  static Future<bool> isConnected() async {
    final res = await _methods.invokeMethod<Map>('isConnected');
    return res?['connected'] == true;
  }

  /// Request the on-device recording list; results arrive via [onFileList].
  static Future<void> getFileList({int startSessionId = 0}) =>
      _methods.invokeMethod('getFileList', {'startSessionId': startSessionId});

  /// Decode a recording to a local audio file (Documents/PlaudExports).
  /// Progress streams via [onExportProgress]; resolves with the output path.
  static Future<PlaudExportResult> exportAudio({
    required int sessionId,
    PlaudAudioFormat format = PlaudAudioFormat.mp3,
    int channels = 1,
  }) async {
    final res = await _methods.invokeMethod<Map>('exportAudio', {
      'sessionId': sessionId,
      'format': format.wireName,
      'channels': channels,
    });
    return PlaudExportResult.fromMap(res);
  }

  /// Delete a recording from the device after it has been ingested elsewhere.
  /// Completion is signalled by [onDeleteFile].
  static Future<void> deleteFile({required int sessionId}) =>
      _methods.invokeMethod('deleteFile', {'sessionId': sessionId});

  /// `deleteFile` result from the device (`status == 0` is success).
  static Stream<PlaudDeleteResult> get onDeleteFile =>
      _on('deleteFile').map(PlaudDeleteResult.fromMap);

  /// Battery / charging updates from the device.
  static Stream<PlaudChargingState> get onChargingState =>
      _on('chargingState').map(PlaudChargingState.fromMap);
}
