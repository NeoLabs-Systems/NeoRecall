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

function getConfig() {
  const chunkMinMs = integer('NEORECALL_CHUNK_MIN_MS', 15_000, { min: 1_000 });
  const chunkMaxMs = integer('NEORECALL_CHUNK_MAX_MS', 120_000, { min: chunkMinMs });
  const speakerPreviewMinimumMs = integer('NEORECALL_SPEAKER_PREVIEW_MIN_MS', 5_000, { min: 5_000, max: 10_000 });
  const speakerPreviewMaximumMs = integer('NEORECALL_SPEAKER_PREVIEW_MAX_MS', 10_000, { min: speakerPreviewMinimumMs, max: 10_000 });
  const relevanceWeight = number('NEORECALL_SEARCH_RELEVANCE_WEIGHT', 0.5, { min: 0 });
  const recencyWeight = number('NEORECALL_SEARCH_RECENCY_WEIGHT', 0.25, { min: 0 });
  const importanceWeight = number('NEORECALL_SEARCH_IMPORTANCE_WEIGHT', 0.25, { min: 0 });
  const searchWeightTotal = relevanceWeight + recencyWeight + importanceWeight;
  if (searchWeightTotal <= 0) throw new Error('At least one search weight must be greater than zero.');

  return Object.freeze({
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
    importFailedTtlHours: integer('NEORECALL_IMPORT_FAILED_TTL_HOURS', 24, { min: 1 }),
    transcriptionProvider: process.env.TRANSCRIPTION_PROVIDER || 'sherpa',
    transcriptionApiBaseUrl: process.env.TRANSCRIPTION_API_BASE_URL || null,
    transcriptionApiKey: process.env.TRANSCRIPTION_API_KEY || null,
    sherpaThreads: integer('NEORECALL_SHERPA_THREADS', 4, { min: 1, max: 128 }),
    diarizationEnabled: boolean('NEORECALL_DIARIZATION_ENABLED', true),
    voiceMatchThreshold: number('NEORECALL_VOICE_MATCH_THRESHOLD', 0.72, { min: -1, max: 1 }),
    voiceMatchMargin: number('NEORECALL_VOICE_MATCH_MARGIN', 0.05, { min: 0, max: 2 }),
    speakerClusterThreshold: number('NEORECALL_SPEAKER_CLUSTER_THRESHOLD', 0.65, { min: -1, max: 1 }),
    speakerPreviewMinimumMs,
    speakerPreviewMaximumMs,
    speakerPreviewMaxBytes: integer('NEORECALL_SPEAKER_PREVIEW_MAX_BYTES', 1024 * 1024, { min: 320_044 }),
    dedupeTokenSimilarity: number('NEORECALL_DEDUPE_TOKEN_SIMILARITY', 0.82, { min: 0, max: 1 }),
    dedupeTimeToleranceMs: integer('NEORECALL_DEDUPE_TIME_TOLERANCE_MS', 2500, { min: 0 }),
    vadThreshold: number('NEORECALL_VAD_THRESHOLD', 0.5, { min: 0, max: 1 }),
    vadMinimumSpeechSeconds: number('NEORECALL_VAD_MIN_SPEECH_SECONDS', 0.25, { min: 0 }),
    vadMinimumSilenceSeconds: number('NEORECALL_VAD_MIN_SILENCE_SECONDS', 0.5, { min: 0 }),
    diarizationMinimumOnSeconds: number('NEORECALL_DIARIZATION_MIN_ON_SECONDS', 0.3, { min: 0 }),
    diarizationMinimumOffSeconds: number('NEORECALL_DIARIZATION_MIN_OFF_SECONDS', 0.2, { min: 0 }),
    conversationHardGapMs: integer('NEORECALL_CONVERSATION_HARD_GAP_MS', 180_000, { min: 1_000 }),
    conversationMinimumMs: integer('NEORECALL_CONVERSATION_MINIMUM_MS', 30_000, { min: 1_000 }),
    conversationQuietCloseMs: integer('NEORECALL_CONVERSATION_QUIET_CLOSE_MS', 300_000, { min: 1_000 }),
    conversationValleyQuantile: number('NEORECALL_CONVERSATION_VALLEY_QUANTILE', 0.25, { min: 0, max: 1 }),
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
    aiDefaultModel: process.env.AI_DEFAULT_MODEL || null,
    aiTimeoutMs: integer('AI_REQUEST_TIMEOUT_MS', 120_000, { min: 1_000 }),
    aiMaxRetries: integer('AI_MAX_RETRIES', 2, { min: 0, max: 10 }),
    openRouterApiKey: process.env.OPENROUTER_API_KEY || null,
    openRouterBaseUrl: (process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1').replace(/\/$/, ''),
    minConsolidationIntervalMs: integer('NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS', 3_600_000, { min: 0 }),
    minNewMaterialChars: integer('NEORECALL_MIN_NEW_MATERIAL_CHARS', 1500, { min: 1 }),
    maxConsolidationInputChars: integer('NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS', 50_000, { min: 1000 }),
    askMaxPerHour: integer('NEORECALL_ASK_MAX_PER_HOUR', 20, { min: 0 }),
    askBurstPerMinute: integer('NEORECALL_ASK_BURST_PER_MINUTE', 5, { min: 0 }),
    jobLeaseMs: integer('NEORECALL_JOB_LEASE_MS', 300_000, { min: 10_000 }),
    jobMaxAttempts: integer('NEORECALL_JOB_MAX_ATTEMPTS', 5, { min: 1, max: 100 }),
  });
}

module.exports = { getConfig, integer, number, boolean };
