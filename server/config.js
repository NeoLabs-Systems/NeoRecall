'use strict';

const { integer, number, boolean, enumeration, jsonObject } = require('./config/env');
const { validateConfig } = require('./config/validate');


// Context kept aside from every request for the chat template and for the gap
// between a character-based estimate of the prompt and the real tokenizer.
// Exported so the input budget and the configuration check that guards it use
// the same number.
const LLM_PROMPT_RESERVE_TOKENS = 512;

// Every environment variable buildConfig reads, by prefix.
const CONFIG_ENV = /^(NEORECALL_|AI_|LLM_|TRANSCRIPTION_|MAX_UPLOAD_BYTES$|NODE_ENV$)/;

let cachedConfig = null;
let cachedFingerprint = null;

// Identifies the environment buildConfig would read, so a changed variable
// rebuilds and an unchanged one does not.
//
// Cheaper than rebuilding: getConfig has ~70 call sites, several of them
// per-chunk (vad, diarization, audio decoding), and each uncached call
// re-validates roughly 120 variables before freezing a fresh object. Keeping
// the fingerprint rather than caching outright means tests that assign to
// process.env still see their own values with no reset call.
function environmentFingerprint() {
  const parts = [];
  for (const key of Object.keys(process.env)) {
    if (CONFIG_ENV.test(key)) parts.push(key, process.env[key]);
  }
  return parts.join('\u0000');
}

function getConfig() {
  const fingerprint = environmentFingerprint();
  if (cachedConfig && fingerprint === cachedFingerprint) return cachedConfig;
  cachedConfig = buildConfig();
  cachedFingerprint = fingerprint;
  return cachedConfig;
}

