import 'dart:async';
import 'dart:typed_data';

import 'base_connector.dart';
import 'device_models.dart';

class OmiConnector extends WearableConnector {
  OmiConnector({required super.device, required super.transport});

  WearableAudioCodec _codec = WearableAudioCodec.pcm8;

  @override
  WearableAudioCodec get codec => _codec;

  @override
  Future<void> onConnected() async {
    await _syncTime();
    _codec = await _readCodec();
    try {
      final level = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (level.isNotEmpty) batteryLevels.add(level.first);
    } catch (_) {}
    try {
      track(
        transport
            .getCharacteristicStream(
              WearableDeviceUuids.batteryService,
              WearableDeviceUuids.batteryLevel,
            )
            .listen((value) {
          if (value.isNotEmpty) batteryLevels.add(value.first);
        }),
      );
    } catch (_) {}
    try {
      track(
        transport
            .getCharacteristicStream(
              WearableDeviceUuids.buttonService,
              WearableDeviceUuids.buttonTrigger,
            )
            .listen((value) {
          if (value.isNotEmpty) buttonEvents.add(value);
        }),
      );
    } catch (_) {}
  }

  Future<void> _syncTime() async {
    try {
      final epochSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final bytes = ByteData(4)..setUint32(0, epochSeconds, Endian.little);
      await transport.writeCharacteristic(
        WearableDeviceUuids.timeSyncService,
        WearableDeviceUuids.timeSyncWrite,
        bytes.buffer.asUint8List(),
      );
    } catch (_) {}
  }

  Future<WearableAudioCodec> _readCodec() async {
    try {
      final value = await transport.readCharacteristic(
        WearableDeviceUuids.omiService,
        WearableDeviceUuids.omiAudioCodec,
      );
      final codecId = value.isNotEmpty ? value.first : 1;
      switch (codecId) {
        case 1:
          return WearableAudioCodec.pcm8;
        case 20:
          return WearableAudioCodec.opus;
        case 21:
          return WearableAudioCodec.opusFs320;
        default:
          return WearableAudioCodec.unknown;
      }
    } catch (_) {
      return WearableAudioCodec.pcm8;
    }
  }

  @override
  Future<int> readBatteryLevel() async {
    try {
      final value = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      return value.isNotEmpty ? value.first : -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    track(
      transport
          .getCharacteristicStream(
            WearableDeviceUuids.omiService,
            WearableDeviceUuids.omiAudioData,
          )
          .listen((value) {
        if (value.isNotEmpty) audioBytes.add(value);
      }),
    );
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    recording = false;
  }
}

class OmiGlassConnector extends OmiConnector {
  OmiGlassConnector({required super.device, required super.transport});
}
