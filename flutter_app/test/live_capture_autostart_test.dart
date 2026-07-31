import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/recording/audio_frame.dart';
import 'package:neorecall/src/recording/recorder.dart';

/// A pendant that reconnects on its own should resume recording on its own —
/// otherwise "always-on" means "always-on as long as you remember to open the
/// app". But starting a recording unprompted is the one action in this app that
/// must never happen by accident, so every gate is pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Auto-start is mobile-only, so these tests must run as mobile. An injected
  // recorder keeps the real MobileRecallRecorder (and its platform channels)
  // out of the way while the platform still reads as Android.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  const omi = AudioDeviceDescriptor(
    adapterId: 'stub',
    deviceKey: 'dev-1',
    displayName: 'Omi',
    transport: 'bluetooth_le',
    metadata: <String, Object?>{'type': 'omi'},
  );

  NeoRecallController armed({
    AudioDeviceDescriptor? device = omi,
    bool consent = true,
    bool preferBluetooth = true,
    _StubRecorder? recorder,
  }) {
    final controller = NeoRecallController(
      recorder: recorder ?? _StubRecorder(),
      audioDeviceRegistry: AudioDeviceAdapterRegistry()..register(_StubAdapter()),
    );
    // authenticated is derived from a real token + account, so both are set
    // rather than faked; that is exactly the state a signed-in app is in.
    controller.api.token = 'test-token';
    controller.accountId = 'acct-1';
    controller.consentAccepted = consent;
    controller.preferBluetoothCapture = preferBluetooth;
    controller.audioDeviceSessions.preferredDevice = device;
    addTearDown(controller.dispose);
    return controller;
  }

  test('a linked live wearable starts capture on its own', () {
    expect(armed().shouldAutoStartLiveCapture, isTrue);
  });

  test('never before consent is given', () {
    // The app has no covert mode: without an accepted consent there is no
    // recording, least of all one the user did not ask for.
    expect(armed(consent: false).shouldAutoStartLiveCapture, isFalse);
  });

  test('never when the user did not choose Bluetooth capture', () {
    expect(armed(preferBluetooth: false).shouldAutoStartLiveCapture, isFalse);
  });

  test('never while signed out', () {
    final controller = armed();
    controller.api.token = null;
    expect(controller.shouldAutoStartLiveCapture, isFalse);
  });

  test('never for an offline-first recorder, whose sync is the point', () {
    // HeyPocket records to its own flash; there is no live stream to start and
    // claiming the channel would only stall the drain.
    const heyPocket = AudioDeviceDescriptor(
      adapterId: 'stub',
      deviceKey: 'dev-2',
      displayName: 'PKT01',
      transport: 'bluetooth_le',
      metadata: <String, Object?>{'type': 'heyPocket'},
    );
    expect(armed(device: heyPocket).shouldAutoStartLiveCapture, isFalse);
  });

  test('never without a remembered device', () {
    expect(armed(device: null).shouldAutoStartLiveCapture, isFalse);
  });

  test('never on desktop, where the user drives capture directly', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(armed().shouldAutoStartLiveCapture, isFalse);
  });

  test('never a second time while a capture is already running', () {
    final recorder = _StubRecorder();
    final controller = armed(recorder: recorder);
    recorder.isRecording = true;
    expect(controller.shouldAutoStartLiveCapture, isFalse);
  });
}

class _StubRecorder implements RecallRecorder {
  @override
  Stream<RecordedAudioChunk> get chunks =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<RecordedAudioChunk> get partials =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<String> get warnings => const Stream<String>.empty();
  @override
  Stream<double> get levels => const Stream<double>.empty();
  @override
  bool isRecording = false;

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) async => const RecorderCapability(
    microphone: false,
    systemAudio: false,
    persistentStorage: false,
    sampleRate: 16000,
    sourceKind: 'stub',
  );

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _StubAdapter implements AudioDeviceAdapter {
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
  Stream<Uint8List> get pcm16Stream => const Stream<Uint8List>.empty();
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
  Future<void> dispose() async {}
}
