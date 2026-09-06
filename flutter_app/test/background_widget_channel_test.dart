import 'dart:convert';

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

  test('battery optimization uses the native exemption flow', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'backgroundRuntimeState':
          return <String, Object?>{
            'running': false,
            'holds': <String>[],
            'foreground': true,
            'microphoneUnavailable': false,
          };
        case 'batteryOptimizationExempt':
          return false;
        case 'requestBatteryOptimizationExemption':
          return true;
        case 'stopBackgroundCapture':
          return true;
      }
      return null;
    });
    final service = AndroidBackgroundCaptureService();
    await service.initialize();

    expect(await service.batteryOptimizationExempt(), isFalse);
    await service.requestBatteryOptimizationExemption();

    expect(calls, contains('batteryOptimizationExempt'));
    expect(calls, contains('requestBatteryOptimizationExemption'));
    await service.dispose();
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

  test(
    'live status replaces the native notification through one payload',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'backgroundRuntimeState') {
          return <String, Object?>{
            'running': true,
            'holds': <String>['microphoneCapture'],
            'foreground': true,
            'microphoneUnavailable': false,
          };
        }
        return true;
      });
      final service = AndroidBackgroundCaptureService();
      await service.initialize();
      const status = BackgroundLiveStatus(
        phase: BackgroundLivePhase.uploading,
        title: 'Uploading recordings',
        detail: '12 minutes safely queued',
        progress: 0.4,
      );

      await service.updateLiveStatus(status);
      await service.updateLiveStatus(status);

      final updates = calls.where((call) => call.method == 'updateLiveStatus');
      expect(updates, hasLength(1));
      expect(
        Map<Object?, Object?>.from(updates.single.arguments as Map)['phase'],
        'uploading',
      );
      await service.dispose();
    },
  );

  test('an unchanged widget snapshot is not published twice', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
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
    const snapshot = HomeWidgetSnapshot(
      signedIn: true,
      capture: HomeWidgetCapture.idle,
      today: HomeWidgetToday.empty,
    );

    await service.publishWidgetSnapshot(snapshot);
    await service.publishWidgetSnapshot(snapshot);
    await service.publishWidgetSnapshot(HomeWidgetSnapshot.signedOut);

    final publishes = calls.where((call) => call.method == 'publishWidgetData');
    expect(publishes, hasLength(2));
    expect(
      jsonDecode(
        (publishes.first.arguments as Map)['payload'] as String,
      )['signedIn'],
      isTrue,
    );
    await service.dispose();
  });

  test('a snapshot the host refused is sent again next time', () async {
    var accept = false;
    final payloads = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backgroundRuntimeState') {
        return <String, Object?>{
          'running': false,
          'holds': <String>[],
          'foreground': true,
          'microphoneUnavailable': false,
        };
      }
      if (call.method == 'publishWidgetData') {
        if (!accept) throw PlatformException(code: 'NO_HOST');
        payloads.add((call.arguments as Map)['payload'] as String);
      }
      return true;
    });
    final service = AndroidBackgroundCaptureService();
    await service.initialize();
    const snapshot = HomeWidgetSnapshot(
      signedIn: true,
      capture: HomeWidgetCapture.idle,
      today: HomeWidgetToday.empty,
    );

    await service.publishWidgetSnapshot(snapshot);
    expect(payloads, isEmpty);
    accept = true;
    await service.publishWidgetSnapshot(snapshot);

    expect(payloads, hasLength(1));
    await service.dispose();
  });

  test('queued widget taps are claimed as typed actions', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backgroundRuntimeState') {
        return <String, Object?>{
          'running': false,
          'holds': <String>[],
          'foreground': true,
          'microphoneUnavailable': false,
        };
      }
      if (call.method == 'takePendingWidgetActions') {
        return <Object?>[
          <Object?, Object?>{'type': 'stopRecording', 'targetId': null},
          <Object?, Object?>{'type': 'completeHighlight', 'targetId': 'mini-1'},
          // A malformed row must not take the rest of the queue down with it.
          <Object?, Object?>{'type': '', 'targetId': 'ignored'},
        ];
      }
      return true;
    });
    final service = AndroidBackgroundCaptureService();
    await service.initialize();

    final actions = await service.takePendingWidgetActions();

    expect(actions.map((action) => action.type), <String>[
      HomeWidgetAction.stopRecording,
      HomeWidgetAction.completeHighlight,
    ]);
    expect(actions.last.targetId, 'mini-1');
    await service.dispose();
  });

  test(
    'watch download activity and failures reach the processing ledger',
    () async {
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
      final events = service.events.take(2).toList();

      for (final call in <MethodCall>[
        const MethodCall('watchTransferStarted'),
        const MethodCall('watchTransferFinished', <String, Object?>{
          'error': 'Link interrupted',
        }),
      ]) {
        await messenger.handlePlatformMessage(
          channelName,
          const StandardMethodCodec().encodeMethodCall(call),
          (ByteData? _) {},
        );
      }

      final received = await events;
      expect(
        received.first.type,
        BackgroundCaptureEventType.watchTransferStarted,
      );
      expect(
        received.last.type,
        BackgroundCaptureEventType.watchTransferFinished,
      );
      expect(received.last.message, 'Link interrupted');
      await service.dispose();
    },
  );
}