function buildConfig() {
  const chunkMinMs = integer('NEORECALL_CHUNK_MIN_MS', 15_000, { min: 1_000 });
  const chunkMaxMs = integer('NEORECALL_CHUNK_MAX_MS', 120_000, { min: chunkMinMs });
  const speakerPreviewMinimumMs = integer('NEORECALL_SPEAKER_PREVIEW_MIN_MS', 1_000, { min: 1_000, max: 10_000 });
  const speakerPreviewMaximumMs = integer('NEORECALL_SPEAKER_PREVIEW_MAX_MS', 10_000, { min: speakerPreviewMinimumMs, max: 10_000 });
  const speakerDisplayMinimumPreviewMs = integer('NEORECALL_SPEAKER_DISPLAY_MIN_PREVIEW_MS', 10_000, { min: 1_000, max: 10_000 });
  const relevanceWeight = number('NEORECALL_SEARCH_RELEVANCE_WEIGHT', 0.5, { min: 0 });
  const recencyWeight = number('NEORECALL_SEARCH_RECENCY_WEIGHT', 0.25, { min: 0 });
  const importanceWeight = number('NEORECALL_SEARCH_IMPORTANCE_WEIGHT', 0.25, { min: 0 });
  const searchWeightTotal = relevanceWeight + recencyWeight + importanceWeight;
  if (searchWeightTotal <= 0) throw new Error('At least one search weight must be greater than zero.');

  const config = {
    host: process.env.NEORECALL_HOST || '127.0.0.1',
    port: integer('NEORECALL_PORT', 4500, { min: 1, max: 65535 }),
    publicUrl: process.env.NEORECALL_PUBLIC_URL || null,
    trustProxy: boolean('NEORECALL_TRUST_PROXY', false),
    logLevel: process.env.NEORECALL_LOG_LEVEL || 'info',
    sessionTtlMs: integer('NEORECALL_SESSION_TTL_MS', 30 * 24 * 60 * 60 * 1000, { min: 60_000 }),
    registrationEnabled: boolean('NEORECALL_REGISTRATION_ENABLED', true),
    maxUploadBytes: integer('MAX_UPLOAD_BYTES', 32 * 1024 * 1024, { min: 1024 }),
    contextMaxFileBytes: integer('NEORECALL_CONTEXT_MAX_FILE_BYTES', 32 * 1024 * 1024, { min: 1024 }),
    contextNoteMaxCharacters: integer('NEORECALL_CONTEXT_NOTE_MAX_CHARACTERS', 20_000, { min: 1 }),
    contextExtractionMaxCharacters: integer('NEORECALL_CONTEXT_EXTRACTION_MAX_CHARACTERS', 500_000, { min: 1_000 }),
    contextMaxItems: integer('NEORECALL_CONTEXT_MAX_ITEMS', 200, { min: 1, max: 10_000 }),
    contextImageAnalysisMaxBytes: integer('NEORECALL_CONTEXT_IMAGE_ANALYSIS_MAX_BYTES', 5 * 1024 * 1024, { min: 1024 }),
    chunkTargetMs: integer('NEORECALL_CHUNK_TARGET_MS', 30_000, { min: chunkMinMs, max: chunkMaxMs }),
    chunkMinMs,
    chunkMaxMs,
    chunkOverlapMs: integer('NEORECALL_CHUNK_OVERLAP_MS', 2_000, { min: 0, max: chunkMaxMs - 1 }),
    importPartBytes: integer('NEORECALL_IMPORT_PART_BYTES', 8 * 1024 * 1024, { min: 64 * 1024 }),
    // How large a gap may be between two imports from the same device before
    // they stop counting as one recording stream. A wearable that records to
    // on-board storage is drained repeatedly — every fifteen seconds while it is
    // connected — and each sweep arrives as its own file. Treating each file as
    // its own recording would give a one-hour meeting one conversation per
    // sweep, and nothing downstream may merge across recordings. The window has
    // to clear the sync poll and its failure backoff comfortably; a genuinely
    // separate recording is still separated by boundary detection inside the
    // stream, so erring long is the safe direction.
    importSessionContinuityMs: integer('NEORECALL_IMPORT_SESSION_CONTINUITY_MS', 600_000, { min: 0 }),
    importFailedTtlHours: integer('NEORECALL_IMPORT_FAILED_TTL_HOURS', 24, { min: 1 }),
    transcriptionProvider: process.env.TRANSCRIPTION_PROVIDER || 'openai-compatible',
    transcriptionApiBaseUrl: (process.env.TRANSCRIPTION_API_BASE_URL || '').replace(/\/+$/, '') || null,
    transcriptionApiKey: process.env.TRANSCRIPTION_API_KEY || null,
    transcriptionApiModel: process.env.TRANSCRIPTION_API_MODEL || null,
    transcriptionApiLanguage: process.env.TRANSCRIPTION_API_LANGUAGE || null,
    transcriptionApiResponseFormat: process.env.TRANSCRIPTION_API_RESPONSE_FORMAT || null,
    transcriptionTimeoutMs: integer('TRANSCRIPTION_REQUEST_TIMEOUT_MS', 1_800_000, { min: 1_000 }),
    transcriptionPollIntervalMs: integer('TRANSCRIPTION_POLL_INTERVAL_MS', 1_000, { min: 250, max: 60_000 }),
    // Audio conditioning before inference. A short ffmpeg filter chain that
    // levels and cleans a chunk so the transcription service hears the same
    // recording under better conditions. Pure signal processing: no language is
    // assumed anywhere in it, so it helps every language the same way.
    //
    // Every stage is sample-count exact. That is not a preference but the
    // condition the rest of the pipeline rests on: diarization turns, segment
    // timestamps and the speaker previews cut from the original chunk all
    // describe one timeline, and a filter that added or removed samples would
    // shift them apart silently. Nothing that trims, gates or stretches belongs
    // in this chain.
    audioPreprocessEnabled: boolean('NEORECALL_AUDIO_PREPROCESS_ENABLED', true),
    // Which passes read the conditioned audio. The transcription service only,
    // by default, and that default is measured rather than cautious: the
    // segmentation and speaker-embedding models were trained on unprocessed
    // recordings, and on the two-speaker fixture in test/fixtures every
    // conditioned variant separated the voices worse than the raw audio did —
    // the high-pass alone merged both people into one speaker, because a voice's
    // identity partly lives in the low frequencies it removes. 'stt+analysis'
    // feeds them the conditioned audio too; see docs/docs/configuration.md
    // before setting it.
    audioPreprocessTarget: enumeration('NEORECALL_AUDIO_PREPROCESS_TARGET', 'stt', ['stt', 'stt+analysis']),
    // Rumble, handling noise and mains hum live below speech. No language
    // carries meaning down there, so removing it is free accuracy; it also
    // removes any DC offset the capture device introduced. 0 disables the stage.
    audioPreprocessHighpassHz: integer('NEORECALL_AUDIO_PREPROCESS_HIGHPASS_HZ', 70, { min: 0, max: 300 }),
    // Spectral denoising, deliberately gentle. Aggressive noise reduction
    // smooths the onset of plosives and fricatives, which is exactly the detail
    // an acoustic model reads; 6 dB against a low noise floor cleans a hissy
    // room without eroding consonants. Raise it only for consistently noisy
    // recordings, and measure the transcripts afterwards.
    audioPreprocessDenoiseEnabled: boolean('NEORECALL_AUDIO_PREPROCESS_DENOISE_ENABLED', true),
    audioPreprocessDenoiseDb: number('NEORECALL_AUDIO_PREPROCESS_DENOISE_DB', 6, { min: 0.01, max: 97 }),
    audioPreprocessDenoiseFloorDb: number('NEORECALL_AUDIO_PREPROCESS_DENOISE_FLOOR_DB', -40, { min: -80, max: -20 }),
    // Level normalization. A pocket wearable and a desk microphone arrive tens
    // of decibels apart, and quiet audio is where transcription degrades first.
    // 'dynaudnorm' is the default because it costs almost nothing; 'loudnorm'
    // is the broadcast-correct answer at roughly ten times the CPU, since it
    // upsamples internally for true-peak measurement.
    audioPreprocessNormalizer: enumeration('NEORECALL_AUDIO_PREPROCESS_NORMALIZER', 'dynaudnorm', ['dynaudnorm', 'loudnorm', 'speechnorm', 'off']),
    // Ceiling on how much a quiet passage may be lifted, so a near-silent room's
    // noise floor is never amplified into something that looks like speech.
    audioPreprocessMaxGain: number('NEORECALL_AUDIO_PREPROCESS_MAX_GAIN', 8, { min: 1, max: 100 }),
    // Only read when the normalizer is 'loudnorm'.
    audioPreprocessTargetLufs: number('NEORECALL_AUDIO_PREPROCESS_TARGET_LUFS', -18, { min: -40, max: -5 }),
    audioPreprocessTruePeakDb: number('NEORECALL_AUDIO_PREPROCESS_TRUE_PEAK_DB', -2, { min: -9, max: 0 }),
    // Clipping is the one way normalization can make transcription worse, so
    // the chain ends behind a limiter.
    audioPreprocessLimiterEnabled: boolean('NEORECALL_AUDIO_PREPROCESS_LIMITER_ENABLED', true),
    audioPreprocessLimiterPeak: number('NEORECALL_AUDIO_PREPROCESS_LIMITER_PEAK', 0.95, { min: 0.0625, max: 1 }),
    // Every transcription service resamples to 16 kHz internally, so arriving
    // there already is not a loss, and it makes the upload predictable.
    audioPreprocessSampleRate: integer('NEORECALL_AUDIO_PREPROCESS_SAMPLE_RATE', 16_000, { min: 8_000, max: 48_000 }),
    // 'flac' is lossless at roughly half the bytes, for a metered uplink.
    audioPreprocessFormat: enumeration('NEORECALL_AUDIO_PREPROCESS_FORMAT', 'wav', ['wav', 'flac']),
    audioPreprocessTimeoutMs: integer('NEORECALL_AUDIO_PREPROCESS_TIMEOUT_MS', 120_000, { min: 1_000, max: 600_000 }),
    // Conditioning is proportional to length, and an unexpectedly long import
    // should reach the transcription service rather than sit in ffmpeg. 0 lifts
    // the cap.
    audioPreprocessMaxDurationMs: integer('NEORECALL_AUDIO_PREPROCESS_MAX_DURATION_MS', 1_800_000, { min: 0, max: 86_400_000 }),
    customVocabularyMaxTerms: integer('NEORECALL_CUSTOM_VOCABULARY_MAX_TERMS', 100, { min: 1, max: 1_000 }),
    customVocabularyMaxTermLength: integer('NEORECALL_CUSTOM_VOCABULARY_MAX_TERM_LENGTH', 120, { min: 1, max: 500 }),
    vocabularyCorrectionMinimumLength: integer('NEORECALL_VOCABULARY_CORRECTION_MIN_LENGTH', 8, { min: 4, max: 100 }),
    vocabularyCorrectionMaximumDistance: integer('NEORECALL_VOCABULARY_CORRECTION_MAX_DISTANCE', 2, { min: 1, max: 5 }),
    vocabularyCorrectionSimilarity: number('NEORECALL_VOCABULARY_CORRECTION_SIMILARITY', 0.84, { min: 0.5, max: 1 }),
    vocabularyCorrectionAmbiguityMargin: number('NEORECALL_VOCABULARY_CORRECTION_AMBIGUITY_MARGIN', 0.08, { min: 0, max: 1 }),
    // Backups. Local by default; the destination layer accepts remote targets
    // without a change here beyond a new NEORECALL_BACKUP_DESTINATION value.
    backupEnabled: boolean('NEORECALL_BACKUP_ENABLED', true),
    backupDestination: process.env.NEORECALL_BACKUP_DESTINATION || 'local',
    backupIntervalHours: integer('NEORECALL_BACKUP_INTERVAL_HOURS', 24, { min: 1, max: 24 * 30 }),
    backupRetain: integer('NEORECALL_BACKUP_RETAIN', 3, { min: 1, max: 365 }),
    // Per-user Nextcloud copies. Interval and age are host-wide; whether a
    // given account actually uploads is the user's own toggle.
    cloudUserBackupIntervalHours: integer('NEORECALL_CLOUD_USER_BACKUP_INTERVAL_HOURS', 24, { min: 1, max: 24 * 30 }),
    cloudPendingMaxAgeMs: integer('NEORECALL_CLOUD_PENDING_MAX_AGE_MS', 7 * 24 * 60 * 60_000, { min: 60_000 }),
    cloudLoginTimeoutMs: integer('NEORECALL_CLOUD_LOGIN_TIMEOUT_MS', 20 * 60_000, { min: 30_000, max: 60 * 60_000 }),
    cloudHttpTimeoutMs: integer('NEORECALL_CLOUD_HTTP_TIMEOUT_MS', 120_000, { min: 5_000, max: 1_800_000 }),
    cloudPutMaxAttempts: integer('NEORECALL_CLOUD_PUT_MAX_ATTEMPTS', 8, { min: 1, max: 50 }),
    // VAD and diarization run locally; see docs/docs/configuration.md.
    diarizationEnabled: boolean('NEORECALL_DIARIZATION_ENABLED', true),
    // Native threads for the audio models.
    sherpaThreads: integer('NEORECALL_SHERPA_THREADS', 2, { min: 1, max: 128 }),
    // Below this confidence a chunk is treated as silence and never sent anywhere.
    vadThreshold: number('NEORECALL_VAD_THRESHOLD', 0.5, { min: 0, max: 1 }),
    vadMinimumSpeechSeconds: number('NEORECALL_VAD_MIN_SPEECH_SECONDS', 0.25, { min: 0 }),
    vadMinimumSilenceSeconds: number('NEORECALL_VAD_MIN_SILENCE_SECONDS', 0.5, { min: 0 }),
    diarizationMinimumOnSeconds: number('NEORECALL_DIARIZATION_MIN_ON_SECONDS', 0.3, { min: 0 }),
    diarizationMinimumOffSeconds: number('NEORECALL_DIARIZATION_MIN_OFF_SECONDS', 0.2, { min: 0 }),
    // Recognising a voice across different recordings. Stricter than matching
    // inside one, since merging two people is harder to undo than leaving them apart.
    voiceMatchThreshold: number('NEORECALL_VOICE_MATCH_THRESHOLD', 0.62, { min: -1, max: 1 }),
    voiceMatchMargin: number('NEORECALL_VOICE_MATCH_MARGIN', 0.05, { min: 0, max: 2 }),
    // Enrolling a person is the only speaker decision more evidence cannot undo,
    // so it takes more than failing to match. A voice must score below this to
    // count as somebody new; between here and voiceMatchThreshold is the grey
    // band where it resembles someone already enrolled without confirming it,
    // and the turn is left unattributed rather than becoming their duplicate.
    voiceEnrollFloor: number('NEORECALL_VOICE_ENROLL_FLOOR', 0.45, { min: -1, max: 1 }),
    // Pooled speech a fingerprint must be measured from before it may found a
    // new person. Below this, a low score says the measurement was poor, not
    // that the voice is unknown.
    voiceEnrollMinimumMs: integer('NEORECALL_VOICE_ENROLL_MIN_MS', 3_000, { min: 0, max: 120_000 }),
    // The bar for folding two enrolled profiles back together when each is the
    // other's closest match and neither has a competing candidate nearby. Mutual
    // exclusivity is far stronger evidence than a one-sided score, so this sits
    // below voiceMatchThreshold — it is what lets the Speakers screen's re-detect
    // repair duplicates that ordinary matching can never reach.
    voiceRepairThreshold: number('NEORECALL_VOICE_REPAIR_THRESHOLD', 0.50, { min: -1, max: 1 }),
    // How far back the Speakers screen's re-detect re-resolves conversations.
    // Bounded because the user is waiting on the response: a year of recordings
    // would be a request that never returns, and the recent past is where a
    // wrongly split speaker is still worth correcting on screen.
    speakerRedetectDays: integer('NEORECALL_SPEAKER_REDETECT_DAYS', 30, { min: 1, max: 3650 }),
    // Distance for grouping voices inside one chunk; a larger value merges more.
    // A separate setting from speakerClusterThreshold below: this is a distance
    // (higher = fewer speakers), that is a similarity (higher = more speakers).
    diarizationClusterDistance: number('NEORECALL_DIARIZATION_CLUSTER_DISTANCE', 0.65, { min: 0, max: 2 }),
    // Cosine similarity a turn must clear against a cluster's centroid to count
    // as the same voice across chunks.
    speakerClusterThreshold: number('NEORECALL_SPEAKER_CLUSTER_THRESHOLD', 0.52, { min: -1, max: 1 }),
    // Two clusters this alike in one recording are merged back into one.
    speakerClusterMergeThreshold: number('NEORECALL_SPEAKER_CLUSTER_MERGE_THRESHOLD', 0.55, { min: -1, max: 1 }),
    // Speech shorter than this may join an existing voice but never founds a new
    // one. Half a second filters brief diarization blips while favoring a
    // possibly imperfect speaker label over leaving real short speech unlabeled.
    speakerMinimumTurnMs: integer('NEORECALL_SPEAKER_MINIMUM_TURN_MS', 500, { min: 0, max: 60_000 }),
    // A cluster match this close to the runner-up is ambiguous, not confident.
    // Without a margin, a single fixed threshold occasionally lets a distinct new
    // speaker's embedding score just above it against some unrelated existing
    // cluster, silently attributing their speech to someone else. Mirrors the
    // margin voice matching already applies across recordings.
    speakerClusterMargin: number('NEORECALL_SPEAKER_CLUSTER_MARGIN', 0.05, { min: 0, max: 2 }),
    // Diarization runs per audio chunk, so a continuous speaker crossing a chunk
    // boundary is re-segmented from scratch and can drift below the plain
    // clustering threshold even though nothing about the voice changed. When the
    // new chunk's first speech for a given audio component starts within this
    // gap of where that component's last known speaker turn ended, the resolver
    // is allowed to keep that same cluster at a relaxed similarity bar instead of
    // minting a new one. This never overrides a clearly different match — it
    // only breaks a near-tie in favor of continuity — so a genuine speaker
    // change right at the boundary still gets its own identity. Independent of
    // chunk length: it compares actual timestamps, not chunk counts.
    speakerContinuityGapMs: integer('NEORECALL_SPEAKER_CONTINUITY_GAP_MS', 4_000, { min: 0 }),
    // Relaxed bar for a speaker still talking across a chunk boundary; must stay
    // below speakerClusterThreshold.
    speakerClusterContinuityThreshold: number('NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD', 0.42, { min: -1, max: 1 }),
    speakerPreviewMinimumMs,
    speakerPreviewMaximumMs,
    speakerDisplayMinimumPreviewMs,
    speakerPreviewMaxBytes: integer('NEORECALL_SPEAKER_PREVIEW_MAX_BYTES', 1024 * 1024, { min: 320_044 }),
    dedupeTokenSimilarity: number('NEORECALL_DEDUPE_TOKEN_SIMILARITY', 0.82, { min: 0, max: 1 }),
    dedupeTimeToleranceMs: integer('NEORECALL_DEDUPE_TIME_TOLERANCE_MS', 2500, { min: 0 }),
    // Live capture and a later drain of the same wearable share one device id,
    // so cross-device exact-utterance dedupe never sees them. If this fraction
    // of an incoming chunk's timeline is already present on another source of
    // that device, transcription is skipped.
    sameDeviceCoverageRatio: number('NEORECALL_SAME_DEVICE_COVERAGE_RATIO', 0.5, { min: 0, max: 1 }),
    // ASR services occasionally fill a short timestamp with the same token
    // template dozens of times. Detect that structurally and only when the
    // resulting speaking rate is implausible; no vocabulary or phrase list is
    // involved. The original first occurrence remains as evidence.
    transcriptRepetitionMinimumRepeats: integer('NEORECALL_TRANSCRIPT_REPETITION_MIN_REPEATS', 8, { min: 3, max: 1_000 }),
    transcriptRepetitionMaximumPatternWords: integer('NEORECALL_TRANSCRIPT_REPETITION_MAX_PATTERN_WORDS', 8, { min: 1, max: 32 }),
    transcriptRepetitionMinimumCoverage: number('NEORECALL_TRANSCRIPT_REPETITION_MIN_COVERAGE', 0.8, { min: 0.5, max: 1 }),
    transcriptMaximumWordsPerSecond: number('NEORECALL_TRANSCRIPT_MAX_WORDS_PER_SECOND', 5, { min: 1, max: 50 }),
    conversationHardGapMs: integer('NEORECALL_CONVERSATION_HARD_GAP_MS', 180_000, { min: 1_000 }),
    conversationSoftGapMs: integer('NEORECALL_CONVERSATION_SOFT_GAP_MS', 60_000, { min: 1_000 }),
    conversationMinimumMs: integer('NEORECALL_CONVERSATION_MINIMUM_MS', 30_000, { min: 1_000 }),
    conversationQuietCloseMs: integer('NEORECALL_CONVERSATION_QUIET_CLOSE_MS', 300_000, { min: 1_000 }),
    conversationValleyQuantile: number('NEORECALL_CONVERSATION_VALLEY_QUANTILE', 0.25, { min: 0, max: 1 }),
    conversationSemanticSimilarityThreshold: number('NEORECALL_CONVERSATION_SEMANTIC_SIMILARITY_THRESHOLD', 0.58, { min: -1, max: 1 }),
    conversationSemanticValleyProminence: number('NEORECALL_CONVERSATION_SEMANTIC_VALLEY_PROMINENCE', 0.1, { min: 0, max: 2 }),
    conversationSemanticContextSegments: integer('NEORECALL_CONVERSATION_SEMANTIC_CONTEXT_SEGMENTS', 3, { min: 1, max: 20 }),
    conversationMaximumMs: integer('NEORECALL_CONVERSATION_MAXIMUM_MS', 4 * 60 * 60_000, { min: 60_000 }),
    // Sized so duration, not transcript length, is what ends a conversation: one
    // real-world occasion must stay one conversation to become one memory, and
    // four hours of continuous speech is roughly 170 000 characters. A ceiling
    // below that would split a lecture into several memories purely because it
    // was long.
    conversationMaximumCharacters: integer('NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS', 200_000, { min: 1_000 }),
    // Live preview of a conversation that is still being recorded. The first
    // preview needs this much transcript, every refresh needs this much growth
    // on top of the previewed text, and two previews of one conversation stay at
    // least this far apart. Together they keep the machine's own work
    // proportional to new speech rather than to elapsed time. They are set close
    // to the scheduler tick so a description that is a minute old is refreshed
    // without flooding the configured provider.
    conversationPreviewMinCharacters: integer('NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS', 300, { min: 1 }),
    conversationPreviewRefreshCharacters: integer('NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS', 600, { min: 1 }),
    conversationPreviewMinIntervalMs: integer('NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS', 60_000, { min: 0 }),
    // Up to this size a refresh re-reads the whole transcript, which is exact.
    // Beyond it a refresh sends the previous summary plus only the new speech,
    // so an all-day conversation costs a constant amount per refresh instead of
    // re-paying for its entire history every few minutes. The final
    // consolidation always reads the full transcript, so any drift the rolling
    // summaries accumulate is corrected when the conversation closes.
    conversationPreviewFullCharacters: integer('NEORECALL_CONVERSATION_PREVIEW_FULL_CHARACTERS', 20_000, { min: 1 }),
    embeddingModel: process.env.NEORECALL_EMBEDDING_MODEL || 'Xenova/multilingual-e5-small',
    embeddingDimensions: integer('NEORECALL_EMBEDDING_DIMENSIONS', 384, { min: 1 }),
    requireVector: boolean('NEORECALL_REQUIRE_VECTOR', process.env.NODE_ENV === 'production'),
    rrfK: integer('NEORECALL_RRF_K', 60, { min: 1 }),
    // A nearest neighbour is not the same thing as a match. The vector index
    // returns the k closest embeddings whatever their distance, so on a small
    // archive every query "matches" every document — which is how unrelated
    // transcript segments ended up ranked as evidence. Embeddings are unit
    // length, so this floor is plain cosine similarity: below it a neighbour is
    // dropped before fusion rather than fused with a rank it did not earn.
    semanticSimilarityFloor: number('NEORECALL_SEMANTIC_SIMILARITY_FLOOR', 0.62, { min: 0, max: 1 }),
    // How many restatements of one question Ask may retrieve for. A question
    // and its paraphrase reach different documents; beyond a handful the extra
    // queries return what the earlier ones already found.
    askMaxSearchQueries: integer('NEORECALL_ASK_MAX_SEARCH_QUERIES', 3, { min: 1, max: 8 }),
    // A question about a period ("what did I do today") is answered from the
    // period, not from whatever happens to resemble the words in it. This caps
    // how many documents such a question may read out of its time window.
    askTimeWindowLimit: integer('NEORECALL_ASK_TIME_WINDOW_LIMIT', 40, { min: 1, max: 200 }),
    // Ask reads the written record first. Memories, their details and daily
    // summaries are what consolidation already sorted, dated and titled;
    // transcript segments are the raw speech behind them, worth a few slots for
    // exact wording but not worth crowding out the layer written from them.
    // Standing instructions an account owner may give the model, per area. Long
    // enough for a paragraph of preferences on each; short enough that four of
    // them plus the global one cannot crowd the evidence out of a request.
    customInstructionsMaxCharacters: integer('NEORECALL_CUSTOM_INSTRUCTIONS_MAX_CHARACTERS', 2_000, { min: 0, max: 20_000 }),
    askMemoryContextLimit: integer('NEORECALL_ASK_MEMORY_CONTEXT_LIMIT', 12, { min: 1, max: 100 }),
    askTranscriptContextLimit: integer('NEORECALL_ASK_TRANSCRIPT_CONTEXT_LIMIT', 4, { min: 0, max: 100 }),
    searchWeights: {
      relevance: relevanceWeight / searchWeightTotal,
      recency: recencyWeight / searchWeightTotal,
      importance: importanceWeight / searchWeightTotal,
    },
    searchHalfLifeDays: number('NEORECALL_SEARCH_HALF_LIFE_DAYS', 30, { min: 0.01 }),
    aiProvider: process.env.AI_PROVIDER || 'openai_compatible',
    // How much of the conversation the configured external model may hold at
    // once, in tokens. Consolidation windows its input to fit, so raising this
    // buys fewer, wider requests and lowering it buys narrower ones.
    llmContextSize: integer('LLM_CONTEXT_SIZE', 16_384, { min: 2_048, max: 262_144 }),
    // Structured extraction, not prose: near-greedy decoding keeps the model on
    // the evidence instead of inventing plausible-sounding detail.
    llmTemperature: number('LLM_TEMPERATURE', 0.2, { min: 0, max: 2 }),
    // Generic endpoint settings. Provider-specific API keys are also supported
    // and the admin page can override these values at runtime.
    aiApiBaseUrl: (process.env.AI_API_BASE_URL || '').replace(/\/+$/, '') || null,
    aiApiKey: process.env.AI_API_KEY || null,
    // Extra JSON merged into every chat-completions request body, for
    // provider-specific fields no shared contract covers.
    aiApiExtraBody: jsonObject('AI_API_EXTRA_BODY'),
    aiApiModel: process.env.AI_API_MODEL || null,
    // External deployments can still take minutes for a bounded consolidation
    // answer. Sized so the slowest legitimate answer finishes rather than being
    // aborted and retried at the same cost.
    aiTimeoutMs: integer('AI_REQUEST_TIMEOUT_MS', 1_800_000, { min: 1_000 }),
    aiMaxRetries: integer('AI_MAX_RETRIES', 2, { min: 0, max: 10 }),
    // Has to cover the sections, memories and mini-memories one window of input
    // can justify; a completion cut off mid-JSON reads as a validation failure.
    // It shares the context budget with the prompt, so it cannot be raised
    // without raising LLM_CONTEXT_SIZE too.
    //
    // Now that the contract caps how many items one pass may return, the worst
    // case is arithmetic rather than a guess: three memories with eight
    // mini-memories each, sixteen entities and the sections around them come to
    // roughly five and a half thousand tokens of pretty-printed JSON. Eight
    // thousand covers that with margin. Measured runs of a dense eight-thousand
    // character window landed between 2 400 and 3 900.
    aiConsolidationMaxOutputTokens: integer('AI_CONSOLIDATION_MAX_OUTPUT_TOKENS', 8_000, { min: 512, max: 200_000 }),
    // How much transcript one consolidation request may read, in characters.
    //
    // Sized against the *answer*, not against the context. What a window can
    // hold and what its answer costs are different quantities, and the answer is
    // the one that fails: a full contract for dense speech runs to roughly one
    // output token per five input characters, so a window sized to fill a 16 384
    // token context — nearly thirty thousand characters — asks for an answer
    // several times larger than AI_CONSOLIDATION_MAX_OUTPUT_TOKENS allows, and
    // arrives truncated. Measured: 29 600 characters of continuous lecture
    // overran a 6 000 token budget outright.
    //
    // Eight thousand characters is five to eight minutes of speech and leaves
    // the answer roughly a fourfold margin. Raising it lets the model see more
    // of an occasion at once; lowering it is the first thing to try if
    // AI_OUTPUT_TRUNCATED appears. It is also clamped to whatever the context
    // can actually hold.
    consolidationWindowCharacters: integer('NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS', 8_000, { min: 1_000 }),
    aiPreviewMaxOutputTokens: integer('AI_PREVIEW_MAX_OUTPUT_TOKENS', 4_000, { min: 256, max: 200_000 }),
    minConsolidationIntervalMs: integer('NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS', 0, { min: 0 }),
    // How long finished material may wait for the character threshold before it
    // is consolidated anyway. Zero means it never waits: with the model running
    // on this machine there is nothing to save by batching short conversations
    // together, and a conversation that just ended is exactly the one a user is
    // about to look for.
    maxConsolidationLatencyMs: integer('NEORECALL_MAX_CONSOLIDATION_LATENCY_MS', 0, { min: 0 }),
    // Consecutive AI validation failures a conversation may cause before it is
    // quarantined. Candidates are always built oldest-first, so one conversation
    // the model cannot partition would otherwise poison every later run and stop
    // memory generation permanently.
    consolidationMaxFailures: integer('NEORECALL_CONSOLIDATION_MAX_FAILURES', 3, { min: 1, max: 100 }),
    // The least audio and text that may cause a model request at all.
    //
    // Both existed to keep a per-request bill off trivial material. The model
    // now runs on this machine, so a thirty-second exchange is worth describing
    // as soon as it ends; the floors that decide what becomes a *memory* are
    // separate and unchanged, and still keep short speech off the timeline as a
    // memory card. Raise these if the machine cannot keep up with its own
    // recordings.
    minAiAudioMs: integer('NEORECALL_MIN_AI_AUDIO_MS', 0, { min: 0 }),
    minNewMaterialChars: integer('NEORECALL_MIN_NEW_MATERIAL_CHARS', 1, { min: 1 }),
    // How substantial a conversation section must be before it may become an
    // episodic memory card. Below either floor the section still gets a title
    // and summary on the timeline; durable one-liners belong in mini-memories
    // when they appear inside a larger worthy occasion, not as their own memory.
    // The model is instructed the same way; these floors enforce it when the
    // model over-promotes brief exchanges.
    minMemoryEvidenceMs: integer('NEORECALL_MIN_MEMORY_EVIDENCE_MS', 120_000, { min: 0 }),
    minMemoryEvidenceChars: integer('NEORECALL_MIN_MEMORY_EVIDENCE_CHARS', 400, { min: 0 }),
    maxConsolidationInputChars: integer('NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS', 250_000, { min: 1000 }),
    // How many conversations one run may carry.
    //
    // Batching several into a single request used to amortize a per-request
    // price; it also asked the model to hold several unrelated occasions in mind
    // at once, which is the harder job and the one it does worse. That objection
    // still stands and is why a run never carries an arbitrary batch: what it
    // carries is one *occasion* — a chain of consecutive conversations from the
    // same recording, none separated from the next by more than
    // NEORECALL_MEMORY_OCCASION_GAP_MS. Those are fragments of one sitting rather
    // than unrelated material, and showing them together is what lets the model
    // write one memory instead of one per fragment.
    //
    // This is the ceiling on that chain, not a batch size. A pause every few
    // minutes through a long meeting is ordinary, so it has to be comfortably
    // above the handful of fragments an hour of speech produces; the character
    // and duration limits below are what actually bound the request.
    maxConsolidationConversations: integer('NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS', 12, { min: 1, max: 200 }),
    // Up to this gap, two consecutive conversations from one recording are read
    // as the same real-world occasion and consolidated together.
    //
    // Conversation boundaries are provisional: NEORECALL_CONVERSATION_HARD_GAP_MS
    // cuts the stream after three minutes of quiet, which is a normal pause in a
    // meeting, a lesson or a meal. Left alone, each piece became its own memory
    // card minutes apart. This is the wider, occasion-sized gap that decides
    // whether those pieces are shown to the model as one thing.
    memoryOccasionGapMs: integer('NEORECALL_MEMORY_OCCASION_GAP_MS', 15 * 60_000, { min: 0 }),
    // How long an occasion must have been quiet before it is written up, while
    // its recording is still running.
    //
    // A conversation that just ended is exactly the one someone is about to look
    // for, so nothing waits once the recording has stopped — a stopped recording
    // is proof the occasion is over. While it is still running there is no such
    // proof, and writing up the first fragment immediately is what produced three
    // cards for one meeting. Sized above the hard gap so an ordinary pause cannot
    // beat it.
    memorySettleMs: integer('NEORECALL_MEMORY_SETTLE_MS', 8 * 60_000, { min: 0 }),
    // The longest a fragment may be held back waiting for its occasion to end.
    //
    // An always-on recording never stops, and a chain that keeps growing would
    // otherwise postpone every memory for as long as someone keeps talking. At
    // this age the chain is written up with whatever it has; the continuation
    // mechanism folds later fragments into that card.
    memoryOccasionMaxWaitMs: integer('NEORECALL_MEMORY_OCCASION_MAX_WAIT_MS', 60 * 60_000, { min: 60_000 }),
    // Recent cards shown to the consolidation model as possible fragments of
    // the same real-world occasion. This bounds context only: timestamps,
    // recording continuity and transcript meaning still decide whether the
    // model claims any candidate, and no numeric similarity score merges data.
    maxMemoryContinuationCandidates: integer('NEORECALL_MAX_MEMORY_CONTINUATION_CANDIDATES', 8, { min: 0, max: 32 }),
    // Cross-recording fragments can belong to one occasion even when the
    // capture client briefly stopped or reconnected. Candidate retrieval uses
    // this wider, bounded horizon so the model can see those fragments; it
    // still has to identify the same continuing sitting from transcript,
    // timing and recurring-speaker evidence before anything is merged.
    memoryContinuationLookbackMs: integer('NEORECALL_MEMORY_CONTINUATION_LOOKBACK_MS', 2 * 60 * 60_000, { min: 0 }),
    // Manual consolidation is structural work first and an optional prose
    // rewrite second. Keep the request bounded for database/query safety while
    // allowing a person to clean up a substantial backlog in one operation.
    memoryMergeMaxItems: integer('NEORECALL_MEMORY_MERGE_MAX_ITEMS', 100, { min: 2, max: 500 }),
    // The safety net under memory generation: a sweep that finds cards which
    // describe the same occasion and folds them together.
    //
    // Consolidating a whole occasion at once is the real fix and handles the
    // ordinary case. It cannot handle every case: a device that reconnects
    // starts a new recording stream, an occasion longer than
    // NEORECALL_MEMORY_OCCASION_MAX_WAIT_MS is written up before it ends, and a
    // fragment that finished transcribing late arrives after its neighbours were
    // already written. Each leaves two cards for one sitting.
    //
    // Retrieval is the memory search index that already exists, so nothing is
    // embedded twice. The numeric score only decides which pairs are worth
    // asking about; the model makes the actual same-occasion decision, exactly as
    // it does for continuation.
    memoryDedupeEnabled: boolean('NEORECALL_MEMORY_DEDUPE_ENABLED', true),
    // How alike two cards must read before the model is asked about them at all.
    // Cosine over multilingual-e5 embeddings, whose similarities sit high even
    // for unrelated text, so this is deliberately close to 1. Lower it and the
    // sweep asks more questions; it never merges anything on this number alone.
    memoryDedupeSimilarityThreshold: number('NEORECALL_MEMORY_DEDUPE_SIMILARITY_THRESHOLD', 0.88, { min: 0, max: 1 }),
    // How far apart two cards may sit and still be candidates. Two lessons of the
    // same course on different days are two occasions and must stay two cards;
    // this is what keeps the sweep from ever considering them.
    memoryDedupeWindowMs: integer('NEORECALL_MEMORY_DEDUPE_WINDOW_MS', 6 * 60 * 60_000, { min: 0 }),
    // Model requests one sweep may make. Bounds what a backlog can cost.
    memoryDedupeMaxPairsPerRun: integer('NEORECALL_MEMORY_DEDUPE_MAX_PAIRS_PER_RUN', 20, { min: 0, max: 500 }),
    // Nearest neighbours considered per card before filtering.
    memoryDedupeNeighbours: integer('NEORECALL_MEMORY_DEDUPE_NEIGHBOURS', 5, { min: 1, max: 50 }),
    // Ask is answered by the same external provider. These limits keep one
    // client from queueing more generation than the provider can work through
    // while recordings are still arriving.
    askMaxPerHour: integer('NEORECALL_ASK_MAX_PER_HOUR', 240, { min: 0 }),
    askBurstPerMinute: integer('NEORECALL_ASK_BURST_PER_MINUTE', 20, { min: 0 }),
    // How often the worker looks for conversations to preview, boundaries to
    // redetect and material to consolidate. It bounds how long after crossing a
    // threshold a result appears, so it is the coarsest term in the latency a
    // user perceives.
    schedulerIntervalMs: integer('NEORECALL_SCHEDULER_INTERVAL_MS', 60_000, { min: 1_000 }),
    // How long a worker may hold a job before another may assume it died. It has
    // to exceed the slowest job the machine actually runs, and with generation
    // happening on this host a single consolidation is minutes of work — a lease
    // shorter than that would let a second worker start the same run while the
    // first is still writing the answer.
    jobLeaseMs: integer('NEORECALL_JOB_LEASE_MS', 1_800_000, { min: 10_000 }),
    jobMaxAttempts: integer('NEORECALL_JOB_MAX_ATTEMPTS', 5, { min: 1, max: 100 }),
    diagnosticRetentionDays: integer('NEORECALL_DIAGNOSTIC_RETENTION_DAYS', 7, { min: 1, max: 90 }),
    diagnosticMaxEventsPerUser: integer('NEORECALL_DIAGNOSTIC_MAX_EVENTS_PER_USER', 500, { min: 50, max: 10_000 }),
    diagnosticExportMaxEvents: integer('NEORECALL_DIAGNOSTIC_EXPORT_MAX_EVENTS', 250, { min: 10, max: 1_000 }),
    // Plaud Embedded partner credentials. Used only to mint per-user JWTs so
    // the mobile client can bind Note Pro / NotePin S over BLE. Audio never
    // goes to Plaud; leave both unset to hide the pairing session endpoint.
    plaudClientId: process.env.NEORECALL_PLAUD_CLIENT_ID || '',
    plaudClientSecret: process.env.NEORECALL_PLAUD_CLIENT_SECRET || '',
    plaudApiHost: (process.env.NEORECALL_PLAUD_API_HOST || 'platform-us.plaud.ai').replace(/^https?:\/\//, '').replace(/\/+$/, ''),
  };
  validateConfig(config, { promptReserveTokens: LLM_PROMPT_RESERVE_TOKENS });
  return Object.freeze(config);
}

module.exports = { getConfig, integer, number, boolean, LLM_PROMPT_RESERVE_TOKENS };
