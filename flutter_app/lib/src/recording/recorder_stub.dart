import 'audio_frame.dart';
import 'recorder.dart';
import '../devices/audio_device_adapter.dart';

RecallRecorder createRecorder() => _UnsupportedRecorder();

class _UnsupportedRecorder implements RecallRecorder {
  @override
  Stream<RecordedAudioChunk> get chunks =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<RecordedAudioChunk> get partials =>
      const Stream<RecordedAudioChunk>.empty();
  @override
  Stream<String> get warnings => const Stream<String>.empty();
  @override
  Stream<double> get levels => const Stream<double>.empty();
  @override
  bool get isRecording => false;
  @override
  Future<RecorderCapability> start({
    required bool microphone,
    required bool systemAudio,
    required int chunkMs,
    required int overlapMs,
    ExternalAudioCaptureDevice? externalDevice,
  }) => throw UnsupportedError('Recording is unsupported on this platform.');
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
