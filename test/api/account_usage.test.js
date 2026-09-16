'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-usage-api-'));
process.env.NEORECALL_AI_TOKENS_4H = '0';
process.env.NEORECALL_TRANSCRIPTION_SECONDS_4H = '0';

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const usage = require('../../server/services/usage/usage_limit_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const PASSWORD = 'a long and unique password';

async function register(username) {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username, password: PASSWORD }).expect(201);
  return { userId: registered.body.user.id, token: registered.body.session.token };
}

test('a session can read its own usage snapshot', async () => {
  const { token } = await register('usage-reader');
  const response = await request(app).get('/api/v1/auth/account/usage')
    .set('Authorization', `Bearer ${token}`).expect(200);
  assert.equal(response.body.ai.limits.fourHour, null);
  assert.equal(response.body.transcription.reached.any, false);
  assert.equal(response.body.ai.usage.fourHour, 0);
});

test('Ask is refused with USAGE_LIMIT_EXCEEDED when the AI meter is exhausted', async () => {
  const { userId, token } = await register('usage-asker');
  usage.setUserLimits(userId, { aiLimit4h: 10 });
  const db = getDatabase();
  const now = new Date().toISOString();
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,prompt_tokens,completion_tokens,reserved_at,completed_at)
    VALUES (?,?, 'ask','openai','test','succeeded',10,0,?,?)`).run(crypto.randomUUID(), userId, now, now);
  const response = await request(app).post('/api/v1/search/ask')
    .set('Authorization', `Bearer ${token}`)
    .send({ question: 'What happened today?' })
    .expect(429);
  assert.equal(response.body.error.code, 'USAGE_LIMIT_EXCEEDED');
  assert.equal(response.body.error.details.meter, 'ai');
  assert.equal(response.body.error.details.usage.ai.reached.fourHour, true);
});

test('erasing content drops transcription usage for that account', async () => {
  const { userId, token } = await register('usage-eraser');
  const db = getDatabase();
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
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono','2026-09-11T10:00:00.000Z',0,30000,'transcribed')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, 'a'.repeat(64));
  usage.recordTranscription(userId, chunkId, 30_000);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM transcription_usage WHERE user_id=?').get(userId).c > 0);
  await request(app).post('/api/v1/auth/account/erase-content')
    .set('Authorization', `Bearer ${token}`)
    .send({ password: PASSWORD })
    .expect(200);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM transcription_usage WHERE user_id=?').get(userId).c, 0);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM users WHERE id=?').get(userId).c, 1);
});
