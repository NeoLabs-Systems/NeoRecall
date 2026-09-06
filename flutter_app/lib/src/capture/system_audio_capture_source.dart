import 'dart:async';

import 'package:desktop_audio_capture/audio_capture.dart';
import 'package:flutter/foundation.dart';

import 'capture_source.dart';
import 'capture_source_base.dart';

/// Desktop system-audio source (ScreenCaptureKit / WASAPI loopback).
class SystemAudioCaptureSource extends CaptureSourceBase {
  SystemAudioCaptureSource({SystemAudioCapture? capture})
    : _capture =
          capture ??
          SystemAudioCapture(
            config: SystemAudioConfig(sampleRate: 16000, channels: 1),
          );

  final SystemAudioCapture _capture;
  StreamSubscription<Uint8List>? _subscription;
  bool _stopping = false;

  @override
  String get id => 'system_audio';
  @override
  String get kind => 'system';

  @override
  Future<bool> ensurePermission() async {
    if (kIsWeb) return false;
    if (!(defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows)) {
      return false;
    }
    try {
      return await _capture.requestPermissions();
    } catch (error) {
      warn('System audio permission was not granted: $error');
      return false;
    }
  }

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (isActive) return;
    if (!await ensurePermission()) {
      throw StateError('System audio capture is unavailable on this platform.');
    }
    await _capture.startCapture();
    final stream = _capture.audioStream;
    if (stream == null) {
      await _capture.stopCapture();
      throw StateError('System audio stream did not become available.');
    }
    _subscription = stream.listen(
      emitPcm,
      onError: (Object error) => failCapture(
        'System audio capture interrupted: $error',
        error,
        stopping: _stopping,
      ),
      onDone: () {
        if (_stopping) {
          active = false;
          return;
        }
        final error = StateError('System audio stream ended unexpectedly.');
        failCapture(error.message, error);
      },
    );
    active = true;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    await _subscription?.cancel();
    _subscription = null;
    if (isActive) {
      try {
        await _capture.stopCapture();
      } catch (error) {
        warn('System audio stop failed: $error');
      }
    }
    active = false;
    _stopping = false;
  }
}

CaptureSource? createPlatformSystemAudioSource() {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows) {
    return SystemAudioCaptureSource();
  }
  return null;
}
