'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Database = require('better-sqlite3');
const migration = require('../../server/db/migrations/017_live_conversation_insights');
const { previewDue, previewOwns, PROVISIONAL, FINAL } = require('../../server/services/conversations/conversation_insight_service');

const limits = {
  minimumCharacters: 800, refreshCharacters: 1500, minimumIntervalMs: 300_000, fullCharacters: 20_000, enabled: true,
};
const now = Date.parse('2026-08-01T12:00:00.000Z');

function conversation(overrides = {}) {
  return {
    state: 'open', quarantined_at: null, insight_state: 'none', insight_characters: 0,
    insight_updated_at: null, insight_attempted_at: null, ...overrides,
  };
}

test('a conversation is previewed once it carries enough transcript to describe', () => {
  assert.equal(previewDue(conversation(), 799, limits, now), false);
  assert.equal(previewDue(conversation(), 800, limits, now), true);
});

test('a previewed conversation is only re-previewed after enough new speech and enough time', () => {
  const previewed = conversation({
    insight_state: PROVISIONAL,
    insight_characters: 5_000,
    insight_updated_at: '2026-08-01T11:57:00.000Z',
  });
  // Grew, but not enough to be worth re-describing.
  assert.equal(previewDue(previewed, 6_000, limits, now), false);
  // Grew enough, but the previous preview is three minutes old.
  assert.equal(previewDue(previewed, 6_500, limits, now), false);
  // Grew enough and the interval has elapsed.
  assert.equal(previewDue(previewed, 6_500, limits, Date.parse('2026-08-01T12:02:00.000Z')), true);
});

test('growth is measured from the previewed size, not from zero', () => {
  // Boundary detection can split an open conversation, leaving the continuation
  // shorter than the text its preview described; it clamps insight_characters
  // down so this comparison keeps measuring genuinely new speech either way.
  const split = conversation({
    insight_state: PROVISIONAL,
    insight_characters: 2_000,
    insight_updated_at: '2026-08-01T11:50:00.000Z',
  });
  assert.equal(previewDue(split, 2_400, limits, now), false);
  assert.equal(previewDue(split, 3_500, limits, now), true);
});

test('a final insight is never replaced by a provisional one', () => {
  const finalised = conversation({ insight_state: FINAL, insight_characters: 1_000, insight_updated_at: '2026-08-01T10:00:00.000Z' });
  assert.equal(previewDue(finalised, 100_000, limits, now), false);
});

test('a preview that keeps failing waits out the interval instead of retrying every tick', () => {
  // The attempt is stamped before the request, so a conversation whose previews
  // never succeed still has no insight but is not perpetually due. Without this
  // the scheduler would spend one request per tick on a broken model.
  const failing = conversation({ insight_state: 'none', insight_attempted_at: '2026-08-01T11:58:00.000Z' });
  assert.equal(previewDue(failing, 5_000, limits, now), false);
  assert.equal(previewDue(failing, 5_000, limits, Date.parse('2026-08-01T12:03:01.000Z')), true);
});

test('previews own conversations consolidation will not describe, and only those', () => {
  assert.equal(previewOwns(conversation({ state: 'open' })), true);
  // Closed and waiting for consolidation: the final pass is about to describe it.
  assert.equal(previewOwns(conversation({ state: 'closed' })), false);
  // Closed and quarantined: consolidation has permanently given up, so without a
  // preview this stays an unlabelled transcript in the timeline forever.
  assert.equal(previewOwns(conversation({ state: 'closed', quarantined_at: '2026-08-01T11:00:00.000Z' })), true);
  assert.equal(previewOwns(conversation({ state: 'consolidated' })), false);
  assert.equal(previewOwns(conversation({ state: 'not_memory_worthy' })), false);
});

