import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_record.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/record/record_sheets.dart';
import 'package:neorecall/src/recording/audio_frame.dart';
import 'package:neorecall/src/recording/recorder.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scan used to dismiss the sheet that would have shown the results. Both the
/// source sheet ("change") and the device sheet have to keep the scan in place
/// and list what it finds.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    theme: buildNeoRecallTheme(Brightness.dark),
    home: Scaffold(body: child),
  );

  // A non-mobile recorder so the injected registry is used. On Android (the
  // test default) the controller would otherwise take the real BLE adapter.
  NeoRecallController controllerWith(_StubAdapter adapter) =>
      NeoRecallController(
        recorder: _IdleRecorder(),
        audioDeviceRegistry: AudioDeviceAdapterRegistry()..register(adapter),
      );

  testWidgets(
    'the change-source sheet scans in place and lists what it finds',
    (tester) async {
      const found = AudioDeviceDescriptor(
        adapterId: 'stub',
        deviceKey: 'dev-1',
        displayName: 'Omi One',
        transport: 'bluetooth_le',
        metadata: <String, Object?>{'type': 'omi'},
      );
      final controller = controllerWith(_StubAdapter(emit: found));
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('change'));
      await tester.pumpAndSettle();

      expect(find.text('Record from'), findsOneWidget);
      expect(find.text('Scan'), findsOneWidget);

      await tester.tap(find.text('Scan'));
      await tester.pump();

      // The sheet stays open while the scan runs. Closing it was why a tap
      // looked like it did nothing: results had nowhere to appear.
      expect(find.text('Record from'), findsOneWidget);
      expect(find.text('Scanning…'), findsOneWidget);

      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();

      expect(find.text('Record from'), findsOneWidget);
      expect(find.text('FOUND NEARBY'), findsOneWidget);
      expect(find.text('Omi One'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a paired wearable still offers Scan in the change-source sheet',
    (tester) async {
      final controller = controllerWith(_StubAdapter())
        ..preferredDeviceLabel = 'PKT01';
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('change'));
      await tester.pumpAndSettle();

      expect(find.text('PKT01'), findsWidgets);
      expect(find.text('Scan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the device sheet scans in place instead of dismissing', (
    tester,
  ) async {
    const found = AudioDeviceDescriptor(
      adapterId: 'stub',
      deviceKey: 'dev-2',
      displayName: 'Memoket Gem',
      transport: 'bluetooth_le',
      metadata: <String, Object?>{'type': 'memoket'},
    );
    final controller = controllerWith(_StubAdapter(emit: found))
      ..preferredDeviceLabel = 'PKT01';
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(DeviceChip.chipKey));
    await tester.pumpAndSettle();

    expect(find.text('Scan for another wearable'), findsOneWidget);
    expect(find.text('Forget this device'), findsOneWidget);

    await tester.tap(find.text('Scan for another wearable'));
    await tester.pump();

    expect(find.text('Forget this device'), findsOneWidget);
    expect(find.text('Scanning…'), findsOneWidget);

    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    expect(find.text('Forget this device'), findsOneWidget);
    expect(find.text('FOUND NEARBY'), findsOneWidget);
    expect(find.text('Memoket Gem'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an empty device sheet keeps the scan open and shows what it finds',
    (tester) async {
      const found = AudioDeviceDescriptor(
        adapterId: 'stub',
        deviceKey: 'dev-3',
        displayName: 'Pocket recorder',
        transport: 'bluetooth_le',
        metadata: <String, Object?>{'type': 'heyPocket'},
      );
      final controller = controllerWith(_StubAdapter(emit: found));
      addTearDown(controller.dispose);

      await tester.pumpWidget(wrap(RecordScreen(controller: controller)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(DeviceChip.chipKey));
      await tester.pumpAndSettle();

      expect(find.text('No device yet'), findsOneWidget);
      await tester.tap(find.text('Scan for wearables'));
      await tester.pump();

      expect(find.text('No device yet'), findsOneWidget);
      expect(find.text('Scanning…'), findsOneWidget);

      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();

      expect(find.text('No device yet'), findsOneWidget);
      expect(find.text('Pocket recorder'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

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
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final device = emit;
    if (device != null) _discoveries.add(device);
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

class _IdleRecorder implements RecallRecorder {
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
  bool get isRecording => false;

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) async => const RecorderCapability(
    microphone: true,
    systemAudio: false,
    persistentStorage: false,
    sampleRate: 16000,
    sourceKind: 'microphone',
  );

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
