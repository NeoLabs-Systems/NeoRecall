'use strict';

function up(db) {
  db.exec(`
    ALTER TABLE users ADD COLUMN ai_limit_4h INTEGER;
    ALTER TABLE users ADD COLUMN ai_limit_weekly INTEGER;
    ALTER TABLE users ADD COLUMN transcription_limit_4h INTEGER;
    ALTER TABLE users ADD COLUMN transcription_limit_weekly INTEGER;
    CREATE TABLE transcription_usage (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      chunk_id TEXT NOT NULL UNIQUE REFERENCES audio_chunks(id) ON DELETE CASCADE,
      duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_transcription_usage_user_time ON transcription_usage(user_id, created_at);
  `);
}

module.exports = { up };
