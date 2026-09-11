'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');

const METERS = Object.freeze(['ai', 'transcription']);
const WINDOWS = Object.freeze({
  fourHour: { durationMs: 4 * 60 * 60 * 1000 },
  weekly: { durationMs: 7 * 24 * 60 * 60 * 1000 },
});
const MAX_AI_RESERVATION_TOKENS = 100_000;
const INSTALL_KEYS = Object.freeze({
  aiTokens4h: 'aiTokens4h',
  aiTokensWeekly: 'aiTokensWeekly',
  transcriptionSeconds4h: 'transcriptionSeconds4h',
  transcriptionSecondsWeekly: 'transcriptionSecondsWeekly',
});
const USER_COLUMNS = Object.freeze({
  ai: { fourHour: 'ai_limit_4h', weekly: 'ai_limit_weekly' },
  transcription: { fourHour: 'transcription_limit_4h', weekly: 'transcription_limit_weekly' },
});

// In-process reservation: `${userId}:${meter}` -> reserved amount. Concurrent
// Ask + consolidation (or two speech chunks) must see each other as in flight.
const _reservations = new Map();

class UsageLimitExceededError extends HttpError {
  constructor(meter, windowKey, snapshot) {
    const label = windowKey === 'fourHour' ? 'the last 4 hours' : 'the last 7 days';
    const meterSnapshot = snapshot[meter];
    const usage = meterSnapshot.usage[windowKey];
    const limit = meterSnapshot.limits[windowKey];
    const noun = meter === 'ai' ? 'language-model usage' : 'transcription';
    super(429, 'USAGE_LIMIT_EXCEEDED', `The ${noun} limit for ${label} has been reached (${usage} of ${limit}).`, {
      meter,
      window: windowKey,
      usage: snapshot,
    });
    this.name = 'UsageLimitExceededError';
    this.retryAt = retryAtForMeter(meterSnapshot);
  }
}

function noopReleaseReservation() {}

function reservationKey(userId, meter) {
  return `${userId}:${meter}`;
}

function reservedAmount(userId, meter) {
  return _reservations.get(reservationKey(userId, meter)) || 0;
}

function addReservation(userId, meter, amount) {
  const key = reservationKey(userId, meter);
  _reservations.set(key, reservedAmount(userId, meter) + amount);
}

function releaseReservation(userId, meter, amount) {
  const key = reservationKey(userId, meter);
  const next = reservedAmount(userId, meter) - amount;
  if (next <= 0) _reservations.delete(key);
  else _reservations.set(key, next);
}

function clearReservations() {
  _reservations.clear();
}

function asNonNegativeInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) return null;
  return parsed;
}

