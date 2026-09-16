'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-usage-'));
process.env.NEORECALL_AI_TOKENS_4H = '0';
process.env.NEORECALL_AI_TOKENS_WEEKLY = '0';
process.env.NEORECALL_TRANSCRIPTION_SECONDS_4H = '0';
process.env.NEORECALL_TRANSCRIPTION_SECONDS_WEEKLY = '0';

const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { getDatabase } = require('../../server/db/database');
const usage = require('../../server/services/usage/usage_limit_service');

const db = getDatabase();

function insertUser(username = `user-${crypto.randomUUID()}`) {
  const id = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(id, username, 'hash');
  return id;
}

function insertAiRequest(userId, tokens, completedAt = new Date().toISOString()) {
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,prompt_tokens,completion_tokens,reserved_at,completed_at)
    VALUES (?,?, 'ask','openai','test','succeeded',?,?,?,?)`)
    .run(crypto.randomUUID(), userId, tokens, 0, completedAt, completedAt);
}

function insertChunk(userId) {
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'D','test','desktop')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'ended')`)
    .run(sessionId, userId, deviceId, sessionId, '2026-09-11T10:00:00.000Z', '2026-09-11T10:00:00.000Z', '2026-09-11T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,-1)`).run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,? ,1,'wav','pcm_s16le','mono','2026-09-11T10:00:00.000Z',0,30000,'uploaded')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, 'a'.repeat(64));
  return chunkId;
}

test.afterEach(() => usage.clearReservations());

test('unlimited install defaults leave both meters open', () => {
  const userId = insertUser();
  const snapshot = usage.getUsageSnapshot(userId);
  assert.equal(snapshot.ai.limits.fourHour, null);
  assert.equal(snapshot.ai.limits.weekly, null);
  assert.equal(snapshot.transcription.limits.fourHour, null);
  assert.equal(snapshot.ai.reached.any, false);
  usage.enforce(userId, 'ai');
});

test('a custom cap inherits nothing and 0 means unlimited', () => {
  const userId = insertUser();
  usage.setUserLimits(userId, { aiLimit4h: 50, aiLimitWeekly: 0 });
  insertAiRequest(userId, 40);
  const snapshot = usage.getUsageSnapshot(userId);
  assert.equal(snapshot.ai.limits.fourHour, 50);
  assert.equal(snapshot.ai.limits.weekly, null);
  assert.equal(snapshot.ai.limits.fourHourIsCustom, true);
  assert.equal(snapshot.ai.limits.weeklyIsCustom, true);
  assert.equal(snapshot.ai.usage.fourHour, 40);
  assert.equal(snapshot.ai.remaining.fourHour, 10);
  assert.equal(snapshot.ai.reached.any, false);
});

test('enforce throws once usage reaches the 4-hour window', () => {
  const userId = insertUser();
  usage.setUserLimits(userId, { aiLimit4h: 100 });
  insertAiRequest(userId, 100);
  assert.throws(() => usage.enforce(userId, 'ai'), (error) => {
    assert.equal(error.code, 'USAGE_LIMIT_EXCEEDED');
    assert.equal(error.status, 429);
    assert.equal(error.details.meter, 'ai');
    assert.equal(error.details.window, 'fourHour');
    assert.equal(error.details.usage.ai.reached.fourHour, true);
    assert.ok(error.retryAt);
    return true;
  });
});

test('reservations stop concurrent admits from sharing the last remaining budget', () => {
  const userId = insertUser();
  usage.setUserLimits(userId, { aiLimit4h: 20 });
  const first = usage.enforce(userId, 'ai', { reserve: 15 });
  assert.throws(() => usage.enforce(userId, 'ai', { reserve: 15 }), (error) => error.code === 'USAGE_LIMIT_EXCEEDED');
  first.releaseReservation();
  usage.enforce(userId, 'ai', { reserve: 15 }).releaseReservation();
});

test('nextDecreaseAt is when the oldest contributing row leaves the window', () => {
  const userId = insertUser();
  usage.setUserLimits(userId, { aiLimit4h: 10 });
  const created = new Date(Date.now() - 60 * 60_000).toISOString();
  insertAiRequest(userId, 10, created);
  const snapshot = usage.getUsageSnapshot(userId);
  const expected = new Date(Date.parse(created) + 4 * 60 * 60_000).toISOString();
  assert.equal(snapshot.ai.nextDecreaseAt.fourHour, expected);
});

test('transcription usage is seconds, unique per chunk, and silent of older rows', () => {
  const userId = insertUser();
  usage.setUserLimits(userId, { transcriptionLimit4h: 30 });
  const chunkId = insertChunk(userId);
  usage.recordTranscription(userId, chunkId, 25_000);
  usage.recordTranscription(userId, chunkId, 25_000);
  const snapshot = usage.getUsageSnapshot(userId);
  assert.equal(snapshot.transcription.usage.fourHour, 25);
  assert.equal(snapshot.transcription.remaining.fourHour, 5);
  assert.throws(
    () => usage.enforce(userId, 'transcription', { reserve: 10 }),
    (error) => error.details.meter === 'transcription',
  );
});

test('install defaults from app_settings override env zeros', () => {
  const userId = insertUser();
  usage.setInstallDefaults({ aiTokens4h: 5 });
  insertAiRequest(userId, 5);
  assert.throws(() => usage.enforce(userId, 'ai'), (error) => error.code === 'USAGE_LIMIT_EXCEEDED');
  usage.setInstallDefaults({ aiTokens4h: 0 });
  usage.enforce(userId, 'ai').releaseReservation();
});

test('null user overrides inherit the install default again', () => {
  const userId = insertUser();
  usage.setInstallDefaults({ transcriptionSeconds4h: 8 });
  usage.setUserLimits(userId, { transcriptionLimit4h: 100 });
  assert.equal(usage.getUsageSnapshot(userId).transcription.limits.fourHour, 100);
  usage.setUserLimits(userId, { transcriptionLimit4h: null });
  assert.equal(usage.getUsageSnapshot(userId).transcription.limits.fourHour, 8);
  usage.setInstallDefaults({ transcriptionSeconds4h: 0 });
});
