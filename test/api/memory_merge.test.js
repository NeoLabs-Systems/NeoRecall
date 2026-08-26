'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-memory-merge-api-'));
process.env.NEORECALL_MEMORY_MERGE_MAX_ITEMS = '30';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const aiProviders = require('../../server/ai/provider_registry');

const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('manual merge accepts a large selection and preserves one combined card', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({
    username: 'large-memory-merge',
    password: 'a long and unique merge password',
  }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  const meta = await request(app).get('/api/v1/meta').set(auth).expect(200);
  assert.equal(meta.body.limits.memoryMergeMaxItems, 30);
  const db = getDatabase();
  const runId = crypto.randomUUID();
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at,started_at,completed_at)
    VALUES (?,?,'succeeded',?,?,?)`)
    .run(runId, userId, '2026-08-26T08:00:00.000Z', '2026-08-26T08:00:00.000Z', '2026-08-26T08:01:00.000Z');
  const insert = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,?,?,?,?,?,?,?,?)`);
  const ids = Array.from({ length: 26 }, (_, index) => {
    const publicId = crypto.randomUUID();
    const minute = String(index).padStart(2, '0');
    insert.run(publicId, userId, 'other', `Memory ${index + 1}`, `Summary ${index + 1}.`, '🧠', 5,
      `2026-08-26T09:${minute}:00.000Z`, `2026-08-26T09:${minute}:30.000Z`, runId);
    return publicId;
  });

  const originalReady = aiProviders.ready;
  aiProviders.ready = () => false;
  try {
    const response = await request(app).post('/api/v1/memories/merge').set(auth).send({ ids }).expect(200);
    assert.equal(response.body.absorbedIds.length, 25);
    assert.equal(db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 1);
    assert.match(response.body.memory.summary_en, /Summary 26\./);
  } finally {
    aiProviders.ready = originalReady;
  }

  const tooMany = Array.from({ length: 31 }, () => crypto.randomUUID());
  const rejected = await request(app).post('/api/v1/memories/merge').set(auth).send({ ids: tooMany }).expect(400);
  assert.equal(rejected.body.error.code, 'INVALID_MERGE');
  assert.equal(rejected.body.error.message, 'Merge at most 30 memories at once.');
});
