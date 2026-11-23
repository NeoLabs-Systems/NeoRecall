'use strict';

// NeoCloud as a second backup destination beside Nextcloud.
//
// cloud_accounts.type widens to 'neocloud' (a CHECK change, so the table is
// rebuilt) and gains the NeoCloud device id and the last quota NeoCloud
// reported. cloud_archive_items remembers a NeoCloud resumable upload so a
// long recording continues where it stopped, and when the audio was recorded
// so NeoCloud files it under that date.

function up(db) {
  db.exec(`
    CREATE TABLE cloud_accounts_new (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL CHECK (type IN ('nextcloud','neocloud')),
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
      remote_device_id TEXT,
      quota_used INTEGER,
      quota_limit INTEGER,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    INSERT INTO cloud_accounts_new
      (id,user_id,type,base_url,username,secret_encrypted,folder,audio_enabled,data_backup_enabled,
       status,last_error,last_audio_upload_at,last_data_backup_at,created_at,updated_at)
      SELECT id,user_id,type,base_url,username,secret_encrypted,folder,audio_enabled,data_backup_enabled,
       status,last_error,last_audio_upload_at,last_data_backup_at,created_at,updated_at
      FROM cloud_accounts;
    DROP TABLE cloud_accounts;
    ALTER TABLE cloud_accounts_new RENAME TO cloud_accounts;

    ALTER TABLE cloud_archive_items ADD COLUMN remote_upload_id TEXT;
    ALTER TABLE cloud_archive_items ADD COLUMN captured_at TEXT;
  `);
}

module.exports = { up, rebuildsReferencedTable: true };
