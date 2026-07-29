'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE diagnostic_request_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      request_id TEXT,
      method TEXT NOT NULL,
      path TEXT NOT NULL,
      status_code INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL,
      error_code TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_diagnostic_events_user_time
      ON diagnostic_request_events(user_id, created_at DESC, id DESC);
  `);
}

module.exports = { up };
