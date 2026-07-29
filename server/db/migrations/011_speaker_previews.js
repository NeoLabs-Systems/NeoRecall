'use strict';

function up(db) {
  db.exec(`
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
  `);
}

module.exports = { up };
