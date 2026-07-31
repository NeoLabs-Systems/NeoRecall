import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';

/// A scan that finds nothing must say so. Silently leaving an empty list on
/// screen is indistinguishable from a broken scan — which is exactly how the
/// Android permission bug presented (scan ran, returned zero results, no error).
void main() {
  // The controller reaches platform channels on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test reports Android by default, which makes the controller build a
  // MobileRecallRecorder and use ITS registry (the real BLE adapter) instead of
  // an injected one. Posing as desktop keeps the injected registry in play.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  // A registry holding only the stub: the real BLE adapter would reach
  // universal_ble's platform channel, which does not exist in a unit test.
  NeoRecallController controllerWith(_StubAdapter adapter) =>
      NeoRecallController(
        audioDeviceRegistry: AudioDeviceAdapterRegistry()..register(adapter),
      );

  test('a scan that finds nothing explains why instead of staying silent', () async {
    final adapter = _StubAdapter();
    final controller = controllerWith(adapter);
    addTearDown(controller.dispose);

    await controller.scanForWearables(timeout: const Duration(milliseconds: 10));

    expect(controller.discoveredWearables, isEmpty);
    expect(controller.scanningWearables, isFalse);
    expect(controller.notice, isNotNull);
    expect(controller.notice, contains('No supported device found'));
  });

  test('a scan that finds a device reports no failure notice', () async {
    const found = AudioDeviceDescriptor(
      adapterId: 'stub',
      deviceKey: 'dev-1',
      displayName: 'Omi',
      transport: 'bluetooth_le',
    );
    final controller = controllerWith(_StubAdapter(emit: found));
    addTearDown(controller.dispose);

    await controller.scanForWearables(timeout: const Duration(milliseconds: 30));

    expect(controller.discoveredWearables.single.deviceKey, 'dev-1');
    expect(controller.notice, isNull);
  });

  test('a stale notice from a previous empty scan does not survive the next', () async {
    const found = AudioDeviceDescriptor(
      adapterId: 'stub',
      deviceKey: 'dev-1',
      displayName: 'Omi',
      transport: 'bluetooth_le',
    );
    final adapter = _StubAdapter();
    final controller = controllerWith(adapter);
    addTearDown(controller.dispose);

    await controller.scanForWearables(timeout: const Duration(milliseconds: 10));
    expect(controller.notice, isNotNull);

    adapter.emit = found;
    await controller.scanForWearables(timeout: const Duration(milliseconds: 30));
    expect(controller.notice, isNull, reason: 'the successful scan clears the old message');
  });
}

/// Minimal adapter that optionally announces one device when a scan starts.
class _StubAdapter implements AudioDeviceAdapter {
  _StubAdapter({this.emit});

  AudioDeviceDescriptor? emit;
  final StreamController<AudioDeviceDescriptor> _discoveries =
      StreamController<AudioDeviceDescriptor>.broadcast();

  @override
  String get id => 'stub';
  @override
  String get displayName => 'Stub';
  @override
  String get transport => 'bluetooth_le';

  @override
  Stream<AudioDeviceDescriptor> get discoveries => _discoveries.stream;
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
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) async {
    final device = emit;
    if (device != null) scheduleMicrotask(() => _discoveries.add(device));
  }

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
  Future<void> dispose() async => _discoveries.close();
}
