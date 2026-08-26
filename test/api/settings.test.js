'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-settings-'));
process.env.NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS = '3600000';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('user settings validate timezones and preserve the environment interval floor', async () => {
  const registered = await request(app).post('/api/v1/auth/register').send({ username: 'settings-user', password: 'a long and unique password' }).expect(201);
  const auth = { Authorization: `Bearer ${registered.body.session.token}` };
  const initial = await request(app).get('/api/v1/settings').set(auth).expect(200);
  assert.equal(initial.body.settings.uploadOnlyOnUnmetered, true);
  assert.equal(initial.body.settings.recordingScheduleEnabled, false);
  const updated = await request(app).put('/api/v1/settings').set(auth).send({
    consolidationIntervalMs: 1000,
    timezone: 'Europe/Berlin',
    chunkTargetMs: 30000,
    chunkOverlapMs: 2000,
    uploadOnlyOnUnmetered: false,
    recordingScheduleEnabled: true,
    recordingStartMinute: 8 * 60,
    recordingEndMinute: 23 * 60,
    customVocabulary: ['NeoRecall', 'Qbii Technologies', 'neorecall'],
  }).expect(200);
  assert.equal(updated.body.settings.consolidationIntervalMs, 1000);
  assert.equal(updated.body.settings.effectiveConsolidationIntervalMs, 3600000);
  assert.equal(updated.body.settings.uploadOnlyOnUnmetered, false);
  assert.equal(updated.body.settings.recordingStartMinute, 480);
  assert.deepEqual(updated.body.settings.customVocabulary, ['NeoRecall', 'Qbii Technologies']);
  await request(app).put('/api/v1/settings').set(auth).send({ timezone: 'Not/A_Timezone' }).expect(400);
  await request(app).put('/api/v1/settings').set(auth).send({ recordingStartMinute: 1440 }).expect(400);
});

test('speaker names are automatically merged into transcription vocabulary per user', async () => {
  const registered = await request(app).post('/api/v1/auth/register').send({ username: 'vocabulary-user', password: 'another long unique password' }).expect(201);
  const userId = registered.body.user.id;
  await request(app).put('/api/v1/settings').set('Authorization', `Bearer ${registered.body.session.token}`)
    .send({ customVocabulary: ['NeoRecall', 'Ada Lovelace'] }).expect(200);
  const crypto = require('node:crypto');
  getDatabase().prepare(`INSERT INTO voiceprints
    (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?)`).run(crypto.randomUUID(), userId, 'Grace Hopper', Buffer.alloc(8), 'test', 2, 1);
  const vocabulary = require('../../server/services/settings/settings_service').transcriptionVocabulary(userId);
  assert.deepEqual(vocabulary, ['Grace Hopper', 'NeoRecall', 'Ada Lovelace']);
  const exposed = require('../../server/services/settings/settings_service').get(userId);
  assert.deepEqual(exposed.automaticSpeakerVocabulary, ['Grace Hopper']);
  assert.equal(exposed.vocabularyCorrectionEnabled, true);
});
