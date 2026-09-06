'use strict';

// Backup history. The artifacts themselves live at the configured destination;
// these rows are the record of what ran, so a failing schedule is visible
// without shell access to the host.
function up(db) {
  db.exec(`
    CREATE TABLE backups (
      id TEXT PRIMARY KEY,
      destination TEXT NOT NULL,
      artifact_key TEXT,
      bytes INTEGER,
      checksum TEXT,
      trigger_kind TEXT NOT NULL CHECK (trigger_kind IN ('scheduled','manual')),
      state TEXT NOT NULL CHECK (state IN ('running','succeeded','failed')),
      error_code TEXT,
      error_message TEXT,
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      completed_at TEXT,
      pruned_at TEXT
    );
    CREATE INDEX idx_backups_started ON backups(started_at DESC);
  `);
}

module.exports = { up };
