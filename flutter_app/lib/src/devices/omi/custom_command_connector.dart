import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';

abstract class CustomCommandConnector extends WearableConnector {
  CustomCommandConnector({required super.device, required super.transport});

  String get serviceUuid;
  String get controlCharacteristicUuid;
  String get audioCharacteristicUuid;
  int get unmuteCommandCode;
  int get muteCommandCode;
  List<int> get unmuteCommandData;
  List<int> get muteCommandData;

  final Map<int, Completer<List<int>>> _pending = <int, Completer<List<int>>>{};

  Map<String, dynamic> parseResponse(List<int> data);
  List<int>? processAudioPacket(List<int> data);

  @override
  Future<void> onConnected() async {
    track(
      transport
          .getCharacteristicStream(serviceUuid, controlCharacteristicUuid)
          .listen((data) {
            final response = parseResponse(data);
            if (response['type'] == 'response') {
              final code = response['code'] as int;
              final payload = List<int>.from(
                response['payload'] as List? ?? const [],
              );
              final completer = _pending.remove(code);
              if (completer != null && !completer.isCompleted) {
                completer.complete(payload);
              }
            }
          }),
    );
    track(
      transport
          .getCharacteristicStream(serviceUuid, audioCharacteristicUuid)
          .listen((data) {
            final payload = processAudioPacket(data);
            if (payload != null && payload.isNotEmpty) {
              audioBytes.add(payload);
            }
          }),
    );
  }

  Future<List<int>?> sendCommand(int code, List<int> payload) async {
    final completer = Completer<List<int>>();
    _pending[code] = completer;
    final packet = <int>[code & 0xFF, (code >> 8) & 0xFF, ...payload];
    await transport.writeCharacteristic(
      serviceUuid,
      controlCharacteristicUuid,
      packet,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _pending.remove(code);
      return null;
    }
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    await sendCommand(unmuteCommandCode, unmuteCommandData);
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    await sendCommand(muteCommandCode, muteCommandData);
    recording = false;
  }
}

class BeeConnector extends CustomCommandConnector {
  BeeConnector({required super.device, required super.transport});
  final List<int> _frameBuffer = <int>[];

  @override
  String get serviceUuid => WearableDeviceUuids.beeService;
  @override
  String get controlCharacteristicUuid => WearableDeviceUuids.beeControl;
  @override
  String get audioCharacteristicUuid => WearableDeviceUuids.beeAudio;
  @override
  WearableAudioCodec get codec => WearableAudioCodec.aac;
  @override
  int get unmuteCommandCode => 0xC006;
  @override
  int get muteCommandCode => 0xC006;
  @override
  List<int> get unmuteCommandData => <int>[0x01];
  @override
  List<int> get muteCommandData => <int>[0x00];

  @override
  Map<String, dynamic> parseResponse(List<int> data) {
    if (data.length < 2) return <String, dynamic>{'type': 'unknown'};
    final responseCode = data[0] | (data[1] << 8);
    final payload = data.length > 2 ? data.sublist(2) : <int>[];
    if (responseCode == 0x8000 && payload.length >= 2) {
      final echoed = payload[0] | (payload[1] << 8);
      return <String, dynamic>{
        'type': 'response',
        'code': echoed,
        'payload': payload.length > 2 ? payload.sublist(2) : <int>[],
      };
    }
    return <String, dynamic>{
      'type': 'response',
      'code': responseCode,
      'payload': payload,
    };
  }

  @override
  List<int>? processAudioPacket(List<int> data) {
    if (data.length < 2) return null;
    _frameBuffer.addAll(data.sublist(2));
    while (_frameBuffer.length >= 7) {
      if (_frameBuffer[0] != 0xFF || (_frameBuffer[1] & 0xF0) != 0xF0) {
        _frameBuffer.removeAt(0);
        continue;
      }
      final frameLength =
          ((_frameBuffer[3] & 0x03) << 11) |
          (_frameBuffer[4] << 3) |
          ((_frameBuffer[5] & 0xE0) >> 5);
      if (frameLength <= 0 || frameLength > 4096) {
        _frameBuffer.removeAt(0);
        continue;
      }
      if (_frameBuffer.length >= frameLength) {
        final frame = _frameBuffer.sublist(0, frameLength);
        _frameBuffer.removeRange(0, frameLength);
        return frame;
      }
      break;
    }
    return null;
  }
}

class FieldyConnector extends WearableConnector {
  FieldyConnector({required super.device, required super.transport});

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opusFs320;

  @override
  Future<void> onConnected() async {
    try {
      final level = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (level.isNotEmpty) batteryLevels.add(level.first);
    } catch (_) {}
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    track(
      transport
          .getCharacteristicStream(
            WearableDeviceUuids.fieldyService,
            WearableDeviceUuids.fieldyAudio,
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
