import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/background/background_capture_service.dart';
import 'package:neorecall/src/capture/capture_source.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/devices/device_session_controller.dart';
import 'package:neorecall/src/recording/recorder_mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements AudioDeviceAdapter {
  final StreamController<AudioDeviceDescriptor> _discoveries =
      StreamController<AudioDeviceDescriptor>.broadcast();
  final StreamController<DeviceControlEvent> _controls =
      StreamController<DeviceControlEvent>.broadcast();
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();
  bool recording = false;

  @override
  String get id => 'fake';
  @override
  String get displayName => 'Fake wearable';
  @override
  String get transport => 'bluetooth';
  @override
  Stream<AudioDeviceDescriptor> get discoveries => _discoveries.stream;
  @override
  Stream<DeviceControlEvent> get controlEvents => _controls.stream;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<DeviceTransportState> get transportStates => _states.stream;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(AudioDeviceDescriptor device) async {
    _states.add(DeviceTransportState.connectedStandby);
  }

  @override
  Future<void> disconnect() async {
    _states.add(DeviceTransportState.disconnected);
  }

  @override
  Future<void> requestStartRecording() async {
    recording = true;
  }

  @override
  Future<void> requestStopRecording() async {
    recording = false;
  }

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _controls.close();
    await _pcm.close();
    await _states.close();
  }
}

class _RecordingBackgroundService implements BackgroundCaptureService {
  final List<BackgroundRuntimeRequest> applied = <BackgroundRuntimeRequest>[];
  final StreamController<BackgroundCaptureEvent> _events =
      StreamController<BackgroundCaptureEvent>.broadcast();
  BackgroundRuntimeRequest _active = BackgroundRuntimeRequest.idle;
  int stops = 0;

