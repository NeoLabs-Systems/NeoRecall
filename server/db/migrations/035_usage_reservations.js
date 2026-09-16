'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE usage_reservations (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      meter TEXT NOT NULL,
      amount INTEGER NOT NULL CHECK (amount > 0),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      expires_at TEXT NOT NULL
    );
    CREATE INDEX idx_usage_reservations_user_meter ON usage_reservations(user_id, meter, expires_at);
  `);
}

module.exports = { up };
