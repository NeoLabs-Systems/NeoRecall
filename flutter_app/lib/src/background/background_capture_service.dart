import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Cross-platform façade for always-on mobile capture.
///
/// Android implementation uses a foreground service host. iOS remains a
/// conservative stub until a dedicated audio background mode is validated.
abstract class BackgroundCaptureService {
  Future<void> initialize();
  Future<bool> start({required String mode});
  Future<void> stop();
  Future<void> dispose();
  bool get isRunning;
  Stream<String> get events;
}

class UnsupportedBackgroundCaptureService implements BackgroundCaptureService {
  final StreamController<String> _events = StreamController<String>.broadcast();
  bool _running = false;

  @override
  bool get isRunning => _running;
  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> start({required String mode}) async {
    _events.add('Background capture is not available on this platform.');
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
  static const MethodChannel _channel =
      MethodChannel('systems.neolabs.neorecall/background_capture');
  final StreamController<String> _events = StreamController<String>.broadcast();
  bool _running = false;
  bool _initialized = false;

  @override
  bool get isRunning => _running;
  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> initialize() async {
    // The native Android foreground service host is registered in
    // android/app/.../MainActivity and AndroidManifest.
    final mic = await Permission.microphone.request();
    final notif = await Permission.notification.request();
    if (!mic.isGranted) {
      _events.add('Microphone permission is required for background capture.');
    }
    if (!notif.isGranted) {
      _events.add('Notification permission helps keep the capture service visible and alive.');
    }
    _initialized = true;
    _events.add('Android background capture host ready.');
  }

  @override
  Future<bool> start({required String mode}) async {
    if (!_initialized) await initialize();
    try {
      final mic = await Permission.microphone.status;
      if (!mic.isGranted) {
        final requested = await Permission.microphone.request();
        if (!requested.isGranted) {
          _events.add('Cannot start background capture without microphone permission.');
          return false;
        }
      }
      await _channel.invokeMethod<bool>('startBackgroundCapture', <String, Object?>{
        'mode': mode,
      });
      final running = await _channel.invokeMethod<bool>('isBackgroundCaptureRunning');
      _running = running ?? true;
      _events.add('Background capture requested for mode=$mode');
      return true;
    } on PlatformException catch (error) {
      _events.add('Background capture failed: ${error.message}');
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
    _events.add('Background capture stopped.');
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

BackgroundCaptureService createBackgroundCaptureService() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidBackgroundCaptureService();
  }
  return UnsupportedBackgroundCaptureService();
}
