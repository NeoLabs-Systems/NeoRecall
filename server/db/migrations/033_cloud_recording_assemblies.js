'use strict';

// One Nextcloud audio object per recording, not per ingest chunk.
//
// Chunks are still copied aside before the receipt unlinks them; this table
// holds that growing local assembly until the session closes and every chunk
// is terminal, at which point it becomes a single queued PUT.

function up(db) {
  db.exec(`
    CREATE TABLE cloud_recording_assemblies (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES recording_sources(id) ON DELETE CASCADE,
      local_dir TEXT NOT NULL,
      remote_path TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'assembling' CHECK (state IN ('assembling','dropped')),
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE UNIQUE INDEX idx_cloud_assemblies_active
      ON cloud_recording_assemblies(user_id, session_id, source_id)
      WHERE state='assembling';
    CREATE INDEX idx_cloud_assemblies_user ON cloud_recording_assemblies(user_id, state);
  `);
}

module.exports = { up };