function finiteLimit(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function readInstallOverrides() {
  const overrides = {};
  for (const row of getDatabase().prepare('SELECT key,value_json FROM app_settings').all()) {
    if (!Object.values(INSTALL_KEYS).includes(row.key)) continue;
    try { overrides[row.key] = JSON.parse(row.value_json); } catch { /* inherit env */ }
  }
  return overrides;
}

function configuredDefaultLimits() {
  const config = getConfig();
  const overrides = readInstallOverrides();
  return {
    ai: {
      fourHour: finiteLimit(overrides.aiTokens4h ?? config.aiTokens4h),
      weekly: finiteLimit(overrides.aiTokensWeekly ?? config.aiTokensWeekly),
    },
    transcription: {
      fourHour: finiteLimit(overrides.transcriptionSeconds4h ?? config.transcriptionSeconds4h),
      weekly: finiteLimit(overrides.transcriptionSecondsWeekly ?? config.transcriptionSecondsWeekly),
    },
  };
}

function getInstallDefaults() {
  const config = getConfig();
  const overrides = readInstallOverrides();
  return {
    aiTokens4h: asNonNegativeInteger(overrides.aiTokens4h ?? config.aiTokens4h) ?? 0,
    aiTokensWeekly: asNonNegativeInteger(overrides.aiTokensWeekly ?? config.aiTokensWeekly) ?? 0,
    transcriptionSeconds4h: asNonNegativeInteger(overrides.transcriptionSeconds4h ?? config.transcriptionSeconds4h) ?? 0,
    transcriptionSecondsWeekly: asNonNegativeInteger(overrides.transcriptionSecondsWeekly ?? config.transcriptionSecondsWeekly) ?? 0,
  };
}

function setInstallDefaults(input) {
  const allowed = Object.values(INSTALL_KEYS);
  const db = getDatabase();
  db.transaction(() => {
    const statement = db.prepare(`INSERT INTO app_settings (key,value_json) VALUES (?,?)
      ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`);
    for (const key of allowed) {
      if (!Object.hasOwn(input, key)) continue;
      const value = asNonNegativeInteger(input[key]);
      if (value == null) throw new HttpError(400, 'VALIDATION_ERROR', `Usage limit ${key} must be an integer of 0 or more.`);
      statement.run(key, JSON.stringify(value));
    }
  })();
  return getInstallDefaults();
}

function resolveLimit(custom, inherited) {
  if (custom == null) return inherited;
  return custom > 0 ? custom : null;
}

function parseSqliteDate(value) {
  const text = String(value || '').trim();
  if (!text) return null;
  const normalized = text.includes('T') ? text : `${text.replace(' ', 'T')}Z`;
  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? null : date;
}

function nextDecreaseAt(rows, durationMs, usage, limit) {
  if (limit == null) return null;
  const positiveRows = rows.filter((row) => Number(row.amount) > 0);
  if (!positiveRows.length) return null;
  let toExpire = 0;
  const requiredExpiry = usage >= limit ? usage - limit + 1 : 1;
  for (const row of positiveRows) {
    toExpire += Number(row.amount);
    if (toExpire < requiredExpiry) continue;
    const createdAt = parseSqliteDate(row.created_at);
    return createdAt ? new Date(createdAt.getTime() + durationMs).toISOString() : null;
  }
  return null;
}

function retryAtForMeter(meterSnapshot) {
  const candidates = [];
  for (const windowKey of Object.keys(WINDOWS)) {
    if (!meterSnapshot.reached[windowKey]) continue;
    if (meterSnapshot.nextDecreaseAt[windowKey]) candidates.push(meterSnapshot.nextDecreaseAt[windowKey]);
  }
  if (!candidates.length) return new Date(Date.now() + 60_000).toISOString();
  return candidates.sort()[0];
}

function usageRows(userId, meter, durationMs) {
  const cutoff = new Date(Date.now() - durationMs).toISOString();
  const db = getDatabase();
  if (meter === 'ai') {
    return db.prepare(`SELECT COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0) AS amount, completed_at AS created_at
      FROM ai_requests
      WHERE user_id=? AND state='succeeded' AND completed_at>?
      ORDER BY completed_at ASC`).all(userId, cutoff);
  }
  return db.prepare(`SELECT CAST((duration_ms + 999) / 1000 AS INTEGER) AS amount, created_at
    FROM transcription_usage
    WHERE user_id=? AND created_at>?
    ORDER BY created_at ASC`).all(userId, cutoff);
}

function userLimitRow(userId) {
  return getDatabase().prepare(`SELECT ai_limit_4h, ai_limit_weekly, transcription_limit_4h, transcription_limit_weekly
    FROM users WHERE id=?`).get(userId) || {};
}

function meterSnapshot(userId, meter, { includeReservations = false } = {}) {
  const row = userLimitRow(userId);
  const defaults = configuredDefaultLimits()[meter];
  const customFourHour = row[USER_COLUMNS[meter].fourHour];
  const customWeekly = row[USER_COLUMNS[meter].weekly];
  const limits = {
    fourHour: resolveLimit(customFourHour, defaults.fourHour),
    weekly: resolveLimit(customWeekly, defaults.weekly),
    fourHourIsCustom: customFourHour != null,
    weeklyIsCustom: customWeekly != null,
  };
  const reserved = includeReservations ? reservedAmount(userId, meter) : 0;
  const usage = {};
  const remaining = {};
  const reached = {};
  const nextDecrease = {};
  for (const [windowKey, window] of Object.entries(WINDOWS)) {
    const rows = usageRows(userId, meter, window.durationMs);
    const used = rows.reduce((total, item) => total + Number(item.amount || 0), 0) + reserved;
    const limit = limits[windowKey];
    usage[windowKey] = used;
    remaining[windowKey] = limit == null ? null : Math.max(0, limit - used);
    reached[windowKey] = limit != null && used >= limit;
    nextDecrease[windowKey] = nextDecreaseAt(rows, window.durationMs, used, limit);
  }
  return {
    limits,
    usage,
    remaining,
    reached: { ...reached, any: reached.fourHour || reached.weekly },
    nextDecreaseAt: nextDecrease,
  };
}

function getUsageSnapshot(userId, options = {}) {
  return {
    ai: meterSnapshot(userId, 'ai', options),
    transcription: meterSnapshot(userId, 'transcription', options),
  };
}

function calculateReservation(limits) {
  const finite = [limits.fourHour, limits.weekly].filter((limit) => Number.isFinite(limit) && limit > 0);
  if (!finite.length) return 1;
  return Math.min(MAX_AI_RESERVATION_TOKENS, Math.max(1, Math.floor(Math.min(...finite) * 0.1)));
}

function windowExceededBy(meterSnapshot, reserve) {
  for (const windowKey of Object.keys(WINDOWS)) {
    const limit = meterSnapshot.limits[windowKey];
    if (limit != null && meterSnapshot.usage[windowKey] + reserve > limit) return windowKey;
  }
  return null;
}

function enforce(userId, meter, options = {}) {
  if (!METERS.includes(meter)) throw new Error(`Unknown usage meter: ${meter}`);
  const snapshot = getUsageSnapshot(userId, { includeReservations: true });
  const meterSnapshot = snapshot[meter];
  if (meterSnapshot.reached.fourHour) throw new UsageLimitExceededError(meter, 'fourHour', snapshot);
  if (meterSnapshot.reached.weekly) throw new UsageLimitExceededError(meter, 'weekly', snapshot);
  if (meterSnapshot.limits.fourHour == null && meterSnapshot.limits.weekly == null) {
    return { snapshot, releaseReservation: noopReleaseReservation };
  }
  const reserve = options.reserve != null
    ? Math.max(1, Math.floor(Number(options.reserve) || 0))
    : calculateReservation(meterSnapshot.limits);
  const exceeded = windowExceededBy(meterSnapshot, reserve);
  if (exceeded) throw new UsageLimitExceededError(meter, exceeded, snapshot);
  addReservation(userId, meter, reserve);
  return { snapshot, releaseReservation: () => releaseReservation(userId, meter, reserve) };
}

function rejectIfReached(userId, meter) {
  const snapshot = getUsageSnapshot(userId, { includeReservations: true });
  const meterSnapshot = snapshot[meter];
  if (meterSnapshot.reached.fourHour) throw new UsageLimitExceededError(meter, 'fourHour', snapshot);
  if (meterSnapshot.reached.weekly) throw new UsageLimitExceededError(meter, 'weekly', snapshot);
  return snapshot;
}

function recordTranscription(userId, chunkId, durationMs) {
  const ms = Math.max(1, Math.floor(Number(durationMs) || 0));
  getDatabase().prepare(`INSERT INTO transcription_usage (id,user_id,chunk_id,duration_ms)
    VALUES (?,?,?,?) ON CONFLICT(chunk_id) DO NOTHING`).run(crypto.randomUUID(), userId, chunkId, ms);
}

function getUserLimits(userId) {
  const row = getDatabase().prepare(`SELECT id,username,ai_limit_4h,ai_limit_weekly,transcription_limit_4h,transcription_limit_weekly
    FROM users WHERE id=?`).get(userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'User not found.');
  return {
    userId: row.id,
    username: row.username,
    aiLimit4h: row.ai_limit_4h,
    aiLimitWeekly: row.ai_limit_weekly,
    transcriptionLimit4h: row.transcription_limit_4h,
    transcriptionLimitWeekly: row.transcription_limit_weekly,
    defaults: getInstallDefaults(),
    usage: getUsageSnapshot(userId),
  };
}

function parseOverride(value, name) {
  if (value == null) return null;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new HttpError(400, 'VALIDATION_ERROR', `${name} must be null, 0 (unlimited), or a positive integer.`);
  }
  return parsed;
}

