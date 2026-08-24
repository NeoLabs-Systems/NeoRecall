import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/background/background_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'systems.neolabs.neorecall/background_capture';
  const channel = MethodChannel(channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a persisted widget tap is claimed exactly once', () async {
    var pending = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'backgroundRuntimeState':
          return <String, Object?>{
            'running': false,
            'holds': <String>[],
            'foreground': true,
            'microphoneUnavailable': false,
          };
        case 'takePendingWidgetPhoneRecordingRequest':
          final result = pending;
          pending = false;
          return result;
        case 'stopBackgroundCapture':
          return true;
      }
      return null;
    });
    final service = AndroidBackgroundCaptureService();
    await service.initialize();

    expect(await service.takePendingWidgetPhoneRecordingRequest(), isTrue);
    expect(await service.takePendingWidgetPhoneRecordingRequest(), isFalse);

    await service.dispose();
  });

  test('a warm widget tap reaches the background event stream', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backgroundRuntimeState') {
        return <String, Object?>{
          'running': false,
          'holds': <String>[],
          'foreground': true,
          'microphoneUnavailable': false,
        };
      }
      return true;
    });
    final service = AndroidBackgroundCaptureService();
    await service.initialize();
    final event = service.events.firstWhere(
      (value) =>
          value.type == BackgroundCaptureEventType.phoneRecordingRequested,
    );

    final encoded = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('widgetPhoneRecordingRequested'),
    );
    await messenger.handlePlatformMessage(
      channelName,
      encoded,
      (ByteData? _) {},
    );

    expect(
      (await event).type,
      BackgroundCaptureEventType.phoneRecordingRequested,
    );
    await service.dispose();
  });
}
