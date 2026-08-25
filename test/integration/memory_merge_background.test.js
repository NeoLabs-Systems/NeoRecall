'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-memory-merge-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const service = require('../../server/services/memories/memory_service');
const ai = require('../../server/ai/ai_engine');
const aiProviders = require('../../server/ai/provider_registry');
const handler = require('../../server/workers/handlers/memory_merge_handler');
migrate();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('memory merge returns after structural work and polishes prose in a worker', async () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const runId = crypto.randomUUID();
  const firstPublicId = crypto.randomUUID();
  const secondPublicId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)')
    .run(userId, 'background-merge', 'not-a-real-hash');
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at,started_at,completed_at)
    VALUES (?,?,'succeeded',?,?,?)`)
    .run(runId, userId, '2026-08-25T09:00:00.000Z', '2026-08-25T09:00:00.000Z', '2026-08-25T09:01:00.000Z');
  const insert = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,?,?,?,?,?,?,?,?)`);
  const first = Number(insert.run(firstPublicId, userId, 'meeting', 'Standup', 'Covered blockers.', '🤝', 5,
    '2026-08-25T10:00:00.000Z', '2026-08-25T10:15:00.000Z', runId).lastInsertRowid);
  const second = Number(insert.run(secondPublicId, userId, 'meeting', 'Planning', 'Agreed on launch timing.', '🚀', 7,
    '2026-08-25T11:00:00.000Z', '2026-08-25T11:30:00.000Z', runId).lastInsertRowid);
  db.prepare(`INSERT INTO mini_memories
    (public_id,user_id,memory_id,kind,text_en,importance,confidence,status)
    VALUES (?,?,?,'task','Send the launch plan.',7,0.9,'open')`)
    .run(crypto.randomUUID(), userId, second);

  const originalReady = aiProviders.ready;
  const originalRewrite = ai.rewriteMergedMemory;
  let rewriteCalls = 0;
  aiProviders.ready = () => true;
  ai.rewriteMergedMemory = async () => {
    rewriteCalls += 1;
    return {
      requestId: 'rewrite-request',
      value: {
        type: 'project_discussion',
        titleEn: 'Launch coordination',
        summaryEn: 'The team reviewed blockers and agreed on launch timing.',
        emoji: '🚀',
      },
    };
  };
  try {
    const result = service.merge(userId, { ids: [firstPublicId, secondPublicId] });
    assert.equal(rewriteCalls, 0, 'the request path does not wait for the language model');
    assert.equal(result.rewriteQueued, true);
    assert.equal(db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 1);
    assert.equal(db.prepare('SELECT memory_id FROM mini_memories WHERE user_id=?').get(userId).memory_id, first,
      'highlights move to the surviving memory before the request returns');

    const job = db.prepare("SELECT * FROM jobs WHERE type='rewrite_merged_memory'").get();
    assert.ok(job);
    await handler.handle({ ...job, payload: JSON.parse(job.payload_json) });
    assert.equal(rewriteCalls, 1);
    assert.deepEqual(db.prepare('SELECT type,title_en,summary_en FROM memories WHERE id=?').get(first), {
      type: 'project_discussion',
      title_en: 'Launch coordination',
      summary_en: 'The team reviewed blockers and agreed on launch timing.',
    });
  } finally {
    aiProviders.ready = originalReady;
    ai.rewriteMergedMemory = originalRewrite;
  }
});
