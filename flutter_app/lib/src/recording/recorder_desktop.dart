import 'dart:async';

import '../capture/capture_pipeline.dart';
import '../capture/capture_source.dart';
import '../capture/microphone_capture_source.dart';
import '../capture/system_audio_capture_source.dart';
import 'audio_frame.dart';
import 'recorder.dart';

RecallRecorder createRecorder() => DesktopRecallRecorder();

class DesktopRecallRecorder implements RecallRecorder {
  CapturePipeline? _pipeline;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  final StreamController<RecordedAudioChunk> _chunks =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<RecordedAudioChunk> _partials =
      StreamController<RecordedAudioChunk>.broadcast();
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();

  @override
  Stream<RecordedAudioChunk> get chunks => _chunks.stream;
  @override
  Stream<RecordedAudioChunk> get partials => _partials.stream;
  @override
  Stream<String> get warnings => _warnings.stream;
  @override
  Stream<double> get levels => _levels.stream;
  @override
  bool get isRecording => _pipeline?.isRunning ?? false;

  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
  }) async {
    if (isRecording) throw StateError('Recorder is already active.');
    if (!microphone && !systemAudio) {
      throw StateError('Select microphone and/or device audio before recording.');
    }

    final sources = <CaptureSource>[];
    final notes = <String>[];

    if (microphone) {
      final source = createPlatformMicrophoneSource();
      if (source == null) {
        throw StateError('Microphone capture is unavailable on this platform.');
      }
      final allowed = await source.ensurePermission();
      if (!allowed) {
        throw StateError(
          'Microphone permission is required. Enable it in system settings and try again.',
        );
      }
      sources.add(source);
    }

    if (systemAudio) {
      final source = createPlatformSystemAudioSource();
      if (source == null) {
        notes.add(
          'System audio capture is unavailable on this platform. Recording can continue with the microphone only.',
        );
      } else {
        final allowed = await source.ensurePermission();
        if (!allowed) {
          notes.add(
            'System audio permission was not granted. Recording continues with the microphone only.',
          );
        } else {
          sources.add(source);
        }
      }
    }

    if (sources.isEmpty) {
      throw StateError(notes.isEmpty ? 'No audio source is available.' : notes.join(' '));
    }

    final pipeline = CapturePipeline(
      sources: sources,
      chunkMs: chunkMs,
      overlapMs: overlapMs,
    );
    _subs
      ..add(pipeline.chunks.stream.listen(_chunks.add))
      ..add(pipeline.partials.stream.listen(_partials.add))
      ..add(pipeline.warnings.stream.listen(_warnings.add))
      ..add(pipeline.levels.stream.listen(_levels.add));

    try {
      final capability = await pipeline.start();
      _pipeline = pipeline;
      final warning = [
        if (capability.warning != null) capability.warning!,
        ...notes,
      ].join(' ').trim();
      return RecorderCapability(
        microphone: capability.microphone,
        systemAudio: capability.systemAudio,
        persistentStorage: true,
        sampleRate: capability.sampleRate,
        warning: warning.isEmpty ? null : warning,
      );
    } catch (error) {
      await pipeline.dispose();
      for (final sub in _subs) {
        await sub.cancel();
      }
      _subs.clear();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) {
      await pipeline.stop();
      await pipeline.dispose();
    }
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _chunks.close();
    await _partials.close();
    await _warnings.close();
    await _levels.close();
  }
}
