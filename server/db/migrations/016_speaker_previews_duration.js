'use strict';

// Relaxes the speaker-preview minimum from 5 s to 1 s, matching
// NEORECALL_SPEAKER_PREVIEW_MIN_MS (config.js), which allows 1 s. While the
// table still carried the 5 s floor, every preview shorter than that was
// rejected by the CHECK constraint and the capture failed.
//
// Originally numbered 012 — a number 012_conversation_insights.js already used.
// The runner keys applied migrations by version, so this file was recorded as
// "done" without ever executing and stayed dormant on every install.
function up(db) {
  db.exec(`
    CREATE TABLE speaker_previews_new (
      voiceprint_id TEXT PRIMARY KEY REFERENCES voiceprints(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      audio BLOB NOT NULL,
      content_type TEXT NOT NULL DEFAULT 'audio/wav',
      duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 1000 AND 10000),
      quality REAL NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

    INSERT INTO speaker_previews_new
      (voiceprint_id,user_id,audio,content_type,duration_ms,quality,created_at,updated_at)
      SELECT voiceprint_id,user_id,audio,content_type,duration_ms,quality,created_at,updated_at
        FROM speaker_previews;

    DROP TABLE speaker_previews;
    ALTER TABLE speaker_previews_new RENAME TO speaker_previews;
    CREATE INDEX IF NOT EXISTS idx_speaker_previews_user ON speaker_previews(user_id);
  `);
}

module.exports = { up };
