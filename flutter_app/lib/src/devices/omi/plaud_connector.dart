import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';

class PlaudConnector extends WearableConnector {
  PlaudConnector({required super.device, required super.transport});

  static const int _cmdGetBattery = 9;
  static const int _cmdStartRecord = 20;
  static const int _cmdStopRecord = 23;
  static const int _cmdSyncFileStart = 28;
  static const int _cmdStopSync = 30;

  final Map<int, StreamController<List<int>>> _queues =
      <int, StreamController<List<int>>>{};
  StreamSubscription<List<int>>? _notificationSub;
  int? _sessionId;

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opus;

  @override
  Future<void> onConnected() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    _notificationSub = transport
        .getCharacteristicStream(
          WearableDeviceUuids.plaudService,
          WearableDeviceUuids.plaudNotify,
        )
        .listen(_handleNotification);
    track(_notificationSub!);
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    if (data[0] == 2) {
      final chunk = _parseAudioChunk(data.sublist(1));
      if (chunk != null) audioBytes.add(chunk);
      return;
    }
    if (data.length >= 3) {
      final cmdId = data[1] | (data[2] << 8);
      final payload = data.length > 3 ? data.sublist(3) : <int>[];
      _queues
          .putIfAbsent(cmdId, () => StreamController<List<int>>.broadcast())
          .add(payload);
    }
  }

  List<int>? _parseAudioChunk(List<int> payload) {
    if (payload.length < 9) return null;
    final position = _toInt32(payload.sublist(4, 8));
    if (position == 0xFFFFFFFF) return null;
    final length = payload[8];
    if (9 + length > payload.length) return null;
    return payload.sublist(9, 9 + length);
  }

  Future<List<int>?> _sendCommand(int cmdId, List<int> payload) async {
    _queues.putIfAbsent(cmdId, () => StreamController<List<int>>.broadcast());
    final command = <int>[1, cmdId & 0xFF, (cmdId >> 8) & 0xFF, ...payload];
    await transport.writeCharacteristic(
      WearableDeviceUuids.plaudService,
      WearableDeviceUuids.plaudWrite,
      command,
    );
    try {
      return await _queues[cmdId]!.stream.first.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<int> readBatteryLevel() async {
    final response = await _sendCommand(_cmdGetBattery, const <int>[]);
    if (response != null && response.length >= 2) return response[1];
    return -1;
  }

  @override
  Future<void> startRecording() async {
    if (recording) return;
    final payload = <int>[..._toBytes32(1), ..._toBytes32(0), ..._toBytes32(0)];
    final response = await _sendCommand(_cmdStartRecord, payload);
    if (response != null && response.length >= 4) {
      _sessionId = _toInt32(response.sublist(0, 4));
      await _sendCommand(
        _cmdSyncFileStart,
        <int>[
          ..._toBytes64(_sessionId!),
          ..._toBytes64(0),
          ..._toBytes64(0x7FFFFFFF),
        ],
      );
      recording = true;
      return;
    }
    throw StateError('PLAUD failed to start recording.');
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.plaudService,
        WearableDeviceUuids.plaudWrite,
        <int>[1, _cmdStopSync & 0xFF, (_cmdStopSync >> 8) & 0xFF, 1],
      );
      if (_sessionId != null) {
        await _sendCommand(
          _cmdStopRecord,
          <int>[..._toBytes32(_sessionId!), ..._toBytes32(0)],
        );
      }
    } finally {
      recording = false;
      _sessionId = null;
    }
  }

  int _toInt32(List<int> bytes) =>
      bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);

  List<int> _toBytes32(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];

  List<int> _toBytes64(int value) => <int>[
        ..._toBytes32(value),
        0,
        0,
        0,
        0,
      ];
}
