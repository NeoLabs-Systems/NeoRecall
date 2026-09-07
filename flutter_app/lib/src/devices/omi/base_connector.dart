import 'dart:async';

import '../ble/gatt_connector_transport.dart';
import 'device_models.dart';

abstract class WearableConnector {
  WearableConnector({required this.device, required this.transport});

  final DiscoveredWearable device;
  final WearableTransport transport;

  final StreamController<List<int>> audioBytes =
      StreamController<List<int>>.broadcast();
  final StreamController<int> batteryLevels = StreamController<int>.broadcast();
  final StreamController<List<int>> buttonEvents =
      StreamController<List<int>>.broadcast();

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  final List<StreamSubscription<dynamic>> _recordingSubs =
      <StreamSubscription<dynamic>>[];
  bool recording = false;

  WearableDeviceType get type => device.type;
  bool get isRecording => recording;
  WearableAudioCodec get codec;

  Future<void> connect({bool requiresPairing = false}) async {
    await transport.connect(requiresPairing: requiresPairing);
    await onConnected();
  }

  Future<void> onConnected() async {}

  /// Whether tearing down the BLE session should also stop on-device recording.
  ///
  /// Omi's live stream *is* the recording, so a drop must stop it. Memoket
  /// keeps the take on flash; sending stop here is what split one long
  /// recording into many when Android dropped the link in the background.
  bool get stopDeviceOnDisconnect => true;

  Future<void> disconnect() async {
    if (recording && stopDeviceOnDisconnect) {
      try {
        await stopRecording();
      } catch (_) {}
    }
    recording = false;
    for (final sub in _subs) {
      try {
        await sub.cancel();
      } catch (_) {
        // Continue releasing the remaining protocol resources.
      }
    }
    _subs.clear();
    await cancelRecordingSubscriptions();
    try {
      await transport.disconnect();
    } catch (_) {
      // The transport may already be gone; local cleanup is still complete.
    }
  }

  void track(StreamSubscription<dynamic> sub) => _subs.add(sub);
  void trackRecording(StreamSubscription<dynamic> sub) =>
      _recordingSubs.add(sub);

  Future<void> cancelRecordingSubscriptions() async {
    for (final sub in _recordingSubs) {
      try {
        await sub.cancel();
      } catch (_) {
        // Continue releasing the remaining recording subscriptions.
      }
    }
    _recordingSubs.clear();
  }

  Future<int> readBatteryLevel() async => -1;

  Future<void> startRecording();
  Future<void> stopRecording();

  Future<void> dispose() async {
    await disconnect();
    await audioBytes.close();
    await batteryLevels.close();
    await buttonEvents.close();
  }
}
