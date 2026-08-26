'use strict';

const { z } = require('zod');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { isIanaTimezone } = require('../../utils/time');
const localAnalysis = require('../../transcription/local_analysis');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('settings');

const schema = z.object({
  consolidationIntervalMs: z.number().int().nonnegative().optional(),
  timezone: z.string().min(1).max(100).optional(),
  recurringSpeakerMatching: z.boolean().optional(),
  diarizationEnabled: z.boolean().optional(),
  chunkTargetMs: z.number().int().optional(),
  chunkOverlapMs: z.number().int().optional(),
  uploadOnlyOnUnmetered: z.boolean().optional(),
  recordingScheduleEnabled: z.boolean().optional(),
  recordingStartMinute: z.number().int().min(0).max(1439).optional(),
  recordingEndMinute: z.number().int().min(0).max(1439).optional(),
  customVocabulary: z.array(z.string().trim().min(1)).optional(),
  vocabularyCorrectionEnabled: z.boolean().optional(),
});

const keyMap = Object.freeze({
  consolidationIntervalMs: 'consolidation_interval_ms', timezone: 'timezone',
  recurringSpeakerMatching: 'recurring_speaker_matching', diarizationEnabled: 'diarization_enabled',
  chunkTargetMs: 'chunk_target_ms', chunkOverlapMs: 'chunk_overlap_ms',
  uploadOnlyOnUnmetered: 'upload_only_on_unmetered',
  recordingScheduleEnabled: 'recording_schedule_enabled',
  recordingStartMinute: 'recording_start_minute', recordingEndMinute: 'recording_end_minute',
  customVocabulary: 'custom_vocabulary',
  vocabularyCorrectionEnabled: 'vocabulary_correction_enabled',
});

// Column name back to API name, so reading a row is a lookup rather than a
// scan of every key for every row.
const apiKeyByColumn = new Map(Object.entries(keyMap).map(([apiKey, column]) => [column, apiKey]));

function defaults() {
  const config = getConfig();
  return {
    consolidationIntervalMs: config.minConsolidationIntervalMs,
    timezone: 'UTC',
    recurringSpeakerMatching: true,
    diarizationEnabled: config.diarizationEnabled,
    chunkTargetMs: config.chunkTargetMs,
    chunkOverlapMs: config.chunkOverlapMs,
    // Mobile capture should preserve the user's data allowance unless they
    // explicitly opt in. Android's unmetered capability is more accurate than
    // merely checking for a Wi-Fi transport (a hotspot can still be metered).
    uploadOnlyOnUnmetered: true,
    recordingScheduleEnabled: false,
    recordingStartMinute: 0,
    recordingEndMinute: 0,
    customVocabulary: [],
    vocabularyCorrectionEnabled: true,
  };
}

function uniqueTerms(terms) {
  const unique = new Map();
  for (const term of terms) {
    const key = term.toLocaleLowerCase();
    if (!unique.has(key)) unique.set(key, term);
  }
  return [...unique.values()];
}

function get(userId) {
  const result = defaults();
  for (const row of getDatabase().prepare('SELECT key,value_json FROM user_settings WHERE user_id=?').all(userId)) {
    const apiKey = apiKeyByColumn.get(row.key);
    if (!apiKey) continue;
    // A row that cannot be parsed falls back to its default rather than throwing:
    // settings are read on nearly every request, and one unreadable row would
    // otherwise take the whole account down instead of the one preference.
    try {
      result[apiKey] = JSON.parse(row.value_json);
    } catch (error) {
      logger.warn('Ignoring an unreadable stored setting', { userId, setting: apiKey, error });
    }
  }
  const config = getConfig();
  result.effectiveConsolidationIntervalMs = Math.max(result.consolidationIntervalMs, config.minConsolidationIntervalMs);
  result.chunkMinMs = config.chunkMinMs;
  result.chunkMaxMs = config.chunkMaxMs;
  result.customVocabularyMaxTerms = config.customVocabularyMaxTerms;
  result.customVocabularyMaxTermLength = config.customVocabularyMaxTermLength;
  result.vocabularyCorrectionMinimumLength = config.vocabularyCorrectionMinimumLength;
  result.automaticSpeakerVocabulary = speakerVocabulary(userId);
  // Derived, not chosen: a fact about this installation's local voice-analysis models.
  result.speakerIdentityAvailable = localAnalysis.available();
  return result;
}

function update(userId, input) {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new HttpError(400, 'VALIDATION_ERROR', 'Settings are invalid.', parsed.error.flatten());
  const config = getConfig();
  if (parsed.data.customVocabulary !== undefined) {
    if (parsed.data.customVocabulary.length > config.customVocabularyMaxTerms) {
      throw new HttpError(400, 'CUSTOM_VOCABULARY_TOO_LARGE', `Custom vocabulary may contain at most ${config.customVocabularyMaxTerms} terms.`);
    }
    if (parsed.data.customVocabulary.some((term) => [...term].length > config.customVocabularyMaxTermLength)) {
      throw new HttpError(400, 'CUSTOM_VOCABULARY_TERM_TOO_LONG', `Custom vocabulary terms may contain at most ${config.customVocabularyMaxTermLength} characters.`);
    }
    parsed.data.customVocabulary = uniqueTerms(parsed.data.customVocabulary);
  }
  if (parsed.data.timezone !== undefined && !isIanaTimezone(parsed.data.timezone)) {
    throw new HttpError(400, 'INVALID_TIMEZONE', 'Timezone must be a valid IANA timezone identifier.');
  }
  if (parsed.data.chunkTargetMs !== undefined && (parsed.data.chunkTargetMs < config.chunkMinMs || parsed.data.chunkTargetMs > config.chunkMaxMs)) {
    throw new HttpError(400, 'INVALID_CHUNK_DURATION', 'Chunk target is outside the server-supported range.');
  }
  const effectiveChunkTargetMs = parsed.data.chunkTargetMs ?? storedChunkTargetMs(userId);
  if (parsed.data.chunkOverlapMs !== undefined && (parsed.data.chunkOverlapMs < 0 || parsed.data.chunkOverlapMs >= effectiveChunkTargetMs)) {
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

function transcriptionVocabulary(userId) {
  const configured = get(userId).customVocabulary;
  const speakerNames = speakerVocabulary(userId);
  const maximum = getConfig().customVocabularyMaxTerms;
  return uniqueTerms([...speakerNames, ...configured]).slice(0, maximum);
}

// Just the stored chunk target, for validating an overlap against it. Reading
// the whole settings record (and its two extra queries) to get one number was
// the only reason update() called get() a second time.
function storedChunkTargetMs(userId) {
  const row = getDatabase().prepare('SELECT value_json FROM user_settings WHERE user_id=? AND key=?')
    .get(userId, keyMap.chunkTargetMs);
  if (!row) return defaults().chunkTargetMs;
  try { return JSON.parse(row.value_json); } catch { return defaults().chunkTargetMs; }
}

function speakerVocabulary(userId) {
  return getDatabase().prepare(`SELECT display_name FROM voiceprints
    WHERE user_id=? AND display_name IS NOT NULL ORDER BY updated_at DESC`).all(userId)
    .map((row) => row.display_name.trim()).filter(Boolean);
}

module.exports = { get, update, schema, transcriptionVocabulary };
