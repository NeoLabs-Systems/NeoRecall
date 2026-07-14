'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE ask_quota_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      ai_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL,
      attempted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_ask_quota_user_time ON ask_quota_events(user_id, attempted_at DESC);
    CREATE TABLE processing_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      job_id TEXT REFERENCES jobs(id) ON DELETE SET NULL,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      metric TEXT NOT NULL,
      value REAL NOT NULL,
      unit TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_processing_metrics_time ON processing_metrics(metric, created_at DESC);
  `);
}

module.exports = { up };
