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
  static const int _audioFrameBytes = 80;
  static const int _sessionSetupAttempts = 3;
  static const Duration _notificationReadyDelay = Duration(seconds: 2);
  static const Duration _commandTimeout = Duration(seconds: 10);
  static const Duration _recordResetDelay = Duration(milliseconds: 500);
  static const Duration _syncReadyDelay = Duration(seconds: 1);

  final Map<int, Completer<List<int>>> _pending = <int, Completer<List<int>>>{};
  StreamSubscription<List<int>>? _notificationSub;
  int? _sessionId;
  final List<int> _audioBuffer = <int>[];

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opusFs320;

  @override
  Future<void> onConnected() async {
    await Future<void>.delayed(_notificationReadyDelay);
    _notificationSub = (await transport.characteristicStream(
      WearableDeviceUuids.plaudService,
      WearableDeviceUuids.plaudNotify,
    )).listen(_handleNotification);
    track(_notificationSub!);
  }

  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    if (data[0] == 2) {
      final chunk = _parseAudioChunk(data.sublist(1));
      if (chunk != null) {
        _audioBuffer.addAll(chunk);
        while (_audioBuffer.length >= _audioFrameBytes) {
          audioBytes.add(_audioBuffer.sublist(0, _audioFrameBytes));
          _audioBuffer.removeRange(0, _audioFrameBytes);
        }
      }
      return;
    }
    if (data.length >= 3) {
      final cmdId = data[1] | (data[2] << 8);
      final payload = data.length > 3 ? data.sublist(3) : <int>[];
      final pending = _pending.remove(cmdId);
      if (pending != null && !pending.isCompleted) pending.complete(payload);
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
    final existing = _pending[cmdId];
    if (existing != null) {
      return existing.future;
    }
    final pending = Completer<List<int>>();
    _pending[cmdId] = pending;
    final command = <int>[1, cmdId & 0xFF, (cmdId >> 8) & 0xFF, ...payload];
    try {
      await transport.writeCharacteristic(
        WearableDeviceUuids.plaudService,
        WearableDeviceUuids.plaudWrite,
        command,
      );
      return await pending.future.timeout(_commandTimeout);
    } on TimeoutException {
      return null;
    } finally {
      if (identical(_pending[cmdId], pending)) _pending.remove(cmdId);
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
    recording = true;
    _startRecordingLoop();
  }

  Future<void> _startRecordingLoop() async {
    for (var attempt = 0; recording; attempt += 1) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!recording) return;
      await _sendCommand(_cmdStopRecord, <int>[
        ..._toBytes32(0),
        ..._toBytes32(0),
      ]);
      await Future<void>.delayed(_recordResetDelay);
      if (!recording) return;
      final response = await _sendCommand(_cmdStartRecord, <int>[
        ..._toBytes32(1),
        ..._toBytes32(0),
        ..._toBytes32(0),
      ]);
      if (response == null || response.length < 10) continue;
      final sessionId = _toInt32(response.sublist(0, 4));
      final startTime = _toInt32(response.sublist(4, 8));
      await Future<void>.delayed(_syncReadyDelay);
      if (!recording) return;
      final syncResponse = await _sendCommand(_cmdSyncFileStart, <int>[
        ..._toBytes64(sessionId),
        ..._toBytes64(startTime),
        ..._toBytes64(0x7FFFFFFF),
      ]);
      if (syncResponse != null && recording) {
        _sessionId = sessionId;
        return;
      }
    }
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
        await _sendCommand(_cmdStopRecord, <int>[
          ..._toBytes32(_sessionId!),
          ..._toBytes32(0),
        ]);
      }
    } finally {
      _audioBuffer.clear();
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
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
    (value >> 32) & 0xFF,
    (value >> 40) & 0xFF,
    (value >> 48) & 0xFF,
    (value >> 56) & 0xFF,
  ];

  @override
  Future<void> dispose() async {
    await super.dispose();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          StateError('PLAUD disconnected before the command completed.'),
        );
      }
    }
    _pending.clear();
  }
}
