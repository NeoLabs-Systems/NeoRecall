'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Database = require('better-sqlite3');
const migration = require('../../server/db/migrations/016_speaker_previews_duration');

const MIGRATIONS_DIR = path.join(__dirname, '../../server/db/migrations');

function schemaWithFiveSecondFloor(db) {
  db.exec(`
    CREATE TABLE users (id TEXT PRIMARY KEY);
    CREATE TABLE voiceprints (id TEXT PRIMARY KEY);
    CREATE TABLE speaker_previews (
      voiceprint_id TEXT PRIMARY KEY REFERENCES voiceprints(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      audio BLOB NOT NULL,
      content_type TEXT NOT NULL DEFAULT 'audio/wav',
      duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 5000 AND 10000),
      quality REAL NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_speaker_previews_user ON speaker_previews(user_id);
    INSERT INTO users (id) VALUES ('u1');
    INSERT INTO voiceprints (id) VALUES ('v1');
    INSERT INTO speaker_previews (voiceprint_id,user_id,audio,duration_ms,quality)
      VALUES ('v1','u1',x'00',6000,0.8);
  `);
}

test('every migration has its own version number', () => {
  // Applied migrations are keyed by version: a shared number records the first
  // file as that version and skips the second forever, without an error. That
  // is how the 5 s speaker-preview floor survived its own fix for weeks.
  const seen = new Map();
  for (const filename of fs.readdirSync(MIGRATIONS_DIR).filter((n) => /^\d{3}_.+\.js$/.test(n))) {
    const version = Number(filename.slice(0, 3));
    assert.equal(
      seen.has(version),
      false,
      `version ${version} used by both ${seen.get(version)} and ${filename}`,
    );
    seen.set(version, filename);
  }
});

test('the migration lowers the preview floor to 1 s and keeps existing rows', () => {
  const db = new Database(':memory:');
  schemaWithFiveSecondFloor(db);

  // Runs inside a transaction, exactly as db/migrate.js applies it — the file
  // must not open one of its own.
  db.transaction(() => migration.up(db))();

  assert.equal(db.prepare('SELECT COUNT(*) c FROM speaker_previews').get().c, 1);
  assert.equal(
    db.prepare('SELECT duration_ms FROM speaker_previews WHERE voiceprint_id=?').get('v1').duration_ms,
    6000,
  );

  // A 2 s preview is what config.js already permits and what the old CHECK
  // rejected with SQLITE_CONSTRAINT_CHECK on every short turn.
  db.prepare('INSERT INTO voiceprints (id) VALUES (?)').run('v2');
  db.prepare(
    'INSERT INTO speaker_previews (voiceprint_id,user_id,audio,duration_ms,quality) VALUES (?,?,?,?,?)',
  ).run('v2', 'u1', Buffer.from([0]), 2000, 0.5);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM speaker_previews').get().c, 2);

  // Below the configured minimum is still refused.
  db.prepare('INSERT INTO voiceprints (id) VALUES (?)').run('v3');
  assert.throws(() => {
    db.prepare(
      'INSERT INTO speaker_previews (voiceprint_id,user_id,audio,duration_ms,quality) VALUES (?,?,?,?,?)',
    ).run('v3', 'u1', Buffer.from([0]), 500, 0.5);
  }, /CHECK constraint failed/);

  // The lookup index survives the table rebuild.
  const indexes = db
    .prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='speaker_previews'")
    .all()
    .map((row) => row.name);
  assert.ok(indexes.includes('idx_speaker_previews_user'));
});
