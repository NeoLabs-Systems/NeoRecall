import 'dart:async';
import 'package:desktop_audio_capture/audio_capture.dart';
import 'package:flutter/foundation.dart';

import 'capture_source.dart';

/// Desktop system-audio source (ScreenCaptureKit / WASAPI loopback).
class SystemAudioCaptureSource implements CaptureSource {
  SystemAudioCaptureSource({SystemAudioCapture? capture})
      : _capture = capture ??
            SystemAudioCapture(
              config: SystemAudioConfig(sampleRate: 16000, channels: 1),
            );

  final SystemAudioCapture _capture;
  StreamSubscription<Uint8List>? _subscription;
  final StreamController<Uint8List> _pcm = StreamController<Uint8List>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings = StreamController<String>.broadcast();
  bool _active = false;

  @override
  String get id => 'system_audio';
  @override
  String get kind => 'system';
  @override
  bool get isActive => _active;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<double> get levelStream => _levels.stream;
  @override
  Stream<String> get warningStream => _warnings.stream;

  @override
  Future<bool> ensurePermission() async {
    if (kIsWeb) return false;
    if (!(defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux)) {
      return false;
    }
    try {
      await _capture.requestPermissions();
      return true;
    } catch (_) {
      // Fall through to startCapture, which will surface a friendly warning.
      return true;
    }
  }

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (_active) return;
    if (!await ensurePermission()) {
      throw StateError('System audio capture is unavailable on this platform.');
    }
    await _capture.startCapture();
    _subscription = _capture.audioStream?.listen((data) {
      _pcm.add(data);
    }, onError: (Object error) {
      _warnings.add('System audio capture interrupted: $error');
    });
    _active = true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    if (_active) {
      try {
        await _capture.stopCapture();
      } catch (error) {
        _warnings.add('System audio stop failed: $error');
      }
    }
    _active = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _pcm.close();
    await _levels.close();
    await _warnings.close();
  }
}

CaptureSource? createPlatformSystemAudioSource() {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux) {
    return SystemAudioCaptureSource();
  }
  return null;
}
