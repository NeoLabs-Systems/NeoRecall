'use strict';

const { z } = require('zod');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { isIanaTimezone } = require('../../utils/time');
const localAnalysis = require('../../transcription/local_analysis');
const { LANGUAGE_CODES, DEFAULT_LANGUAGE } = require('../../ai/prompts/output_language');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('settings');

const schema = z.object({
  // The language this account reads the product in and has its memories,
  // summaries and answers written in. One setting for both: a person who reads
  // the interface in German does not want their day described in English.
  language: z.enum(LANGUAGE_CODES).optional(),
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
  contextOriginalRetentionDays: z.number().int().min(1).max(365).optional(),
  keepRawAudio: z.boolean().optional(),
  vocabularyCorrectionEnabled: z.boolean().optional(),
  deferredSpeakerResolution: z.boolean().optional(),
  // Standing instructions the account owner gives the language model. Trimmed,
  // never interpreted here: what they mean is the model's business, and a rule
  // in this file about what they may say would be a phrase filter.
  instructionsGlobal: z.string().trim().optional(),
  instructionsMemories: z.string().trim().optional(),
  instructionsSummaries: z.string().trim().optional(),
  instructionsAsk: z.string().trim().optional(),
});

const keyMap = Object.freeze({
  language: 'language',
  consolidationIntervalMs: 'consolidation_interval_ms', timezone: 'timezone',
  recurringSpeakerMatching: 'recurring_speaker_matching', diarizationEnabled: 'diarization_enabled',
  chunkTargetMs: 'chunk_target_ms', chunkOverlapMs: 'chunk_overlap_ms',
  uploadOnlyOnUnmetered: 'upload_only_on_unmetered',
  recordingScheduleEnabled: 'recording_schedule_enabled',
  recordingStartMinute: 'recording_start_minute', recordingEndMinute: 'recording_end_minute',
  customVocabulary: 'custom_vocabulary',
  contextOriginalRetentionDays: 'context_original_retention_days',
  keepRawAudio: 'keep_raw_audio',
  vocabularyCorrectionEnabled: 'vocabulary_correction_enabled',
  deferredSpeakerResolution: 'deferred_speaker_resolution',
  instructionsGlobal: 'instructions_global',
  instructionsMemories: 'instructions_memories',
  instructionsSummaries: 'instructions_summaries',
  instructionsAsk: 'instructions_ask',
});

// Column name back to API name, so reading a row is a lookup rather than a
// scan of every key for every row.
const apiKeyByColumn = new Map(Object.entries(keyMap).map(([apiKey, column]) => [column, apiKey]));

function defaults() {
  const config = getConfig();
  return {
    // Null, not 'en': "this account has never chosen" is a different state from
    // "this account chose English", and only the first one lets a client adopt
    // the language it detected from the device on first sign-in without
    // overwriting a choice the owner made on another device.
    language: null,
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
    contextOriginalRetentionDays: 7,
    keepRawAudio: true,
    vocabularyCorrectionEnabled: true,
  // Re-resolving a finished conversation's speakers is a correction, not a
  // feature: without it a voice too briefly heard in any single chunk never
  // attaches to a person and every cluster keeps its own Speaker N.
  deferredSpeakerResolution: true,
    instructionsGlobal: '',
    instructionsMemories: '',
    instructionsSummaries: '',
    instructionsAsk: '',
  };
}

// Every setting that carries free-form instructions, so the length check and
// the prompt layer agree on the list.
const INSTRUCTION_KEYS = Object.freeze(['instructionsGlobal', 'instructionsMemories', 'instructionsSummaries', 'instructionsAsk']);

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
  // The installation's hard floor, reported separately from the effective
  // value. A client that only sees the effective value cannot tell a floor from
  // the current choice, so it ends up refusing to let the interval be lowered.
  result.minConsolidationIntervalMs = config.minConsolidationIntervalMs;
  result.effectiveConsolidationIntervalMs = Math.max(result.consolidationIntervalMs, config.minConsolidationIntervalMs);
  result.chunkMinMs = config.chunkMinMs;
  result.chunkMaxMs = config.chunkMaxMs;
  result.customVocabularyMaxTerms = config.customVocabularyMaxTerms;
  // What this build can actually offer, so the client's picker is a view of the
  // server's list rather than a second copy of it that can drift out of step.
  result.availableLanguages = LANGUAGE_CODES;
  result.customInstructionsMaxCharacters = config.customInstructionsMaxCharacters;
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
  for (const key of INSTRUCTION_KEYS) {
    const value = parsed.data[key];
    if (value !== undefined && [...value].length > config.customInstructionsMaxCharacters) {
      throw new HttpError(400, 'CUSTOM_INSTRUCTIONS_TOO_LONG',
        `Custom instructions may contain at most ${config.customInstructionsMaxCharacters} characters.`);
    }
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
    WHERE user_id=? AND display_name IS NOT NULL AND display_name_source='manual'
    ORDER BY updated_at DESC`).all(userId)
    .map((row) => row.display_name.trim()).filter(Boolean);
}

/**
 * Just the output language for an account.
 *
 * The AI layer needs this on every request and nothing else from the record, so
 * it reads one row rather than assembling the whole settings object (which also
 * queries voiceprints and probes the local analysis models).
 */
function outputLanguage(userId) {
  // Unset resolves to the default here rather than in every prompt.
  const row = getDatabase().prepare('SELECT value_json FROM user_settings WHERE user_id=? AND key=?')
    .get(userId, keyMap.language);
  if (!row) return DEFAULT_LANGUAGE;
  try { return JSON.parse(row.value_json); } catch { return DEFAULT_LANGUAGE; }
}

module.exports = { get, update, schema, transcriptionVocabulary, outputLanguage, INSTRUCTION_KEYS };