function migratedDatabase() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE users (id TEXT PRIMARY KEY);
    CREATE TABLE ai_requests (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      purpose TEXT NOT NULL CHECK (purpose IN ('consolidation','ask')),
      provider TEXT NOT NULL,
      model TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('reserved','sent','succeeded','failed')),
      http_status INTEGER,
      provider_request_id TEXT,
      prompt_tokens INTEGER,
      completion_tokens INTEGER,
      cost_usd REAL,
      error_code TEXT,
      reserved_at TEXT NOT NULL,
      sent_at TEXT,
      completed_at TEXT
    );
    CREATE INDEX idx_ai_requests_user_purpose ON ai_requests(user_id, purpose, reserved_at DESC);
    CREATE TABLE consolidation_runs (
      id TEXT PRIMARY KEY,
      ai_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL
    );
    CREATE TABLE ask_quota_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ai_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL
    );
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      state TEXT NOT NULL,
      boundary_method TEXT NOT NULL,
      boundary_score REAL,
      boundary_version TEXT NOT NULL,
      title_en TEXT,
      summary_en TEXT,
      topics_json TEXT NOT NULL DEFAULT '[]',
      refined_at TEXT,
      refinement_run_id TEXT,
      origin_conversation_id TEXT,
      created_at TEXT,
      updated_at TEXT
    );
    CREATE TABLE transcript_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT,
      text TEXT NOT NULL
    );
    INSERT INTO users (id) VALUES ('user-1');
    INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at)
      VALUES ('request-1','user-1','consolidation','openai','test/model','succeeded','2026-07-13T10:00:00Z'),
             ('request-2','user-1','ask','openai','test/model','succeeded','2026-07-13T10:05:00Z');
    INSERT INTO consolidation_runs (id,ai_request_id) VALUES ('run-1','request-1');
    INSERT INTO ask_quota_events (ai_request_id) VALUES ('request-2');
    INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version,refined_at)
      VALUES ('refined','user-1','2026-07-13T10:00:00Z','2026-07-13T11:00:00Z','consolidated','legacy','3','2026-07-13T11:05:00Z'),
             ('worthless','user-1','2026-07-13T12:00:00Z','2026-07-13T12:30:00Z','not_memory_worthy','legacy','3','2026-07-13T12:35:00Z'),
             ('unrefined','user-1','2026-07-13T13:00:00Z','2026-07-13T13:30:00Z','closed','legacy','2',NULL);
    INSERT INTO transcript_segments (conversation_id,text) VALUES ('refined','twelve chars'),('refined','abc');
  `);
  return db;
}

/// Applies the migration the way the runner does for a rebuilding migration.
function applyLikeRunner(db) {
  db.pragma('foreign_keys = OFF');
  try {
    db.transaction(() => migration.up(db))();
  } finally {
    db.pragma('foreign_keys = ON');
  }
}

test('running the rebuild with enforcement on would sever the links the runner protects', () => {
  // This is the failure the rebuildsReferencedTable flag exists to prevent:
  // dropping a referenced table runs an implicit delete, which fires every
  // ON DELETE SET NULL pointing at it before the replacement is renamed in.
  const db = migratedDatabase();
  db.pragma('foreign_keys = ON');
  migration.up(db);
  assert.equal(db.prepare("SELECT ai_request_id FROM consolidation_runs WHERE id='run-1'").get().ai_request_id, null);
  db.close();
});

test('the rebuild widens the request purpose without dropping requests or their references', () => {
  const db = migratedDatabase();
  applyLikeRunner(db);

  assert.equal(db.prepare('SELECT COUNT(*) count FROM ai_requests').get().count, 2);
  assert.equal(db.prepare("SELECT ai_request_id FROM consolidation_runs WHERE id='run-1'").get().ai_request_id, 'request-1');
  assert.equal(db.prepare('SELECT ai_request_id FROM ask_quota_events').get().ai_request_id, 'request-2');
  assert.equal(db.pragma('foreign_key_check').length, 0);

  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at)
    VALUES ('request-3','user-1','conversation_preview','openai','test/model','sent','2026-07-13T10:10:00Z')`).run();
  assert.throws(() => db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at)
    VALUES ('request-4','user-1','something_else','openai','test/model','sent','2026-07-13T10:11:00Z')`).run(), /CHECK constraint/);
  db.close();
});

test('conversations that were already refined start out with a final insight', () => {
  const db = migratedDatabase();
  applyLikeRunner(db);

  const refined = db.prepare("SELECT insight_state,insight_characters,insight_updated_at,memory_worthy FROM conversations WHERE id='refined'").get();
  assert.equal(refined.insight_state, 'final');
  assert.equal(refined.insight_characters, 15);
  assert.equal(refined.insight_updated_at, '2026-07-13T11:05:00Z');
  assert.equal(refined.memory_worthy, 1);

  const worthless = db.prepare("SELECT insight_state,memory_worthy FROM conversations WHERE id='worthless'").get();
  assert.equal(worthless.insight_state, 'final');
  assert.equal(worthless.memory_worthy, 0);

  const unrefined = db.prepare("SELECT insight_state,insight_characters,memory_worthy,consolidation_failures,quarantined_at FROM conversations WHERE id='unrefined'").get();
  assert.deepEqual(unrefined, { insight_state: 'none', insight_characters: 0, memory_worthy: null, consolidation_failures: 0, quarantined_at: null });
  db.close();
});

test('the runner restores foreign key enforcement after a rebuilding migration', () => {
  assert.equal(migration.rebuildsReferencedTable, true);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-migrate-'));
  try {
    const db = new Database(path.join(home, 'test.sqlite'));
    require('sqlite-vec').load(db);
    db.pragma('foreign_keys = ON');
    require('../../server/db/migrate').migrate(db);
    assert.ok(db.prepare('SELECT 1 x FROM schema_migrations WHERE version=17').get());
    // Disabling enforcement is scoped to the rebuild, not left behind for the
    // rest of the process.
    assert.equal(db.pragma('foreign_keys', { simple: true }), 1);
    assert.equal(db.pragma('foreign_key_check').length, 0);
    db.close();
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
