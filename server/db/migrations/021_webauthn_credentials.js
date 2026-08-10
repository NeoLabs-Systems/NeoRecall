'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE user_webauthn_credentials (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      credential_id TEXT NOT NULL UNIQUE,
      public_key TEXT NOT NULL,
      counter INTEGER NOT NULL DEFAULT 0,
      rp_id TEXT NOT NULL,
      transports TEXT NOT NULL DEFAULT '[]',
      device_type TEXT,
      backed_up INTEGER NOT NULL DEFAULT 0,
      label TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );
    CREATE INDEX idx_user_webauthn_credentials_user
      ON user_webauthn_credentials(user_id, rp_id, created_at DESC);

    CREATE TABLE webauthn_challenges (
      id TEXT PRIMARY KEY,
      purpose TEXT NOT NULL CHECK (purpose IN ('registration', 'authentication')),
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      challenge TEXT NOT NULL,
      rp_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_webauthn_challenges_expiry ON webauthn_challenges(expires_at);
  `);
}

module.exports = { up };
