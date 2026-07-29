import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'capture_source.dart';

/// Shared microphone source used by desktop and mobile.
class MicrophoneCaptureSource implements CaptureSource {
  MicrophoneCaptureSource({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _subscription;
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  bool _active = false;

  @override
  String get id => 'microphone';
  @override
  String get kind => 'microphone';
  @override
  bool get isActive => _active;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<double> get levelStream => _levels.stream;
  @override
  Stream<String> get warningStream => _warnings.stream;

  @override
  Future<bool> ensurePermission() => _recorder.hasPermission();

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    if (_active) return;
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
      (data) {
        _pcm.add(data);
        _emitLevel(data);
      },
      onError: (Object error) {
        _warnings.add('Microphone capture interrupted: $error');
      },
    );
    _active = true;
  }

  void _emitLevel(Uint8List data) {
    if (data.length < 2) return;
    final view = ByteData.sublistView(data);
    var energy = 0.0;
    var samples = 0;
    for (var offset = 0; offset + 1 < data.length; offset += 8) {
      final value = view.getInt16(offset, Endian.little) / 32768.0;
      energy += value * value;
      samples += 1;
    }
    if (samples > 0) {
      _levels.add(math.sqrt(energy / samples).clamp(0.0, 1.0));
    }
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    if (_active) {
      try {
        await _recorder.stop();
      } catch (error) {
        _warnings.add('Microphone stop failed: $error');
      }
    }
    _active = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    await _pcm.close();
    await _levels.close();
    await _warnings.close();
  }
}

/// Factory keeps web free of the record package path when needed.
CaptureSource? createPlatformMicrophoneSource() {
  if (kIsWeb) return null;
  return MicrophoneCaptureSource();
}
