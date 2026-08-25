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

function jsonObject(name) {
  const raw = String(process.env[name] || '').trim();
  if (!raw) return null;
  let parsed;
  try { parsed = JSON.parse(raw); } catch (error) {
    throw new Error(`${name} must be valid JSON: ${error.message}`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${name} must be a JSON object, for example {"chat_template_kwargs":{"enable_thinking":false}}.`);
  }
  return parsed;
}

function boolean(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  if (['1', 'true', 'yes', 'on'].includes(raw.toLowerCase())) return true;
  if (['0', 'false', 'no', 'off'].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} must be true or false.`);
}

/// Context kept aside from every request for the chat template and for the gap
/// between a character-based estimate of the prompt and the real tokenizer.
/// Exported so the input budget and the configuration check that guards it use
/// the same number.
const LLM_PROMPT_RESERVE_TOKENS = 512;

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
    transcriptionProvider: process.env.TRANSCRIPTION_PROVIDER || 'openai-compatible',
    transcriptionApiBaseUrl: (process.env.TRANSCRIPTION_API_BASE_URL || '').replace(/\/+$/, '') || null,
    transcriptionApiKey: process.env.TRANSCRIPTION_API_KEY || null,
    transcriptionApiModel: process.env.TRANSCRIPTION_API_MODEL || null,
    transcriptionApiLanguage: process.env.TRANSCRIPTION_API_LANGUAGE || null,
    transcriptionApiResponseFormat: process.env.TRANSCRIPTION_API_RESPONSE_FORMAT || null,
    transcriptionTimeoutMs: integer('TRANSCRIPTION_REQUEST_TIMEOUT_MS', 1_800_000, { min: 1_000 }),
    transcriptionPollIntervalMs: integer('TRANSCRIPTION_POLL_INTERVAL_MS', 1_000, { min: 250, max: 60_000 }),
    // Voice activity detection and diarization run in this process on models
    // small enough to be unremarkable — a 640 KB VAD and 31 MB of segmentation
    // and speaker-embedding weights, against the gigabytes speech recognition
    // and a language model would need. They are what NeoRecall still does
    // itself, because they are what an external transcription service cannot
    // give back: a service returns words, and at best a speaker label that is
    // only consistent inside the one request that produced it. A voice
    // embedding per turn is what makes a speaker the same person an hour later.
    diarizationEnabled: boolean('NEORECALL_DIARIZATION_ENABLED', true),
    // Native threads for the audio models. They run per chunk on a handful of
    // seconds of audio, so this is a small number by design.
    sherpaThreads: integer('NEORECALL_SHERPA_THREADS', 2, { min: 1, max: 128 }),
    // Speech detection. Below the threshold a chunk is treated as silence and
    // never reaches the transcription service at all, which on an always-on
    // recorder is most of the day and most of the bill.
    vadThreshold: number('NEORECALL_VAD_THRESHOLD', 0.5, { min: 0, max: 1 }),
    vadMinimumSpeechSeconds: number('NEORECALL_VAD_MIN_SPEECH_SECONDS', 0.25, { min: 0 }),
    vadMinimumSilenceSeconds: number('NEORECALL_VAD_MIN_SILENCE_SECONDS', 0.5, { min: 0 }),
    diarizationMinimumOnSeconds: number('NEORECALL_DIARIZATION_MIN_ON_SECONDS', 0.3, { min: 0 }),
    diarizationMinimumOffSeconds: number('NEORECALL_DIARIZATION_MIN_OFF_SECONDS', 0.2, { min: 0 }),
    // Recognising a voice in a *different* recording. Stricter than matching
    // inside one, because merging two people into a single named speaker is far
    // harder to undo than leaving them apart, but no longer so strict that the
    // same person earns a new entry in the Speakers screen every session. The
    // same voice measured a median of 0.78 across separate samples, so 0.62
    // leaves margin on both sides.
    voiceMatchThreshold: number('NEORECALL_VOICE_MATCH_THRESHOLD', 0.62, { min: -1, max: 1 }),
    voiceMatchMargin: number('NEORECALL_VOICE_MATCH_MARGIN', 0.05, { min: 0, max: 2 }),
    // How far apart two voices may be and still be grouped *inside* one chunk.
    //
    // This is a distance handed to the diarizer, where a larger value merges
    // more, and it is deliberately a separate setting from the similarity
    // threshold below even though both are about "the same voice". They point in
    // opposite directions — raising this one yields fewer speakers, raising that
    // one yields more — and for a while they were the same number, so an
    // operator turning it to stop speakers multiplying made one half better and
    // the other half worse.
    diarizationClusterDistance: number('NEORECALL_DIARIZATION_CLUSTER_DISTANCE', 0.65, { min: 0, max: 2 }),
    // How alike a turn must be to a cluster's centroid to be the same voice
    // across chunks. A cosine similarity, so larger means stricter.
    //
    // Measured against two known-different voices rather than chosen. Given at
    // least two seconds of speech per fingerprint, the same voice never scored
    // below 0.55 and two different voices never above 0.50 — so anything in that
    // gap separates them cleanly. The old default of 0.65 sat well above the
    // floor for a genuine match, which is why one person kept failing to match
    // themselves and minting another speaker instead.
    speakerClusterThreshold: number('NEORECALL_SPEAKER_CLUSTER_THRESHOLD', 0.52, { min: -1, max: 1 }),
    // Two clusters in one recording this alike are one person the matcher
    // already split, and are merged back rather than left to accumulate.
    speakerClusterMergeThreshold: number('NEORECALL_SPEAKER_CLUSTER_MERGE_THRESHOLD', 0.55, { min: -1, max: 1 }),
    // Below two seconds of speech a fingerprint simply does not identify anyone,
    // and no threshold repairs that. Measured: with one second per fingerprint,
    // the same voice ranged from 0.20 to 0.87 while two different voices reached
    // 0.77 — the two populations overlap almost completely. At two seconds they
    // separate with room to spare.
    //
    // This counts the speech a fingerprint was *pooled* from, not the length of
    // one turn, so a speaker who says four one-second things in a chunk clears it
    // comfortably. Speech below the bar may still join a voice that already
    // exists; it may not found one, and it may not move a centroid.
    speakerMinimumTurnMs: integer('NEORECALL_SPEAKER_MINIMUM_TURN_MS', 2_000, { min: 0, max: 60_000 }),
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
    // The relaxed bar a speaker still talking across a chunk boundary is held
    // to, so it has to sit below the plain threshold to mean anything. 0.3 is
    // between where different voices typically land (median 0.36) and the plain
    // bar, so it rescues a continuing speaker without waving through a new one.
    speakerClusterContinuityThreshold: number('NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD', 0.42, { min: -1, max: 1 }),
    speakerPreviewMinimumMs,
    speakerPreviewMaximumMs,
    speakerPreviewMaxBytes: integer('NEORECALL_SPEAKER_PREVIEW_MAX_BYTES', 1024 * 1024, { min: 320_044 }),
    dedupeTokenSimilarity: number('NEORECALL_DEDUPE_TOKEN_SIMILARITY', 0.82, { min: 0, max: 1 }),
    dedupeTimeToleranceMs: integer('NEORECALL_DEDUPE_TIME_TOLERANCE_MS', 2500, { min: 0 }),
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
    // How many conversations one run may carry. Batching several into a single
    // request used to amortize a per-request price; it also asked the model to
    // hold several unrelated occasions in mind at once, which is the harder job
    // and the one it does worse. One conversation per run is the accurate unit —
    // it is what a memory is anchored to — and the scheduler starts the next run
    // on its next tick, so a backlog still drains continuously.
    maxConsolidationConversations: integer('NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS', 1, { min: 1, max: 200 }),
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
  // An output budget the context cannot also hold a prompt beside would leave
  // nothing to send. Caught at startup, where it is a one-line fix, rather than
  // as a scheduler exception on the first conversation of the day.
  for (const name of ['AI_CONSOLIDATION_MAX_OUTPUT_TOKENS', 'AI_PREVIEW_MAX_OUTPUT_TOKENS']) {
    const budget = name === 'AI_CONSOLIDATION_MAX_OUTPUT_TOKENS' ? config.aiConsolidationMaxOutputTokens : config.aiPreviewMaxOutputTokens;
    if (budget + LLM_PROMPT_RESERVE_TOKENS >= config.llmContextSize) {
      throw new Error(`${name} (${budget}) leaves no room for input inside LLM_CONTEXT_SIZE (${config.llmContextSize}).`);
    }
  }
  return Object.freeze(config);
}

module.exports = { getConfig, integer, number, boolean, LLM_PROMPT_RESERVE_TOKENS };
