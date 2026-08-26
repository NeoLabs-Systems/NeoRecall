'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-worker-interrupted-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_BASE_URL = 'http://127.0.0.1:1';
process.env.AI_API_MODEL = 'test/model';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const maintenance = require('../../server/workers/handlers/maintenance_handler');
const consolidation = require('../../server/services/memories/consolidation_service');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

function reservedRun(userId, reservedAt) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at)
    VALUES (?,?,?,?,10,1,'running',?)`).run(id, userId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z', reservedAt);
  return id;
}

test('a run orphaned by a crashed worker is reconciled, not left blocking forever', async () => {
  const db = getDatabase();
  // Two users: only one active run per user is allowed at a time (the whole
  // reason eligibility() can treat 'reserved'/'running' as exclusive), so the
  // crashed-vs-still-running comparison needs separate users, not two rows on one.
  const crashedUserId = crypto.randomUUID();
  const activeUserId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(crashedUserId, `u-${crashedUserId.slice(0, 8)}`, 'hash');
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(activeUserId, `u-${activeUserId.slice(0, 8)}`, 'hash');

  // What a crash leaves behind: state='running' with no completed_at, because
  // the process died between the state='running' write and either branch of
  // execute()'s try/catch. Without reconciliation, eligibility() would report
  // this user as having an active run forever.
  const old = reservedRun(crashedUserId, new Date(Date.now() - 45 * 60_000).toISOString());
  // A run that started a moment ago is still legitimately in flight and must
  // survive the sweep untouched.
  const fresh = reservedRun(activeUserId, new Date().toISOString());

  await maintenance.handle({ type: 'maintenance' });

  const oldRow = db.prepare('SELECT state,error_code,error_message,completed_at FROM consolidation_runs WHERE id=?').get(old);
  assert.equal(oldRow.state, 'failed');
  assert.equal(oldRow.error_code, 'WORKER_INTERRUPTED');
  assert.ok(oldRow.error_message, 'The reconciled row should explain itself without requiring a second incident to diagnose.');
  assert.ok(oldRow.completed_at);

  const freshRow = db.prepare('SELECT state FROM consolidation_runs WHERE id=?').get(fresh);
  assert.equal(freshRow.state, 'running');

  // Reconciliation must not be mistaken for a rejection of the input: it feeds
  // neither the narrowing nor the quarantine policy a real model failure does.
  assert.equal(consolidation.VALIDATION_FAILURE_CODES.includes('WORKER_INTERRUPTED'), false);

  // The crashed user is unblocked again — the whole point of the sweep — while
  // the genuinely active run still correctly blocks a second attempt.
  assert.notEqual(consolidation.eligibility(crashedUserId).reason, 'already_running');
  assert.equal(consolidation.eligibility(activeUserId).reason, 'already_running');
});
