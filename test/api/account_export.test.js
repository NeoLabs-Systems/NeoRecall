'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-export-api-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const accounts = require('../../server/services/cloud/cloud_account_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const PASSWORD = 'a long and unique password';

function zipEntry(buffer, name) {
  let offset = 0;
  while (offset + 30 <= buffer.length) {
    if (buffer.readUInt32LE(offset) !== 0x04034b50) break;
    const method = buffer.readUInt16LE(offset + 8);
    const compSize = buffer.readUInt32LE(offset + 18);
    const nameLen = buffer.readUInt16LE(offset + 26);
    const extra = buffer.readUInt16LE(offset + 28);
    const entryName = buffer.subarray(offset + 30, offset + 30 + nameLen).toString();
    const start = offset + 30 + nameLen + extra;
    const data = buffer.subarray(start, start + compSize);
    if (entryName === name) return method === 8 ? zlib.inflateRawSync(data) : data;
    offset = start + compSize;
  }
  throw new Error(`zip entry missing: ${name}`);
}

async function register(username) {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username, password: PASSWORD }).expect(201);
  return {
    userId: registered.body.user.id,
    token: registered.body.session.token,
    username,
  };
}

function seedOwnedRows(userId, { title, note, entityName, secretPhrase }) {
  const db = getDatabase();
  const conversationId = crypto.randomUUID();
  db.prepare(`INSERT INTO conversations
    (id,user_id,started_at,ended_at,state,boundary_method,boundary_version,title_en,summary_en,topics_json)
    VALUES (?,?,?,?, 'closed','silence','v1',?,?,'["export"]')`)
    .run(conversationId, userId, '2026-09-11T10:00:00.000Z', '2026-09-11T10:05:00.000Z', title, 'A private summary');
  const entityId = crypto.randomUUID();
  db.prepare(`INSERT INTO entities (id,user_id,kind,canonical_name_en,display_name,normalized_identity_key)
    VALUES (?,?, 'person',?,?,?)`).run(entityId, userId, entityName, entityName, entityName.toLowerCase());
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  db.prepare(`INSERT INTO devices (id,user_id,client_uuid,name,platform,kind)
    VALUES (?,?,?,?,?,'desktop')`).run(deviceId, userId, deviceId, 'Export phone', 'test');
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'ended')`).run(sessionId, userId, deviceId, sessionId,
    '2026-09-11T10:00:00.000Z', '2026-09-11T10:00:00.000Z', '2026-09-11T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_context_items
    (id,user_id,session_id,kind,captured_offset_ms,captured_at,note_text,analysis_state)
    VALUES (?,?,?, 'note',0,?,?,'ready')`).run(crypto.randomUUID(), userId, sessionId,
    '2026-09-11T10:01:00.000Z', note);
  const voiceprintId = crypto.randomUUID();
  db.prepare(`INSERT INTO voiceprints (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?)`).run(voiceprintId, userId, 'Named speaker', Buffer.from(secretPhrase), 'test', 4, 1);
}

test('a session can download a zip of only that account', async () => {
  const owner = await register('export-owner');
  const other = await register('export-other');
  seedOwnedRows(owner.userId, {
    title: 'Owner meeting',
    note: 'Owner private note',
    entityName: 'Ada Lovelace',
    secretPhrase: 'owner-embedding-bytes',
  });
  seedOwnedRows(other.userId, {
    title: 'Other meeting',
    note: 'Other private note',
    entityName: 'Hidden Person',
    secretPhrase: 'other-embedding-bytes',
  });
  accounts.upsertConnected(owner.userId, {
    baseUrl: 'https://cloud.example.test',
    username: 'ada',
    appPassword: 'hidden-app-password',
  });

  const response = await request(app).get('/api/v1/auth/account/export')
    .set('Authorization', `Bearer ${owner.token}`)
    .buffer(true)
    .parse((res, callback) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => callback(null, Buffer.concat(chunks)));
    })
    .expect(200);
  assert.match(response.headers['content-type'], /application\/zip/);
  assert.match(response.headers['content-disposition'], /neorecall-export-owner-/);
  const data = JSON.parse(zipEntry(response.body, 'data.json').toString());
  const dumped = JSON.stringify(data);
  assert.equal(data.account.username, 'export-owner');
  assert.equal(data.conversations[0].title_en, 'Owner meeting');
  assert.equal(data.context[0].note_text, 'Owner private note');
  assert.equal(data.entities[0].canonical_name_en, 'Ada Lovelace');
  assert.ok(!dumped.includes('export-other'));
  assert.ok(!dumped.includes('Other meeting'));
  assert.ok(!dumped.includes('Other private note'));
  assert.ok(!dumped.includes('Hidden Person'));
  assert.ok(!dumped.includes('hidden-app-password'));
  assert.ok(!dumped.includes('owner-embedding-bytes'));
  assert.ok(!dumped.includes('centroid_embedding'));
  assert.ok(!dumped.includes('password_hash'));
  accounts.disconnect(owner.userId);
});

test('an API key cannot download the account export', async () => {
  const { token } = await register('export-key-holder');
  const key = await request(app).post('/api/v1/api-keys').set('Authorization', `Bearer ${token}`)
    .send({ name: 'full access', scopes: ['*'] }).expect(201);
  await request(app).get('/api/v1/auth/account/export')
    .set('Authorization', `Bearer ${key.body.token}`)
    .expect(403);
});
