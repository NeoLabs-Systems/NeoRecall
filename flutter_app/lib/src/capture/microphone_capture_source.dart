import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'capture_source.dart';
import 'capture_source_base.dart';

/// Shared microphone source used by desktop and mobile.
class MicrophoneCaptureSource extends CaptureSourceBase {
  MicrophoneCaptureSource({AudioRecorder? recorder})
    // PCM has exactly one pipeline consumer. A single-subscription controller
    // queues frames produced during the small window between native startup and
    // the pipeline attaching, instead of dropping those first samples.
    : _recorder = recorder ?? AudioRecorder(),
      super(broadcastPcm: false);

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _subscription;
  bool _started = false;
  bool _stopping = false;

  @override
  String get id => 'microphone';
  @override
  String get kind => 'microphone';

  @override
  Future<bool> ensurePermission() => _recorder.hasPermission();

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (isActive) return;
    if (!await ensurePermission()) {
      throw StateError('Microphone permission was not granted.');
    }
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    _subscription = stream.listen(
      emitPcm,
      onError: (Object error) => failCapture(
        'Microphone capture interrupted: $error',
        error,
        stopping: _stopping,
      ),
      onDone: () {
        if (_stopping) {
          active = false;
          return;
        }
        final error = StateError('Microphone audio stream ended unexpectedly.');
        failCapture(error.message, error);
      },
    );
    _started = true;
    active = true;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    final subscription = _subscription;
    if (_started) {
      try {
        // Keep the stream subscription attached until the native recorder has
        // stopped so PCM already read by Android can still reach the pipeline.
        await _recorder.stop();
      } catch (error) {
        warn('Microphone stop failed: $error');
      }
    }
    await Future<void>.delayed(Duration.zero);
    await subscription?.cancel();
    _subscription = null;
    _started = false;
    active = false;
    _stopping = false;
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _recorder.dispose();
  }
}

/// Factory keeps web free of the record package path when needed.
CaptureSource? createPlatformMicrophoneSource() {
  if (kIsWeb) return null;
  return MicrophoneCaptureSource();
}
