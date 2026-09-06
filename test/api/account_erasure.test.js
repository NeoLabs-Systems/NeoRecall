'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-erasure-'));
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


// Content erasure keeps the account. The distinction is the whole point of
// having two actions, so both halves are asserted: what goes, and what stays.
const CONTENT_TABLES = [
  'voiceprints', 'speaker_previews', 'recording_sessions', 'audio_chunks',
  'recording_context_items', 'search_documents',
];
const KEPT_TABLES = ['user_settings', 'user_sessions', 'devices'];

test('erasing content empties the library and keeps the account', async () => {
  const { userId, token, contextPath } = await accountWithData('erase-user');
  const db = getDatabase();

  const response = await request(app).post('/api/v1/auth/account/erase-content')
    .set('Authorization', `Bearer ${token}`).send({ password: PASSWORD }).expect(200);
  assert.equal(typeof response.body.files, 'number');

  for (const table of CONTENT_TABLES) {
    assert.equal(db.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id=?`).get(userId).c, 0,
      `${table} still holds content after an erase`);
  }
  assert.equal(fs.existsSync(contextPath), false, 'the attached context original still exists');

  // The account survives, and so does everything that is setup rather than data.
  assert.equal(db.prepare('SELECT COUNT(*) c FROM users WHERE id=?').get(userId).c, 1);
  for (const table of KEPT_TABLES) {
    assert.ok(db.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id=?`).get(userId).c > 0,
      `${table} was cleared, but erasing content must keep it`);
  }
  // Still signed in, and the settings that were chosen are still chosen.
  const me = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${token}`).expect(200);
  assert.equal(me.body.user.id, userId);
  const settings = await request(app).get('/api/v1/settings').set('Authorization', `Bearer ${token}`).expect(200);
  assert.equal(settings.body.settings.timezone, 'Europe/Berlin');
});

test('erasing content requires the correct password', async () => {
  const { userId, token } = await accountWithData('erase-careful-user');
  const db = getDatabase();
  await request(app).post('/api/v1/auth/account/erase-content')
    .set('Authorization', `Bearer ${token}`).send({ password: 'not the password' }).expect(401);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM voiceprints WHERE user_id=?').get(userId).c > 0,
    'a wrong password erases nothing');
});

test('erasing one account does not touch another', async () => {
  const erased = await accountWithData('erase-doomed');
  const bystander = await accountWithData('erase-bystander');
  const db = getDatabase();
  await request(app).post('/api/v1/auth/account/erase-content')
    .set('Authorization', `Bearer ${erased.token}`).send({ password: PASSWORD }).expect(200);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM voiceprints WHERE user_id=?').get(bystander.userId).c > 0);
  assert.ok(db.prepare('SELECT COUNT(*) c FROM recording_context_items WHERE user_id=?').get(bystander.userId).c > 0);
});

test('an API key cannot erase the content it can otherwise read', async () => {
  const { token } = await accountWithData('erase-key-holder');
  const key = await request(app).post('/api/v1/api-keys').set('Authorization', `Bearer ${token}`)
    .send({ name: 'full access', scopes: ['*'] }).expect(201);
  await request(app).post('/api/v1/auth/account/erase-content')
    .set('Authorization', `Bearer ${key.body.token}`).send({ password: PASSWORD }).expect(403);
});

