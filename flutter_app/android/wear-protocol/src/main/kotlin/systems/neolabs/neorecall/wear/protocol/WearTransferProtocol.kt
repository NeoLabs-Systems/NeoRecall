package systems.neolabs.neorecall.wear.protocol

/** One versioned contract shared by the phone and watch APKs. */
object WearTransferProtocol {
  const val VERSION = 1

  const val RECORDING_PATH_PREFIX = "/neorecall/watch/recordings/"
  const val ACK_PATH_PREFIX = "/neorecall/watch/acks/"

  const val KEY_VERSION = "version"
  const val KEY_AUDIO = "audio"
  const val KEY_RECORDING_ID = "recordingId"
  const val KEY_SESSION_ID = "sessionId"
  const val KEY_SOURCE_ID = "sourceId"
  const val KEY_WATCH_DEVICE_ID = "watchDeviceId"
  const val KEY_WATCH_NAME = "watchName"
  const val KEY_SEQUENCE = "sequence"
  const val KEY_SESSION_STARTED_AT_MS = "sessionStartedAtMs"
  const val KEY_STARTED_AT_MS = "startedAtMs"
  const val KEY_MONOTONIC_OFFSET_MS = "monotonicOffsetMs"
  const val KEY_DURATION_MS = "durationMs"
  const val KEY_SAMPLE_RATE = "sampleRate"
  const val KEY_IS_FINAL = "isFinal"
  const val KEY_SHA256 = "sha256"
  const val KEY_CONTAINER = "container"
  const val KEY_CODEC = "codec"
  const val KEY_CONTENT_TYPE = "contentType"

  const val KEY_RECEIPT_STATE = "receiptState"
  const val KEY_SERVER_CHUNK_ID = "serverChunkId"
  const val KEY_PERSISTED_AT = "persistedAt"
  const val KEY_SERVER_AUDIO_DELETED_AT = "serverAudioDeletedAt"
  const val KEY_TRANSCRIPT_SHA256 = "transcriptSha256"

  const val SAMPLE_RATE = 16_000
  const val CHANNELS = 1
  const val AAC_BIT_RATE = 24_000
  const val CHUNK_DURATION_MS = 30_000L
  // Deliberately conservative onboard VAD: discard only near-digital silence;
  // uncertain audio is retained for server transcription.
  const val VAD_MIN_RMS = 64.0
  const val VAD_MIN_VOICED_MS = 192L
  const val CONTAINER = "aac"
  const val CODEC = "aac_lc"
  const val CONTENT_TYPE = "audio/aac"
}
