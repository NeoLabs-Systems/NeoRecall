enum PendingAudioPlaybackStage {
  needsAttention,
  onDevice,
  uploading,
  serverProcessing,
  finalizing,
}

class PendingAudioPart {
  const PendingAudioPart({
    required this.id,
    required this.duration,
    required this.mimeType,
  });

  final String id;
  final Duration duration;
  final String mimeType;
}

/// A user-facing recording session assembled from its immutable retained
/// chunks. Bytes remain lazy so opening the review sheet never
/// loads a potentially large backlog into memory.
class PendingAudioRecording {
  const PendingAudioRecording({
    required this.id,
    required this.startedAt,
    required this.duration,
    required this.byteSize,
    required this.stage,
    required this.parts,
  });

  final String id;
  final DateTime startedAt;
  final Duration duration;
  final int byteSize;
  final PendingAudioPlaybackStage stage;
  final List<PendingAudioPart> parts;
}
