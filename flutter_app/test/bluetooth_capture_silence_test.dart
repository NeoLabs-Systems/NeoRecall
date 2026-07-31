import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/capture/bluetooth_capture_source.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';

/// A connected wearable that sends nothing looks exactly like a working
/// recording — the timer runs, the pipeline is live, the file is empty. Real
/// hardware does this: an Omi CV 1 on firmware 3.0.20 answered its storage
/// protocol perfectly while delivering zero live-audio packets. Without this
/// warning the user finds out only when the transcript is missing.
void main() {
  const device = AudioDeviceDescriptor(
    adapterId: 'stub',
    deviceKey: 'dev-1',
    displayName: 'Omi',
    transport: 'bluetooth_le',
  );

  test('a capture that receives no audio says so', () async {
    final adapter = _StubAdapter();
    final source = BluetoothCaptureSource(
      adapter: adapter,
      device: device,
      connectOnStart: false,
      firstAudioTimeout: const Duration(milliseconds: 40),
    );
    final warning = source.warningStream.first;

    await source.start(sampleRate: 16000, channels: 1);

    expect(await warning.timeout(const Duration(seconds: 2)),
        contains('has not sent any audio'));
    await source.dispose();
  });

  test('a device that streams normally is never accused', () async {
    final adapter = _StubAdapter();
    final source = BluetoothCaptureSource(
      adapter: adapter,
      device: device,
      connectOnStart: false,
      firstAudioTimeout: const Duration(milliseconds: 40),
    );
    final warnings = <String>[];
    source.warningStream.listen(warnings.add);

    await source.start(sampleRate: 16000, channels: 1);
    adapter.emit(Uint8List.fromList(<int>[0, 0, 1, 0]));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(warnings, isEmpty);
    await source.dispose();
  });

  test('the warning does not fire again after a restart that works', () async {
    // stop() must reset the watchdog, or a second capture would inherit the
    // first one's "already saw audio" state and never warn again.
    final adapter = _StubAdapter();
    final source = BluetoothCaptureSource(
      adapter: adapter,
      device: device,
      connectOnStart: false,
      firstAudioTimeout: const Duration(milliseconds: 40),
    );
    await source.start(sampleRate: 16000, channels: 1);
    adapter.emit(Uint8List.fromList(<int>[0, 0]));
    await source.stop();

    final warning = source.warningStream.first;
    await source.start(sampleRate: 16000, channels: 1);
    expect(await warning.timeout(const Duration(seconds: 2)),
        contains('has not sent any audio'));
    await source.dispose();
  });
}

class _StubAdapter implements AudioDeviceAdapter {
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();

  void emit(Uint8List data) => _pcm.add(data);

  @override
  String get id => 'stub';
  @override
  String get displayName => 'Stub';
  @override
  String get transport => 'bluetooth_le';

  @override
  Stream<AudioDeviceDescriptor> get discoveries =>
      const Stream<AudioDeviceDescriptor>.empty();
  @override
  Stream<DeviceControlEvent> get controlEvents =>
      const Stream<DeviceControlEvent>.empty();
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<DeviceTransportState> get transportStates =>
      const Stream<DeviceTransportState>.empty();

  @override
  Future<void> initialize() async {}
  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(AudioDeviceDescriptor device) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> requestStartRecording() async {}
  @override
  Future<void> requestStopRecording() async {}
  @override
  Future<void> dispose() async => _pcm.close();
}
