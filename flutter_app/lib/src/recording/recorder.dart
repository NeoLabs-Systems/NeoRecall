import 'audio_frame.dart';
import 'recorder_stub.dart'
    if (dart.library.html) 'recorder_web.dart'
    if (dart.library.io) 'recorder_io.dart'
    as implementation;

abstract class RecallRecorder {
  Stream<RecordedAudioChunk> get chunks;
  Stream<RecordedAudioChunk> get partials;
  Stream<String> get warnings;
  Stream<double> get levels;
  bool get isRecording;
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
  });
  Future<void> stop();
  Future<void> dispose();
}

RecallRecorder createRecorder() => implementation.createRecorder();