  @override
  BackgroundRuntimeRequest get active => _active;
  @override
  bool get isRunning => _active.isNotEmpty;
  @override
  BackgroundRuntimeState get state =>
      BackgroundRuntimeState(running: isRunning, holds: _active.holds, foreground: true);
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}
  @override
  Future<BackgroundRuntimeState> refreshState() async => state;

  @override
  Future<bool> apply(BackgroundRuntimeRequest request) async {
    applied.add(request);
    _active = request;
    return true;
  }

  @override
  Future<void> stop() async {
    stops += 1;
    _active = BackgroundRuntimeRequest.idle;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

const AudioDeviceDescriptor _descriptor = AudioDeviceDescriptor(
  adapterId: 'fake',
  deviceKey: 'fake:1',
  displayName: 'Fake wearable',
  transport: 'bluetooth',
  supportsHardwareButtons: true,
);

MobileRecallRecorder _buildRecorder(
  _FakeAdapter adapter,
  _RecordingBackgroundService background,
) {
  final registry = AudioDeviceAdapterRegistry()..register(adapter);
  return MobileRecallRecorder(
    registry: registry,
    devices: DeviceSessionController(registry: registry),
    background: background,
  );
}

void _mockPreferredDevice() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'preferred_audio_device_v2:account-1': jsonEncode(<String, Object?>{
      'adapterId': _descriptor.adapterId,
      'deviceKey': _descriptor.deviceKey,
      'displayName': _descriptor.displayName,
      'transport': _descriptor.transport,
      'supportsMicrophone': true,
      'supportsSystemAudio': false,
      'supportsHardwareButtons': true,
      'metadata': <String, Object?>{'type': 'heyPocket'},
      'preferBluetooth': true,
    }),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a paired wearable keeps the host alive with nothing recording', () async {
    _mockPreferredDevice();
    final adapter = _FakeAdapter();
    final background = _RecordingBackgroundService();
    final recorder = _buildRecorder(adapter, background);

    await recorder.initialize(accountId: 'account-1');

    expect(
      background.active.holds,
      <BackgroundHold>{BackgroundHold.wearableLink},
      reason: 'sync and reconnect must survive the UI being swiped away',
    );
    expect(background.active.deviceLabel, 'Fake wearable');
    await recorder.dispose();
  });

  test('no hold is taken when no wearable is paired', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final adapter = _FakeAdapter();
    final background = _RecordingBackgroundService();
    final recorder = _buildRecorder(adapter, background);

    await recorder.initialize(accountId: 'account-1');

    expect(background.active.isEmpty, isTrue);
    expect(background.isRunning, isFalse);
    await recorder.dispose();
  });

  test('capture adds its hold and stopping keeps the wearable link', () async {
    _mockPreferredDevice();
    final adapter = _FakeAdapter();
    final background = _RecordingBackgroundService();
    final recorder = _buildRecorder(adapter, background);
    await recorder.initialize(accountId: 'account-1');

    final capability = await recorder.start(
      microphone: false,
      systemAudio: false,
      chunkMs: 30000,
      overlapMs: 2000,
      externalDevice: ExternalAudioCaptureDevice(
        adapter: adapter,
        descriptor: _descriptor,
      ),
    );

    expect(capability.sourceKind, 'wearable');
    expect(adapter.recording, isTrue);
    expect(background.active.holds, <BackgroundHold>{
      BackgroundHold.wearableCapture,
      BackgroundHold.wearableLink,
    });

    await recorder.stop();
    await recorder.finishBackgroundHost();

    expect(
      background.active.holds,
      <BackgroundHold>{BackgroundHold.wearableLink},
      reason: 'ending a recording must not end background sync',
    );
    await recorder.dispose();
  });

  test('an in-flight device transfer keeps the CPU awake, idle polling does not',
      () async {
    _mockPreferredDevice();
    final adapter = _FakeAdapter();
    final background = _RecordingBackgroundService();
    final recorder = _buildRecorder(adapter, background);
    await recorder.initialize(accountId: 'account-1');

    expect(background.active.needsWakeLock, isFalse);

    await recorder.setDeviceSyncActive(true);
    expect(background.active.holds, contains(BackgroundHold.wearableSync));
    expect(background.active.needsWakeLock, isTrue);

    await recorder.setDeviceSyncActive(false);
    expect(background.active.holds, <BackgroundHold>{BackgroundHold.wearableLink});
    expect(background.active.needsWakeLock, isFalse);
    await recorder.dispose();
  });

  test('the notification Stop releases every hold until the app is opened',
      () async {
    _mockPreferredDevice();
    final adapter = _FakeAdapter();
    final background = _RecordingBackgroundService();
    final recorder = _buildRecorder(adapter, background);
    await recorder.initialize(accountId: 'account-1');

    await recorder.pauseBackgroundRuntime();
    expect(recorder.backgroundPaused, isTrue);
    expect(background.isRunning, isFalse);
    expect(recorder.devices.autoReconnect, isFalse);

    await recorder.resumeBackgroundRuntime();
    expect(recorder.backgroundPaused, isFalse);
    expect(recorder.devices.autoReconnect, isTrue);
    expect(background.active.holds, <BackgroundHold>{BackgroundHold.wearableLink});
    await recorder.dispose();
  });

  test('holds follow the sources that are actually streaming', () {
    expect(
      MobileRecallRecorder.holdsForSources(const <CaptureSource>[]),
      isEmpty,
    );
    expect(
      MobileRecallRecorder.holdsForSources(<CaptureSource>[
        _StubSource('microphone'),
        _StubSource('wearable'),
      ]),
      <BackgroundHold>{
        BackgroundHold.microphoneCapture,
        BackgroundHold.wearableCapture,
      },
    );
    // Desktop-only kinds have no mobile hold and must not invent one.
    expect(
      MobileRecallRecorder.holdsForSources(<CaptureSource>[
        _StubSource('system'),
      ]),
      isEmpty,
    );
  });
}

class _StubSource implements CaptureSource {
  _StubSource(this.kind);
  @override
  final String kind;
  @override
  String get id => 'stub:$kind';
  @override
  bool get isActive => true;
  @override
  Stream<Uint8List> get pcm16Stream => const Stream<Uint8List>.empty();
  @override
  Stream<double> get levelStream => const Stream<double>.empty();
  @override
  Stream<String> get warningStream => const Stream<String>.empty();
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<void> start({required int sampleRate, required int channels}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
