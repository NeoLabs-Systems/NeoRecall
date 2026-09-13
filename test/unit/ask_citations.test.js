'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-ask-cite-'));
const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { getDatabase } = require('../../server/db/database');
const { citationHref } = require('../../server/services/search/ask_service');

test('Ask citation links use public ids and kind-correct paths', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(userId, 'cite-user', 'hash');
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at)
    VALUES ('run-cite',?,'succeeded','2026-08-02T09:00:00.000Z')`).run(userId);
  const memoryPublicId = crypto.randomUUID();
  const memory = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,'meeting','Cite me','Body.','📝',5,'2026-08-02T10:00:00.000Z','2026-08-02T10:30:00.000Z','run-cite')
    RETURNING id`).get(memoryPublicId, userId);
  const miniPublicId = crypto.randomUUID();
  const mini = db.prepare(`INSERT INTO mini_memories
    (public_id,user_id,memory_id,kind,text_en,importance,confidence)
    VALUES (?,?,?,'fact','A detail.',5,0.9) RETURNING id`).get(miniPublicId, userId, memory.id);

  assert.equal(citationHref(userId, 'memory', `memory:${memory.id}`), `/memories/${memoryPublicId}`);
  assert.equal(citationHref(userId, 'mini_memory', `mini_memory:${mini.id}`), `/memories/${memoryPublicId}`);
  assert.equal(citationHref(userId, 'daily_summary', 'daily_summary:2026-08-02'), '/daily-summaries/2026-08-02');
});
