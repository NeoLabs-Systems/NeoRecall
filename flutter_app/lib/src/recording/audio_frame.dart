import 'dart:typed_data';

class AudioFrame {
  const AudioFrame({
    required this.source,
    required this.timestamp,
    required this.samples,
    required this.sampleRate,
  });
  final String source;
  final Duration timestamp;
  final Uint8List samples;
  final int sampleRate;
}

class RecordedAudioChunk {
  const RecordedAudioChunk({
    required this.bytes,
    required this.durationMs,
    required this.overlapMs,
    required this.channelLayout,
    required this.startedAt,
    required this.monotonicOffsetMs,
    this.isFinal = false,
  });
  final Uint8List bytes;
  final int durationMs;
  final int overlapMs;
  final String channelLayout;
  final DateTime startedAt;
  final int monotonicOffsetMs;
  final bool isFinal;
}

class RecorderCapability {
  const RecorderCapability({
    required this.microphone,
    required this.systemAudio,
    required this.persistentStorage,
    required this.sampleRate,
    required this.sourceKind,
    this.warning,
  });
  final bool microphone;
  final bool systemAudio;
  final bool persistentStorage;
  final int sampleRate;
  final String sourceKind;
  final String? warning;
}
