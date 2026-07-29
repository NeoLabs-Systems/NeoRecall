import 'dart:async';

import '../ble/ble_transport.dart';
import 'device_models.dart';

abstract class WearableConnector {
  WearableConnector({
    required this.device,
    required this.transport,
  });

  final DiscoveredWearable device;
  final BleTransport transport;

  final StreamController<List<int>> audioBytes =
      StreamController<List<int>>.broadcast();
  final StreamController<int> batteryLevels =
      StreamController<int>.broadcast();
  final StreamController<List<int>> buttonEvents =
      StreamController<List<int>>.broadcast();

  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  bool recording = false;

  WearableDeviceType get type => device.type;
  bool get isRecording => recording;
  WearableAudioCodec get codec;

  Future<void> connect() async {
    await transport.connect();
    await onConnected();
  }

  Future<void> onConnected() async {}

  Future<void> disconnect() async {
    if (recording) {
      try {
        await stopRecording();
      } catch (_) {}
    }
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await transport.disconnect();
  }

  void track(StreamSubscription<dynamic> sub) => _subs.add(sub);

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
