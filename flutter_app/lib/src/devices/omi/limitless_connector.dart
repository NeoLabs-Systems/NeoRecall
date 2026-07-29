import 'dart:async';

import 'base_connector.dart';
import 'device_models.dart';

/// Limitless pendant protocol (command/notify style).
///
/// The full Omi Limitless connector is large; this port implements the
/// capture-critical path: connect, subscribe RX, start/stop capture, stream
/// audio frames. Advanced sync/file transfer can be extended later.
class LimitlessConnector extends WearableConnector {
  LimitlessConnector({required super.device, required super.transport});

  final Map<int, Completer<List<int>>> _pending = <int, Completer<List<int>>>{};

  @override
  WearableAudioCodec get codec => WearableAudioCodec.opus;

  @override
  Future<void> onConnected() async {
    // Limitless often requires bonding for reliable capture.
    track(
      transport
          .getCharacteristicStream(
            WearableDeviceUuids.limitlessService,
            WearableDeviceUuids.limitlessRx,
          )
          .listen(_handleNotify),
    );
  }

  void _handleNotify(List<int> data) {
    if (data.isEmpty) return;
    // Audio frames are pushed as bulk notify payloads; command replies are short.
    if (data.length > 8) {
      audioBytes.add(data);
      return;
    }
    final code = data.first;
    final payload = data.length > 1 ? data.sublist(1) : <int>[];
    final completer = _pending.remove(code);
    if (completer != null && !completer.isCompleted) {
      completer.complete(payload);
    }
  }

  Future<List<int>?> _send(int code, [List<int> payload = const <int>[]]) async {
    final completer = Completer<List<int>>();
    _pending[code] = completer;
    await transport.writeCharacteristic(
      WearableDeviceUuids.limitlessService,
      WearableDeviceUuids.limitlessTx,
      <int>[code, ...payload],
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
    // 0x01 is used by the Omi Limitless path as a capture-start style command.
    await _send(0x01);
    recording = true;
  }

  @override
  Future<void> stopRecording() async {
    if (!recording) return;
    await _send(0x02);
    recording = false;
  }
}
