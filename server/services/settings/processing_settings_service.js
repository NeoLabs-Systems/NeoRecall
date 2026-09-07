'use strict';

const { z } = require('zod');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');

const schema = z.object({
  voiceMatchThreshold: z.number().min(-1).max(1).optional(),
  voiceMatchMargin: z.number().min(0).max(2).optional(),
  voiceEnrollFloor: z.number().min(-1).max(1).optional(),
  voiceEnrollMinimumMs: z.number().int().min(0).max(120_000).optional(),
  voiceRepairThreshold: z.number().min(-1).max(1).optional(),
  speakerClusterThreshold: z.number().min(-1).max(1).optional(),
  speakerClusterMergeThreshold: z.number().min(-1).max(1).optional(),
  speakerMinimumTurnMs: z.number().int().min(0).max(60_000).optional(),
  diarizationClusterDistance: z.number().min(0).max(2).optional(),
  speakerClusterMargin: z.number().min(0).max(2).optional(),
  speakerContinuityGapMs: z.number().int().min(0).max(60_000).optional(),
  speakerClusterContinuityThreshold: z.number().min(-1).max(1).optional(),
  // Audio conditioning. Only the values worth changing without a restart: a
  // switch to stop it outright on a live system, and the two knobs that decide
  // how hard it acts. Which normalizer and which output format are deployment
  // decisions, and stay in the environment.
  audioPreprocessEnabled: z.boolean().optional(),
  audioPreprocessHighpassHz: z.number().int().min(0).max(300).optional(),
  audioPreprocessDenoiseDb: z.number().min(0.01).max(97).optional(),
  audioPreprocessMaxGain: z.number().min(1).max(100).optional(),
  dedupeTokenSimilarity: z.number().min(0).max(1).optional(),
  dedupeTimeToleranceMs: z.number().int().min(0).max(30_000).optional(),
  transcriptRepetitionMinimumRepeats: z.number().int().min(3).max(1_000).optional(),
  transcriptRepetitionMaximumPatternWords: z.number().int().min(1).max(32).optional(),
  transcriptRepetitionMinimumCoverage: z.number().min(0.5).max(1).optional(),
  transcriptMaximumWordsPerSecond: z.number().min(1).max(50).optional(),
  conversationHardGapMs: z.number().int().min(1_000).max(24 * 60 * 60_000).optional(),
  conversationSoftGapMs: z.number().int().min(1_000).max(24 * 60 * 60_000).optional(),
  conversationMinimumMs: z.number().int().min(1_000).max(60 * 60_000).optional(),
  conversationQuietCloseMs: z.number().int().min(1_000).max(24 * 60 * 60_000).optional(),
  conversationValleyQuantile: z.number().min(0).max(1).optional(),
  conversationSemanticSimilarityThreshold: z.number().min(-1).max(1).optional(),
  conversationSemanticValleyProminence: z.number().min(0).max(2).optional(),
  conversationSemanticContextSegments: z.number().int().min(1).max(20).optional(),
  conversationMaximumMs: z.number().int().min(60_000).max(24 * 60 * 60_000).optional(),
  conversationMaximumCharacters: z.number().int().min(1_000).max(2_000_000).optional(),
  conversationPreviewMinCharacters: z.number().int().min(1).max(2_000_000).optional(),
  conversationPreviewRefreshCharacters: z.number().int().min(1).max(2_000_000).optional(),
  conversationPreviewMinIntervalMs: z.number().int().min(0).max(24 * 60 * 60_000).optional(),
  conversationPreviewFullCharacters: z.number().int().min(1).max(2_000_000).optional(),
  minAiAudioMs: z.number().int().min(0).max(24 * 60 * 60_000).optional(),
  minNewMaterialChars: z.number().int().min(1).max(1_000_000).optional(),
  minMemoryEvidenceMs: z.number().int().min(0).max(24 * 60 * 60_000).optional(),
  minMemoryEvidenceChars: z.number().int().min(0).max(1_000_000).optional(),
  maxConsolidationInputChars: z.number().int().min(1_000).max(2_000_000).optional(),
  maxConsolidationConversations: z.number().int().min(1).max(200).optional(),
  maxMemoryContinuationCandidates: z.number().int().min(0).max(32).optional(),
  memoryContinuationLookbackMs: z.number().int().min(0).max(30 * 24 * 60 * 60_000).optional(),
  maxConsolidationLatencyMs: z.number().int().min(0).max(7 * 24 * 60 * 60_000).optional(),
  memoryOccasionGapMs: z.number().int().min(0).max(24 * 60 * 60_000).optional(),
  memorySettleMs: z.number().int().min(0).max(24 * 60 * 60_000).optional(),
  memoryOccasionMaxWaitMs: z.number().int().min(60_000).max(7 * 24 * 60 * 60_000).optional(),
  memoryDedupeEnabled: z.boolean().optional(),
  memoryDedupeSimilarityThreshold: z.number().min(0).max(1).optional(),
  memoryDedupeWindowMs: z.number().int().min(0).max(30 * 24 * 60 * 60_000).optional(),
  memoryDedupeMaxPairsPerRun: z.number().int().min(0).max(500).optional(),
  memoryDedupeNeighbours: z.number().int().min(1).max(50).optional(),
  consolidationMaxFailures: z.number().int().min(1).max(100).optional(),
}).strict();

