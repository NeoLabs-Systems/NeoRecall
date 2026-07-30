import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';

abstract class CustomCommandConnector extends WearableConnector {
  CustomCommandConnector({required super.device, required super.transport});

  static const Duration commandTimeout = Duration(seconds: 8);

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
      (await transport.characteristicStream(
        serviceUuid,
        controlCharacteristicUuid,
      )).listen((data) {
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
      (await transport.characteristicStream(
        serviceUuid,
        audioCharacteristicUuid,
      )).listen((data) {
        final payload = processAudioPacket(data);
        if (payload != null && payload.isNotEmpty) {
          audioBytes.add(payload);
        }
      }),
    );
  }

  Future<List<int>?> sendCommand(int code, List<int> payload) async {
    if (_pending.containsKey(code)) {
      throw StateError('Wearable command $code is already pending.');
    }
    final completer = Completer<List<int>>();
    _pending[code] = completer;
    final packet = <int>[code & 0xFF, (code >> 8) & 0xFF, ...payload];
    try {
      await transport.writeCharacteristic(
        serviceUuid,
        controlCharacteristicUuid,
        packet,
      );
      return await completer.future.timeout(commandTimeout);
    } on TimeoutException {
      return null;
    } finally {
      if (identical(_pending[code], completer)) _pending.remove(code);
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

class FieldyConnector extends WearableConnector {
  FieldyConnector({required super.device, required super.transport});
  static const frameSize = 40;
  static const opusToc = 0xb8;
  static const Duration _batteryPollInterval = Duration(seconds: 60);
  final List<int> _frameBuffer = <int>[];
  Timer? _batteryTimer;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opusFs320;

  @override
  Future<void> onConnected() async {
    await _readBattery();
    // Fieldy exposes no battery notify characteristic; poll it like the
    // reference so the level stays current across a long session.
    _batteryTimer = Timer.periodic(
      _batteryPollInterval,
      (_) => unawaited(_readBattery()),
    );
  }

  Future<void> _readBattery() async {
    try {
      final level = await transport.readCharacteristic(
        WearableDeviceUuids.batteryService,
        WearableDeviceUuids.batteryLevel,
      );
      if (level.isNotEmpty) batteryLevels.add(level.first);
    } catch (_) {
      // Battery telemetry is informational; a failed read is ignored.
    }
  }

  @override
  Future<void> dispose() async {
    _batteryTimer?.cancel();
    _batteryTimer = null;
    await super.dispose();
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    trackRecording(
      (await transport.characteristicStream(
        WearableDeviceUuids.fieldyService,
        WearableDeviceUuids.fieldyAudio,
      )).listen((value) {
        _frameBuffer.addAll(value);
        while (_frameBuffer.isNotEmpty && _frameBuffer.first != opusToc) {
          _frameBuffer.removeAt(0);
        }
        while (_frameBuffer.length >= frameSize) {
          audioBytes.add(_frameBuffer.sublist(0, frameSize));
          _frameBuffer.removeRange(0, frameSize);
          while (_frameBuffer.isNotEmpty && _frameBuffer.first != opusToc) {
            _frameBuffer.removeAt(0);
          }
        }
      }),
    );
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    await cancelRecordingSubscriptions();
    _frameBuffer.clear();
    recording = false;
  }
}
