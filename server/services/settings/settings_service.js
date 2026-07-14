'use strict';

const { z } = require('zod');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { isIanaTimezone } = require('../../utils/time');

const schema = z.object({
  consolidationIntervalMs: z.number().int().nonnegative().optional(),
  timezone: z.string().min(1).max(100).optional(),
  recurringSpeakerMatching: z.boolean().optional(),
  diarizationEnabled: z.boolean().optional(),
  chunkTargetMs: z.number().int().optional(),
  chunkOverlapMs: z.number().int().optional(),
});

const keyMap = Object.freeze({
  consolidationIntervalMs: 'consolidation_interval_ms', timezone: 'timezone',
  recurringSpeakerMatching: 'recurring_speaker_matching', diarizationEnabled: 'diarization_enabled',
  chunkTargetMs: 'chunk_target_ms', chunkOverlapMs: 'chunk_overlap_ms',
});

function defaults() {
  const config = getConfig();
  return {
    consolidationIntervalMs: config.minConsolidationIntervalMs,
    timezone: 'UTC',
    recurringSpeakerMatching: true,
    diarizationEnabled: config.diarizationEnabled,
    chunkTargetMs: config.chunkTargetMs,
    chunkOverlapMs: config.chunkOverlapMs,
  };
}

function get(userId) {
  const result = defaults();
  for (const row of getDatabase().prepare('SELECT key,value_json FROM user_settings WHERE user_id=?').all(userId)) {
    const apiKey = Object.keys(keyMap).find((candidate) => keyMap[candidate] === row.key);
    if (apiKey) result[apiKey] = JSON.parse(row.value_json);
  }
  const config = getConfig();
  result.effectiveConsolidationIntervalMs = Math.max(result.consolidationIntervalMs, config.minConsolidationIntervalMs);
  result.chunkMinMs = config.chunkMinMs;
  result.chunkMaxMs = config.chunkMaxMs;
  return result;
}

function update(userId, input) {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new HttpError(400, 'VALIDATION_ERROR', 'Settings are invalid.', parsed.error.flatten());
  const config = getConfig();
  if (parsed.data.timezone !== undefined && !isIanaTimezone(parsed.data.timezone)) {
    throw new HttpError(400, 'INVALID_TIMEZONE', 'Timezone must be a valid IANA timezone identifier.');
  }
  if (parsed.data.chunkTargetMs !== undefined && (parsed.data.chunkTargetMs < config.chunkMinMs || parsed.data.chunkTargetMs > config.chunkMaxMs)) {
    throw new HttpError(400, 'INVALID_CHUNK_DURATION', 'Chunk target is outside the server-supported range.');
  }
  if (parsed.data.chunkOverlapMs !== undefined && (parsed.data.chunkOverlapMs < 0 || parsed.data.chunkOverlapMs >= (parsed.data.chunkTargetMs || get(userId).chunkTargetMs))) {
    throw new HttpError(400, 'INVALID_CHUNK_OVERLAP', 'Chunk overlap must be non-negative and shorter than the target chunk.');
  }
  const db = getDatabase();
  db.transaction(() => {
    const statement = db.prepare(`INSERT INTO user_settings (user_id,key,value_json) VALUES (?,?,?)
      ON CONFLICT(user_id,key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`);
    for (const [apiKey, value] of Object.entries(parsed.data)) statement.run(userId, keyMap[apiKey], JSON.stringify(value));
  })();
  return get(userId);
}

module.exports = { get, update, schema };