const keys = Object.freeze(Object.keys(schema.shape));

function get() {
  const base = getConfig();
  const result = Object.fromEntries(keys.map((key) => [key, base[key]]));
  for (const row of getDatabase().prepare('SELECT key,value_json FROM app_settings').all()) {
    if (keys.includes(row.key)) result[row.key] = JSON.parse(row.value_json);
  }
  return result;
}

function update(input) {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new HttpError(400, 'VALIDATION_ERROR', 'Processing settings are invalid.', parsed.error.flatten());
  const next = { ...get(), ...parsed.data };
  if (next.speakerClusterContinuityThreshold > next.speakerClusterThreshold) {
    throw new HttpError(400, 'INVALID_SPEAKER_LIMITS', 'The continuity match threshold must not exceed the plain cluster match threshold.');
  }
  if (next.voiceEnrollFloor > next.voiceMatchThreshold) {
    throw new HttpError(400, 'INVALID_SPEAKER_LIMITS', 'The bar for treating a voice as a new person must not exceed the bar for recognising a known one, or every voice would become a new person.');
  }
  if (next.voiceRepairThreshold > next.voiceMatchThreshold) {
    throw new HttpError(400, 'INVALID_SPEAKER_LIMITS', 'The duplicate-repair threshold must not exceed the voice match threshold.');
  }
  if (next.maxConsolidationInputChars < next.minNewMaterialChars) {
    throw new HttpError(400, 'INVALID_MATERIAL_LIMITS', 'The consolidation input limit must not be lower than the material threshold.');
  }
  if (next.conversationMinimumMs >= next.conversationHardGapMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The minimum conversation duration must be shorter than the hard boundary gap.');
  }
  if (next.conversationSoftGapMs >= next.conversationHardGapMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The soft conversation gap must be shorter than the hard boundary gap.');
  }
  if (next.conversationMaximumMs <= next.conversationMinimumMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The maximum conversation duration must be longer than the minimum duration.');
  }
  if (next.conversationMaximumCharacters > next.maxConsolidationInputChars) {
    throw new HttpError(400, 'INVALID_MATERIAL_LIMITS', 'The conversation character limit must not exceed the consolidation input limit.');
  }
  if (next.conversationPreviewMinCharacters > next.conversationMaximumCharacters) {
    throw new HttpError(400, 'INVALID_MATERIAL_LIMITS', 'The preview threshold must not exceed the conversation character limit, or no conversation would ever be previewed.');
  }
  // An occasion gap narrower than the boundary gap could never join anything:
  // every conversation is cut at the hard gap, so a shorter occasion gap means
  // no two fragments are ever read as one sitting.
  if (next.memoryOccasionGapMs < next.conversationHardGapMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The occasion gap must be at least as long as the hard boundary gap, or fragments of one sitting could never be joined.');
  }
  // Settling has to outlast an ordinary pause. Below the hard gap the first
  // fragment is written up before the pause that follows it has even ended,
  // which is the duplicate-card behaviour this exists to prevent.
  if (next.memorySettleMs < next.conversationHardGapMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The settle delay must be at least as long as the hard boundary gap, or a fragment is written up before the pause after it has ended.');
  }
  if (next.memoryOccasionMaxWaitMs <= next.memorySettleMs) {
    throw new HttpError(400, 'INVALID_CONVERSATION_LIMITS', 'The maximum occasion wait must be longer than the settle delay.');
  }
  const db = getDatabase();
  db.transaction(() => {
    const statement = db.prepare(`INSERT INTO app_settings (key,value_json) VALUES (?,?)
      ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`);
    for (const [key, value] of Object.entries(parsed.data)) statement.run(key, JSON.stringify(value));
  })();
  return get();
}

module.exports = { get, update, schema };
