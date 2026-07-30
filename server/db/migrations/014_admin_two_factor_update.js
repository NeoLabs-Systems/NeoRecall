'use strict';

function up(db) {
  db.exec(`
    ALTER TABLE admin_two_factor ADD COLUMN pending INTEGER NOT NULL DEFAULT 1 CHECK (pending IN (0,1));
    ALTER TABLE admin_two_factor ADD COLUMN failed_attempts INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE admin_two_factor ADD COLUMN locked_until TEXT;

    CREATE TABLE admin_recovery_codes (
      id TEXT PRIMARY KEY,
      admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL,
      used_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(admin_id, code_hash)
    );
  `);
}

module.exports = { up };
