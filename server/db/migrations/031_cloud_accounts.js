'use strict';

// Per-user write-only cloud backup accounts (Nextcloud today).
//
// One row per NeoRecall user. The app password is stored encrypted; the drain
// queue holds local copies waiting to be PUT. Nothing here is a restore path.

function up(db) {
  db.exec(`
    CREATE TABLE cloud_accounts (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL CHECK (type IN ('nextcloud')),
      base_url TEXT NOT NULL,
      username TEXT NOT NULL,
      secret_encrypted TEXT NOT NULL,
      folder TEXT NOT NULL DEFAULT 'NeoRecall',
      audio_enabled INTEGER NOT NULL DEFAULT 0 CHECK (audio_enabled IN (0,1)),
      data_backup_enabled INTEGER NOT NULL DEFAULT 0 CHECK (data_backup_enabled IN (0,1)),
      status TEXT NOT NULL DEFAULT 'connected' CHECK (status IN ('connected','error')),
      last_error TEXT,
      last_audio_upload_at TEXT,
      last_data_backup_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE TABLE cloud_archive_items (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('audio','data')),
      local_path TEXT,
      remote_path TEXT NOT NULL,
      bytes INTEGER,
      sha256 TEXT,
      state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','uploading','uploaded','failed','dropped')),
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      uploaded_at TEXT
    );
    CREATE INDEX idx_cloud_archive_pending ON cloud_archive_items(user_id, state, created_at)
      WHERE state IN ('queued','uploading');
  `);
}

module.exports = { up };
