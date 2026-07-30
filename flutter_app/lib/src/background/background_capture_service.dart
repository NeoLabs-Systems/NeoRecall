import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cross-platform façade for always-on mobile capture.
///
/// Android implementation uses a foreground service host. iOS is deliberately
/// unsupported here because a user force-quit cannot be recovered by iOS.
abstract class BackgroundCaptureService {
  Future<void> initialize();
  Future<bool> start({required String mode});
  Future<void> stop();
  Future<void> dispose();
  bool get isRunning;
  Stream<BackgroundCaptureEvent> get events;
}

enum BackgroundCaptureEventType { message, stopRequested, batteryOptimizationActive }

class BackgroundCaptureEvent {
  const BackgroundCaptureEvent(this.type, {this.message});

  final BackgroundCaptureEventType type;
  final String? message;
}

class UnsupportedBackgroundCaptureService implements BackgroundCaptureService {
  final StreamController<BackgroundCaptureEvent> _events =
      StreamController<BackgroundCaptureEvent>.broadcast();
  bool _running = false;

  @override
  bool get isRunning => _running;
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> start({required String mode}) async {
    _events.add(
      const BackgroundCaptureEvent(
        BackgroundCaptureEventType.message,
        message: 'Background capture is not available on this platform.',
      ),
    );
    return false;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

class AndroidBackgroundCaptureService implements BackgroundCaptureService {
  static const MethodChannel _channel = MethodChannel(
    'systems.neolabs.neorecall/background_capture',
  );
  final StreamController<BackgroundCaptureEvent> _events =
      StreamController<BackgroundCaptureEvent>.broadcast();
  bool _running = false;
  bool _initialized = false;

  @override
  bool get isRunning => _running;
  @override
  Stream<BackgroundCaptureEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'backgroundStopRequested') {
        _events.add(
          const BackgroundCaptureEvent(
            BackgroundCaptureEventType.stopRequested,
          ),
        );
      }
    });
    try {
      _running =
          await _channel.invokeMethod<bool>('isBackgroundCaptureRunning') ??
          false;
    } on PlatformException catch (error) {
      _running = false;
      _message(
        'Android background capture host is temporarily unavailable: ${error.message ?? error.code}',
      );
    }
    _initialized = true;
    _message('Android background capture host ready.');
  }

  @override
  Future<bool> start({required String mode}) async {
    if (!_initialized) await initialize();
    try {
      final notification = await Permission.notification.request();
      if (!notification.isGranted) {
        _message(
          'Cannot start reliable background capture without notification permission.',
        );
        return false;
      }
      if (mode == 'microphone') {
        final microphone = await Permission.microphone.request();
        if (!microphone.isGranted) {
          _message(
            'Cannot start background capture without microphone permission.',
          );
          return false;
        }
      }
      final preferences = await SharedPreferences.getInstance();
      var batteryOptimization =
          await Permission.ignoreBatteryOptimizations.status;
      if (!batteryOptimization.isGranted &&
          !(preferences.getBool('batteryOptimizationPrompted') ?? false)) {
        await preferences.setBool('batteryOptimizationPrompted', true);
        batteryOptimization = await Permission.ignoreBatteryOptimizations
            .request();
      }
      if (!batteryOptimization.isGranted) {
        _message(
          'Battery optimization is still active; Android or the device vendor may suspend long-running capture.',
        );
        _events.add(
          const BackgroundCaptureEvent(
            BackgroundCaptureEventType.batteryOptimizationActive,
          ),
        );
      }
      await _channel.invokeMethod<bool>(
        'startBackgroundCapture',
        <String, Object?>{'mode': mode},
      );
      final running = await _channel.invokeMethod<bool>(
        'isBackgroundCaptureRunning',
      );
      _running = running ?? true;
      _message('Background capture requested for mode=$mode');
      return _running;
    } on PlatformException catch (error) {
      _message('Background capture failed: ${error.message}');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    try {
      await _channel.invokeMethod<bool>('stopBackgroundCapture');
    } catch (_) {
      // Best-effort stop; Dart-side state still clears.
    }
    _running = false;
    _message('Background capture stopped.');
  }

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    await _events.close();
  }

  void _message(String value) {
    _events.add(
      BackgroundCaptureEvent(
        BackgroundCaptureEventType.message,
        message: value,
      ),
    );
  }
}

BackgroundCaptureService createBackgroundCaptureService() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidBackgroundCaptureService();
  }
  return UnsupportedBackgroundCaptureService();
}
