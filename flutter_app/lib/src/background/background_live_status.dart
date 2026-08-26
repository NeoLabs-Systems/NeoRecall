/// User-visible state rendered by the native Android notification and the iOS
/// Live Activity. Dart owns the wording and facts; platform code only decides
/// how to present them, so the two platforms cannot drift into different state
/// machines.
enum BackgroundLivePhase {
  recording,
  watchTransfer,
  queued,
  uploading,
  transcribing,
  finalizing,
  connected,
  idle,
  storageFull,
}

extension BackgroundLivePhaseWire on BackgroundLivePhase {
  String get wireName => switch (this) {
    BackgroundLivePhase.recording => 'recording',
    BackgroundLivePhase.watchTransfer => 'watchTransfer',
    BackgroundLivePhase.queued => 'queued',
    BackgroundLivePhase.uploading => 'uploading',
    BackgroundLivePhase.transcribing => 'transcribing',
    BackgroundLivePhase.finalizing => 'finalizing',
    BackgroundLivePhase.connected => 'connected',
    BackgroundLivePhase.idle => 'idle',
    BackgroundLivePhase.storageFull => 'storageFull',
  };
}

class BackgroundLiveStatus {
  const BackgroundLiveStatus({
    required this.phase,
    required this.title,
    required this.detail,
    this.recordingStartedAt,
    this.progress,
    this.pendingBytes = 0,
    this.pendingAudioSeconds = 0,
    this.etaSeconds,
    this.issue,
  });

  final BackgroundLivePhase phase;
  final String title;
  final String detail;
  final DateTime? recordingStartedAt;
  final double? progress;
  final int pendingBytes;
  final int pendingAudioSeconds;
  final int? etaSeconds;
  final String? issue;

  bool get isRecording => phase == BackgroundLivePhase.recording;
  bool get isStorageFull => phase == BackgroundLivePhase.storageFull;

  Map<String, Object?> toMap() => <String, Object?>{
    'phase': phase.wireName,
    'shortLabel': switch (phase) {
      BackgroundLivePhase.recording => 'REC',
      BackgroundLivePhase.watchTransfer => 'WATCH',
      BackgroundLivePhase.queued => 'QUEUED',
      BackgroundLivePhase.uploading => 'UPLOAD',
      BackgroundLivePhase.transcribing => 'TEXT',
      BackgroundLivePhase.finalizing => 'SAVE',
      BackgroundLivePhase.connected => 'LINKED',
      BackgroundLivePhase.idle => 'READY',
      BackgroundLivePhase.storageFull => 'FULL',
    },
    'title': title,
    'detail': detail,
    'recordingStartedAtMs': recordingStartedAt?.millisecondsSinceEpoch,
    'progress': progress,
    'pendingBytes': pendingBytes,
    'pendingAudioSeconds': pendingAudioSeconds,
    'etaSeconds': etaSeconds,
    'issue': issue,
  };

  @override
  bool operator ==(Object other) =>
      other is BackgroundLiveStatus &&
      other.phase == phase &&
      other.title == title &&
      other.detail == detail &&
      other.recordingStartedAt == recordingStartedAt &&
      other.progress == progress &&
      other.pendingBytes == pendingBytes &&
      other.pendingAudioSeconds == pendingAudioSeconds &&
      other.etaSeconds == etaSeconds &&
      other.issue == issue;

  @override
  int get hashCode => Object.hash(
    phase,
    title,
    detail,
    recordingStartedAt,
    progress,
    pendingBytes,
    pendingAudioSeconds,
    etaSeconds,
    issue,
  );
}
