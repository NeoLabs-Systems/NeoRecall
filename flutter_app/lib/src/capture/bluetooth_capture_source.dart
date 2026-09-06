import 'dart:async';

import '../devices/audio_device_adapter.dart';
import 'capture_source_base.dart';

/// Bridges a connected external device adapter into the shared capture pipeline.
class BluetoothCaptureSource extends CaptureSourceBase {
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
  bool _stopping = false;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  @override
  String get id => 'bluetooth:${device.deviceKey}';
  @override
  String get kind => 'wearable';

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (isActive) return;
    if (connectOnStart) await adapter.connect(device);
    _subs.add(
      adapter.pcm16Stream.listen(
        (pcm) {
          if (!_sawAudio) {
            _sawAudio = true;
            _firstAudioTimer?.cancel();
          }
          emitPcm(pcm);
        },
        onError: (Object error) => failCapture(
          'Bluetooth audio stream interrupted: $error',
          error,
          stopping: _stopping,
        ),
      ),
    );
    _subs.add(
      adapter.transportStates.listen((state) {
        if (state == DeviceTransportState.faulted ||
            state == DeviceTransportState.disconnected) {
          warn('Bluetooth device entered $state');
        }
      }),
    );
    _subs.add(
      adapter.controlEvents.listen((event) {
        if (event.type == DeviceControlEventType.custom &&
            event.payload['warning'] is String) {
          warn(event.payload['warning'] as String);
        }
        if (event.type == DeviceControlEventType.stopRecording) {
          warn('Hardware stop pressed on ${device.displayName}');
        }
      }),
    );
    await adapter.requestStartRecording();
    _firstAudioTimer = Timer(firstAudioTimeout, () {
      if (_sawAudio || !isActive) return;
      warn(
        '${device.displayName} is connected but has not sent any audio yet. '
        'If it records on its own, sync its storage instead.',
      );
    });
    active = true;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _firstAudioTimer?.cancel();
    _firstAudioTimer = null;
    _sawAudio = false;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (isActive) {
      try {
        await adapter.requestStopRecording();
      } catch (error) {
        warn('Bluetooth stop failed: $error');
      }
    }
    active = false;
    _stopping = false;
  }
}
