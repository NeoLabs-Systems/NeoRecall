'use strict';

function integer(name, fallback, { min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = process.env[name];
  const value = raw === undefined || raw === '' ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

function number(name, fallback, { min = -Infinity, max = Infinity } = {}) {
  const raw = process.env[name];
  const value = raw === undefined || raw === '' ? fallback : Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new Error(`${name} must be a number between ${min} and ${max}.`);
  }
  return value;
}

function boolean(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  if (['1', 'true', 'yes', 'on'].includes(raw.toLowerCase())) return true;
  if (['0', 'false', 'no', 'off'].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} must be true or false.`);
}

// A capable model with a large context that supports strict JSON schema output,
// at a price that survives an always-on recorder. Overridable with
// AI_DEFAULT_MODEL; nothing in the pipeline depends on this particular model.
const defaultAiModel = 'deepseek/deepseek-v4-flash-0731';

function getConfig() {
  const chunkMinMs = integer('NEORECALL_CHUNK_MIN_MS', 15_000, { min: 1_000 });
  const chunkMaxMs = integer('NEORECALL_CHUNK_MAX_MS', 120_000, { min: chunkMinMs });
  const speakerPreviewMinimumMs = integer('NEORECALL_SPEAKER_PREVIEW_MIN_MS', 1_000, { min: 1_000, max: 10_000 });
  const speakerPreviewMaximumMs = integer('NEORECALL_SPEAKER_PREVIEW_MAX_MS', 10_000, { min: speakerPreviewMinimumMs, max: 10_000 });
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
    transcriptionProvider: process.env.TRANSCRIPTION_PROVIDER || 'sherpa',
    transcriptionApiBaseUrl: process.env.TRANSCRIPTION_API_BASE_URL || null,
    transcriptionApiKey: process.env.TRANSCRIPTION_API_KEY || null,
    sherpaThreads: integer('NEORECALL_SHERPA_THREADS', 4, { min: 1, max: 128 }),
    diarizationEnabled: boolean('NEORECALL_DIARIZATION_ENABLED', true),
    voiceMatchThreshold: number('NEORECALL_VOICE_MATCH_THRESHOLD', 0.72, { min: -1, max: 1 }),
    voiceMatchMargin: number('NEORECALL_VOICE_MATCH_MARGIN', 0.05, { min: 0, max: 2 }),
    speakerClusterThreshold: number('NEORECALL_SPEAKER_CLUSTER_THRESHOLD', 0.65, { min: -1, max: 1 }),
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
    speakerClusterContinuityThreshold: number('NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD', 0.5, { min: -1, max: 1 }),
    speakerPreviewMinimumMs,
    speakerPreviewMaximumMs,
    speakerPreviewMaxBytes: integer('NEORECALL_SPEAKER_PREVIEW_MAX_BYTES', 1024 * 1024, { min: 320_044 }),
    // Least text the statistical language detector is trusted with when the
    // recogniser labelled nothing itself. Measured against three hours of real
    // council audio: correctly labelled segments ran to a median of 88
    // characters, misdetected ones to 13, and 23 of 26 misdetections were under
    // thirty characters.
    languageDetectionMinimumCharacters: integer('NEORECALL_LANGUAGE_DETECTION_MIN_CHARACTERS', 30, { min: 0 }),
    dedupeTokenSimilarity: number('NEORECALL_DEDUPE_TOKEN_SIMILARITY', 0.82, { min: 0, max: 1 }),
    dedupeTimeToleranceMs: integer('NEORECALL_DEDUPE_TIME_TOLERANCE_MS', 2500, { min: 0 }),
    vadThreshold: number('NEORECALL_VAD_THRESHOLD', 0.5, { min: 0, max: 1 }),
    vadMinimumSpeechSeconds: number('NEORECALL_VAD_MIN_SPEECH_SECONDS', 0.25, { min: 0 }),
    vadMinimumSilenceSeconds: number('NEORECALL_VAD_MIN_SILENCE_SECONDS', 0.5, { min: 0 }),
    diarizationMinimumOnSeconds: number('NEORECALL_DIARIZATION_MIN_ON_SECONDS', 0.3, { min: 0 }),
    diarizationMinimumOffSeconds: number('NEORECALL_DIARIZATION_MIN_OFF_SECONDS', 0.2, { min: 0 }),
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
    // least this far apart. Together they bound preview cost on a stream that
    // never stops.
    conversationPreviewMinCharacters: integer('NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS', 800, { min: 1 }),
    conversationPreviewRefreshCharacters: integer('NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS', 1_500, { min: 1 }),
    conversationPreviewMinIntervalMs: integer('NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS', 300_000, { min: 0 }),
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
    searchWeights: {
      relevance: relevanceWeight / searchWeightTotal,
      recency: recencyWeight / searchWeightTotal,
      importance: importanceWeight / searchWeightTotal,
    },
    searchHalfLifeDays: number('NEORECALL_SEARCH_HALF_LIFE_DAYS', 30, { min: 0.01 }),
    aiProvider: process.env.AI_PROVIDER || 'openrouter',
    aiDefaultModel: process.env.AI_DEFAULT_MODEL || defaultAiModel,
    // Live conversation previews run far more often than consolidation and only
    // produce a title, a summary and topics, so they default to the same cheap
    // model but can be pointed somewhere else without touching consolidation.
    aiPreviewModel: process.env.AI_PREVIEW_MODEL || process.env.AI_DEFAULT_MODEL || defaultAiModel,
    aiTimeoutMs: integer('AI_REQUEST_TIMEOUT_MS', 120_000, { min: 1_000 }),
    aiMaxRetries: integer('AI_MAX_RETRIES', 2, { min: 0, max: 10 }),
    // Has to cover the sections, memories and mini-memories a full-size input
    // can justify; a completion cut off mid-JSON reads as a validation failure.
    //
    // Sized from measurement, and the measurement had a surprise in it. Three
    // hours of real council audio produced 24 315 completion tokens — but on a
    // reasoning model most of that is not the answer. One observed call spent
    // 12 307 of 15 979 completion tokens thinking before writing any JSON, and
    // an earlier attempt at the same input truncated mid-answer. The budget has
    // to cover reasoning *and* the answer, and reasoning length varies from call
    // to call, so the ceiling needs real headroom rather than a tight fit.
    // Nothing is charged for headroom that goes unused.
    aiConsolidationMaxOutputTokens: integer('AI_CONSOLIDATION_MAX_OUTPUT_TOKENS', 64_000, { min: 512, max: 200_000 }),
    // The preview's *answer* is tiny — a title, a summary, topics — but on a
    // reasoning model the internal tokens bill against the same limit, and one
    // observed call spent over 12 000 tokens thinking before any JSON. A budget
    // sized to the answer alone would truncate every preview. Unused headroom
    // costs nothing.
    aiPreviewMaxOutputTokens: integer('AI_PREVIEW_MAX_OUTPUT_TOKENS', 24_000, { min: 256, max: 200_000 }),
    openRouterApiKey: process.env.OPENROUTER_API_KEY || null,
    openRouterBaseUrl: (process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1').replace(/\/$/, ''),
    minConsolidationIntervalMs: integer('NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS', 300_000, { min: 0 }),
    // How long finished material may wait for the character threshold before it
    // is consolidated anyway. Without it, a short conversation at the end of a
    // day would stay a transcript with no memory until unrelated speech arrives.
    maxConsolidationLatencyMs: integer('NEORECALL_MAX_CONSOLIDATION_LATENCY_MS', 900_000, { min: 0 }),
    // Consecutive AI validation failures a conversation may cause before it is
    // quarantined. Candidates are always built oldest-first, so one conversation
    // the model cannot partition would otherwise poison every later run and stop
    // memory generation permanently.
    consolidationMaxFailures: integer('NEORECALL_CONSOLIDATION_MAX_FAILURES', 3, { min: 1, max: 100 }),
    // The least audio that may cause an outbound LLM request at all.
    //
    // A hard floor, not a heuristic: a one-minute recording never reaches a
    // model, whatever else would have made it eligible. Character thresholds
    // alone cannot promise that — a fast speaker clears them in forty seconds,
    // and the latency sweep deliberately consolidates material that never does.
    //
    // Cost is per request, not per conversation, so this gates what may *start*
    // a request. A short conversation still rides along in a request that longer
    // material already justified, where including it costs nothing extra.
    minAiAudioMs: integer('NEORECALL_MIN_AI_AUDIO_MS', 60_000, { min: 0 }),
    minNewMaterialChars: integer('NEORECALL_MIN_NEW_MATERIAL_CHARS', 1500, { min: 1 }),
    maxConsolidationInputChars: integer('NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS', 250_000, { min: 1000 }),
    // The character limit alone does not bound the *output*: many short
    // conversations produce a section and a memory each, and a completion that
    // runs past AI_CONSOLIDATION_MAX_OUTPUT_TOKENS arrives as truncated JSON,
    // which is indistinguishable from a model that cannot follow the contract.
    // A backlog draining after a long offline stretch is exactly when that
    // happens, so the batch is bounded by count as well.
    maxConsolidationConversations: integer('NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS', 12, { min: 1, max: 200 }),
    askMaxPerHour: integer('NEORECALL_ASK_MAX_PER_HOUR', 20, { min: 0 }),
    askBurstPerMinute: integer('NEORECALL_ASK_BURST_PER_MINUTE', 5, { min: 0 }),
    // How often the worker looks for conversations to preview, boundaries to
    // redetect and material to consolidate. It bounds how long after crossing a
    // threshold a result appears, so it is the coarsest term in the latency a
    // user perceives.
    schedulerIntervalMs: integer('NEORECALL_SCHEDULER_INTERVAL_MS', 60_000, { min: 1_000 }),
    jobLeaseMs: integer('NEORECALL_JOB_LEASE_MS', 300_000, { min: 10_000 }),
    jobMaxAttempts: integer('NEORECALL_JOB_MAX_ATTEMPTS', 5, { min: 1, max: 100 }),
    // Outbound OAuth apps for meeting cloud-recording sources. Empty means the
    // platform is unavailable on this install until an admin configures it.
    googleMeetOauthClientId: process.env.GOOGLE_MEET_OAUTH_CLIENT_ID || null,
    googleMeetOauthClientSecret: process.env.GOOGLE_MEET_OAUTH_CLIENT_SECRET || null,
    zoomOauthClientId: process.env.ZOOM_OAUTH_CLIENT_ID || null,
    zoomOauthClientSecret: process.env.ZOOM_OAUTH_CLIENT_SECRET || null,
    microsoftTeamsOauthClientId: process.env.MICROSOFT_TEAMS_OAUTH_CLIENT_ID || null,
    microsoftTeamsOauthClientSecret: process.env.MICROSOFT_TEAMS_OAUTH_CLIENT_SECRET || null,
    microsoftTeamsOauthTenant: process.env.MICROSOFT_TEAMS_OAUTH_TENANT || 'common',
    diagnosticRetentionDays: integer('NEORECALL_DIAGNOSTIC_RETENTION_DAYS', 7, { min: 1, max: 90 }),
    diagnosticMaxEventsPerUser: integer('NEORECALL_DIAGNOSTIC_MAX_EVENTS_PER_USER', 500, { min: 50, max: 10_000 }),
    diagnosticExportMaxEvents: integer('NEORECALL_DIAGNOSTIC_EXPORT_MAX_EVENTS', 250, { min: 10, max: 1_000 }),
  };
  if (config.speakerClusterContinuityThreshold > config.speakerClusterThreshold) {
    throw new Error('NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD must not exceed NEORECALL_SPEAKER_CLUSTER_THRESHOLD.');
  }
  if (config.conversationSoftGapMs >= config.conversationHardGapMs) {
    throw new Error('NEORECALL_CONVERSATION_SOFT_GAP_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS.');
  }
  if (config.conversationMinimumMs >= config.conversationHardGapMs) {
    throw new Error('NEORECALL_CONVERSATION_MINIMUM_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS.');
  }
  if (config.conversationMaximumMs <= config.conversationMinimumMs) {
    throw new Error('NEORECALL_CONVERSATION_MAXIMUM_MS must be longer than NEORECALL_CONVERSATION_MINIMUM_MS.');
  }
  if (config.conversationMaximumCharacters > config.maxConsolidationInputChars) {
    throw new Error('NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS must not exceed NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS.');
  }
  if (config.conversationPreviewMinCharacters > config.conversationMaximumCharacters) {
    throw new Error('NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS must not exceed NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS.');
  }
  return Object.freeze(config);
}

module.exports = { getConfig, integer, number, boolean };
