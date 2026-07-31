import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../devices/audio_device_adapter.dart';
import 'capture_source.dart';

/// Bridges a connected external device adapter into the shared capture pipeline.
class BluetoothCaptureSource implements CaptureSource {
  BluetoothCaptureSource({
    required this.adapter,
    required this.device,
    this.connectOnStart = true,
    this.firstAudioTimeout = const Duration(seconds: 90),
  });

  final AudioDeviceAdapter adapter;
  final AudioDeviceDescriptor device;
  final bool connectOnStart;

  /// How long a started capture may receive nothing before saying so.
  ///
  /// A connected wearable that streams no audio looks exactly like a working
  /// recording: the timer runs, the pipeline is live, and the file is empty.
  /// Some devices legitimately stay quiet (Omi only sends on acoustic activity),
  /// so this window is generous and only *warns* — it never stops the capture,
  /// because a wrongly-stopped recording loses audio while a wrong warning
  /// costs nothing.
  final Duration firstAudioTimeout;

  Timer? _firstAudioTimer;
  bool _sawAudio = false;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  bool _active = false;

  @override
  String get id => 'bluetooth:${device.deviceKey}';
  @override
  String get kind => 'wearable';
  @override
  bool get isActive => _active;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<double> get levelStream => _levels.stream;
  @override
  Stream<String> get warningStream => _warnings.stream;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (_active) return;
    if (connectOnStart) await adapter.connect(device);
    _subs.add(
      adapter.pcm16Stream.listen(
        (pcm) {
          if (!_sawAudio) {
            _sawAudio = true;
            _firstAudioTimer?.cancel();
          }
          _pcm.add(pcm);
          _emitLevel(pcm);
        },
        onError: (Object error) {
          _warnings.add('Bluetooth audio stream interrupted: $error');
        },
      ),
    );
    _subs.add(
      adapter.transportStates.listen((state) {
        if (state == DeviceTransportState.faulted ||
            state == DeviceTransportState.disconnected) {
          _warnings.add('Bluetooth device entered $state');
        }
      }),
    );
    _subs.add(
      adapter.controlEvents.listen((event) {
        if (event.type == DeviceControlEventType.custom &&
            event.payload['warning'] is String) {
          _warnings.add(event.payload['warning'] as String);
        }
        if (event.type == DeviceControlEventType.stopRecording) {
          _warnings.add('Hardware stop pressed on ${device.displayName}');
        }
      }),
    );
    await adapter.requestStartRecording();
    _firstAudioTimer = Timer(firstAudioTimeout, () {
      if (_sawAudio || !_active) return;
      _warnings.add(
        '${device.displayName} is connected but has not sent any audio yet. '
        'If it records on its own, sync its storage instead.',
      );
    });
    _active = true;
  }

  void _emitLevel(Uint8List data) {
    if (data.length < 2) return;
    final view = ByteData.sublistView(data);
    var energy = 0.0;
    var samples = 0;
    for (var offset = 0; offset + 1 < data.length; offset += 8) {
      final value = view.getInt16(offset, Endian.little) / 32768.0;
      energy += value * value;
      samples += 1;
    }
    if (samples > 0) {
      _levels.add(math.sqrt(energy / samples).clamp(0.0, 1.0));
    }
  }

  @override
  Future<void> stop() async {
    _firstAudioTimer?.cancel();
    _firstAudioTimer = null;
    _sawAudio = false;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (_active) {
      try {
        await adapter.requestStopRecording();
      } catch (error) {
        _warnings.add('Bluetooth stop failed: $error');
      }
    }
    _active = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _pcm.close();
    await _levels.close();
    await _warnings.close();
  }
}
