'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speakers-api-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('bulk deletion accepts the same text speaker ids as single-speaker routes', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({
    username: 'speaker-bulk-user',
    password: 'a long and unique password',
  }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  const database = getDatabase();
  const insert = database.prepare(`INSERT INTO voiceprints
    (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,'legacy-model',1,1)`);
  insert.run('legacy-speaker-a', userId, Buffer.alloc(4));
  insert.run('legacy-speaker-b', userId, Buffer.alloc(4));

  const response = await request(app).post('/api/v1/speakers/bulk').set(auth).send({
    ids: ['legacy-speaker-a', 'legacy-speaker-b'],
    action: 'delete',
  }).expect(200);

  assert.equal(response.body.count, 2);
  assert.equal(database.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(userId).count, 0);
});

test('saving a speaker name marks it as user-confirmed for transcription vocabulary', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({
    username: 'speaker-name-provenance-user',
    password: 'another long and unique password',
  }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  const database = getDatabase();
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,display_name,display_name_source,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,'inferred',?,'legacy-model',1,1)`)
    .run('inferred-speaker', userId, 'Model Guess', Buffer.alloc(4));

  assert.deepEqual(require('../../server/services/settings/settings_service').transcriptionVocabulary(userId), []);
  const response = await request(app).patch('/api/v1/speakers/inferred-speaker').set(auth)
    .send({ displayName: 'Confirmed Name' }).expect(200);

  assert.equal(response.body.display_name_source, 'manual');
  assert.deepEqual(require('../../server/services/settings/settings_service').transcriptionVocabulary(userId), ['Confirmed Name']);
});
