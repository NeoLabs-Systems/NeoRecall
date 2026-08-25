'use strict';

const { z } = require('zod');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');

const schema = z.object({
  voiceMatchThreshold: z.number().min(-1).max(1).optional(),
  voiceMatchMargin: z.number().min(0).max(2).optional(),
  speakerClusterThreshold: z.number().min(-1).max(1).optional(),
  speakerClusterMergeThreshold: z.number().min(-1).max(1).optional(),
  speakerMinimumTurnMs: z.number().int().min(0).max(60_000).optional(),
  diarizationClusterDistance: z.number().min(0).max(2).optional(),
  speakerClusterMargin: z.number().min(0).max(2).optional(),
  speakerContinuityGapMs: z.number().int().min(0).max(60_000).optional(),
  speakerClusterContinuityThreshold: z.number().min(-1).max(1).optional(),
  dedupeTokenSimilarity: z.number().min(0).max(1).optional(),
  dedupeTimeToleranceMs: z.number().int().min(0).max(30_000).optional(),
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
  maxConsolidationLatencyMs: z.number().int().min(0).max(7 * 24 * 60 * 60_000).optional(),
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
  const db = getDatabase();
  db.transaction(() => {
    const statement = db.prepare(`INSERT INTO app_settings (key,value_json) VALUES (?,?)
      ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`);
    for (const [key, value] of Object.entries(parsed.data)) statement.run(key, JSON.stringify(value));
  })();
  return get();
}

module.exports = { get, update, schema };