function setUserLimits(userId, input) {
  const existing = getUserLimits(userId);
  const next = {
    aiLimit4h: Object.hasOwn(input, 'aiLimit4h') ? parseOverride(input.aiLimit4h, 'aiLimit4h') : existing.aiLimit4h,
    aiLimitWeekly: Object.hasOwn(input, 'aiLimitWeekly') ? parseOverride(input.aiLimitWeekly, 'aiLimitWeekly') : existing.aiLimitWeekly,
    transcriptionLimit4h: Object.hasOwn(input, 'transcriptionLimit4h')
      ? parseOverride(input.transcriptionLimit4h, 'transcriptionLimit4h') : existing.transcriptionLimit4h,
    transcriptionLimitWeekly: Object.hasOwn(input, 'transcriptionLimitWeekly')
      ? parseOverride(input.transcriptionLimitWeekly, 'transcriptionLimitWeekly') : existing.transcriptionLimitWeekly,
  };
  const changed = getDatabase().prepare(`UPDATE users SET ai_limit_4h=?,ai_limit_weekly=?,transcription_limit_4h=?,transcription_limit_weekly=?
    WHERE id=?`).run(next.aiLimit4h, next.aiLimitWeekly, next.transcriptionLimit4h, next.transcriptionLimitWeekly, userId).changes;
  if (!changed) throw new HttpError(404, 'NOT_FOUND', 'User not found.');
  return getUserLimits(userId);
}

function transcriptionSecondsFor(durationMs) {
  return Math.max(1, Math.ceil(Math.max(0, Number(durationMs) || 0) / 1000));
}

module.exports = {
  METERS,
  WINDOWS,
  MAX_AI_RESERVATION_TOKENS,
  UsageLimitExceededError,
  configuredDefaultLimits,
  getInstallDefaults,
  setInstallDefaults,
  getUsageSnapshot,
  enforce,
  rejectIfReached,
  recordTranscription,
  releaseReservation,
  clearReservations,
  getUserLimits,
  setUserLimits,
  retryAtForMeter,
  transcriptionSecondsFor,
};
