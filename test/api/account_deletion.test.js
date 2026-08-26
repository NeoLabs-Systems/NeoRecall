'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-deletion-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const PASSWORD = 'a long and unique password';

async function accountWithData(username) {
  const registered = await request(app).post('/api/v1/auth/register').send({ username, password: PASSWORD }).expect(201);
  const userId = registered.body.user.id;
  const token = registered.body.session.token;
  const db = getDatabase();

  await request(app).put('/api/v1/settings').set('Authorization', `Bearer ${token}`)
    .send({ timezone: 'Europe/Berlin', customVocabulary: ['NeoRecall'] }).expect(200);

  const voiceprintId = crypto.randomUUID();
  db.prepare(`INSERT INTO voiceprints (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?)`).run(voiceprintId, userId, 'Grace Hopper', Buffer.alloc(16), 'test', 4, 1);
  db.prepare('INSERT INTO speaker_previews (voiceprint_id,user_id,audio,duration_ms,quality) VALUES (?,?,?,?,?)')
    .run(voiceprintId, userId, Buffer.from('audio'), 2000, 0.9);

  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const contextId = crypto.randomUUID();
  const contextPath = path.join(process.env.NEORECALL_HOME, `${contextId}.txt`);
  const contextBytes = Buffer.from('Private attached context');
  fs.writeFileSync(contextPath, contextBytes);
  db.prepare(`INSERT INTO devices (id,user_id,client_uuid,name,platform,kind)
    VALUES (?,?,?,?,?,'desktop')`).run(deviceId, userId, deviceId, 'Deletion test', 'test');
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?,'ended')`).run(sessionId, userId, deviceId, sessionId,
    '2026-08-26T08:00:00.000Z', '2026-08-26T08:00:00.000Z', 'UTC', '2026-08-26T07:59:59.000Z');
  db.prepare(`INSERT INTO recording_context_items
    (id,user_id,session_id,kind,captured_offset_ms,captured_at,original_name,content_type,byte_size,sha256,original_path,analysis_state)
    VALUES (?,?,?,'document',0,?,'private.txt','text/plain',?,?,?,'pending')`)
    .run(contextId, userId, sessionId, '2026-08-26T08:00:00.000Z', contextBytes.length,
      crypto.createHash('sha256').update(contextBytes).digest('hex'), contextPath);

  return { userId, token, voiceprintId, contextPath };
}

// Every table that holds something belonging to one account. If a future
// migration adds one and forgets the cascade, this list is where it shows up.
const OWNED_TABLES = [
  'user_settings', 'user_sessions', 'voiceprints', 'speaker_previews',
  'transcript_segments', 'conversations', 'memories', 'mini_memories',
  'entities', 'recording_sessions', 'audio_chunks', 'devices', 'jobs',
  'api_keys', 'user_two_factor', 'user_recovery_codes', 'search_documents',
  'diagnostic_request_events', 'processing_metrics',
  'recording_context_items',
];

test('deleting an account erases every row it owns', async () => {
  const { userId, token, contextPath } = await accountWithData('deletion-user');
  const db = getDatabase();

  const before = db.prepare('SELECT COUNT(*) c FROM user_settings WHERE user_id=?').get(userId).c;
  assert.ok(before > 0, 'the account really had data to erase');

  await request(app).delete('/api/v1/auth/account').set('Authorization', `Bearer ${token}`)
    .send({ password: PASSWORD }).expect(204);

  assert.equal(db.prepare('SELECT COUNT(*) c FROM users WHERE id=?').get(userId).c, 0);
  for (const table of OWNED_TABLES) {
    const remaining = db.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id=?`).get(userId).c;
    assert.equal(remaining, 0, `${table} still holds rows for the deleted account`);
  }
  assert.equal(fs.existsSync(contextPath), false, 'the attached context original still exists');
  // The session token must stop working immediately, not at its next expiry.
  await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${token}`).expect(401);
});

test('deletion requires the correct password and leaves the account intact otherwise', async () => {
  const { userId, token } = await accountWithData('careful-user');
  const db = getDatabase();

  await request(app).delete('/api/v1/auth/account').set('Authorization', `Bearer ${token}`)
    .send({ password: 'not the password' }).expect(401);

  assert.equal(db.prepare('SELECT COUNT(*) c FROM users WHERE id=?').get(userId).c, 1, 'a wrong password deletes nothing');
  assert.ok(db.prepare('SELECT COUNT(*) c FROM voiceprints WHERE user_id=?').get(userId).c > 0);
  await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${token}`).expect(200);
});

test('deleting one account does not touch another', async () => {
  const doomed = await accountWithData('doomed-user');
  const bystander = await accountWithData('bystander-user');
  const db = getDatabase();

  await request(app).delete('/api/v1/auth/account').set('Authorization', `Bearer ${doomed.token}`)
    .send({ password: PASSWORD }).expect(204);

  assert.equal(db.prepare('SELECT COUNT(*) c FROM users WHERE id=?').get(bystander.userId).c, 1);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM voiceprints WHERE user_id=?').get(bystander.userId).c > 0);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM speaker_previews WHERE user_id=?').get(bystander.userId).c > 0);
  await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${bystander.token}`).expect(200);
});

test('an API key cannot delete the account it can otherwise read', async () => {
  const { token } = await accountWithData('key-holder');
  const key = await request(app).post('/api/v1/api-keys').set('Authorization', `Bearer ${token}`)
    .send({ name: 'full access', scopes: ['*'] }).expect(201);
  // Deletion sits behind requireSession: a leaked long-lived key must not be
  // able to destroy the account it was issued for.
  await request(app).delete('/api/v1/auth/account').set('Authorization', `Bearer ${key.body.token}`)
    .send({ password: PASSWORD }).expect(403);
});
