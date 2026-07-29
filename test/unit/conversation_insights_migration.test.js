'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Database = require('better-sqlite3');
const migration = require('../../server/db/migrations/012_conversation_insights');

test('conversation insight migration backfills existing consolidated memories without another LLM call', () => {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE consolidation_runs (id TEXT PRIMARY KEY);
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      state TEXT NOT NULL,
      boundary_method TEXT NOT NULL,
      boundary_score REAL,
      boundary_version TEXT NOT NULL,
      created_at TEXT,
      updated_at TEXT
    );
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY,
      title_en TEXT NOT NULL,
      summary_en TEXT NOT NULL,
      importance REAL NOT NULL,
      started_at TEXT NOT NULL
    );
    CREATE TABLE memory_sources (
      memory_id INTEGER NOT NULL,
      conversation_id TEXT,
      segment_id INTEGER
    );
    CREATE TABLE memory_topics (
      memory_id INTEGER NOT NULL,
      topic TEXT NOT NULL
    );
    INSERT INTO conversations
      (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
      VALUES ('conversation-1','user-1','2026-07-13T10:00:00Z','2026-07-13T11:00:00Z','consolidated','legacy','1');
    INSERT INTO memories (id,title_en,summary_en,importance,started_at)
      VALUES (1,'Release planning','The team planned the release.',8,'2026-07-13T10:00:00Z');
    INSERT INTO memory_sources (memory_id,conversation_id) VALUES (1,'conversation-1');
    INSERT INTO memory_topics (memory_id,topic) VALUES (1,'Launch'),(1,'Planning');
  `);

  migration.up(db);

  const row = db.prepare('SELECT title_en,summary_en,topics_json FROM conversations WHERE id=?').get('conversation-1');
  assert.equal(row.title_en, 'Release planning');
  assert.equal(row.summary_en, 'The team planned the release.');
  assert.deepEqual(JSON.parse(row.topics_json), ['Launch', 'Planning']);
  db.close();
});
