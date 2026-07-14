'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE oauth_clients_v2 (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      name TEXT NOT NULL,
      description TEXT,
      client_type TEXT NOT NULL CHECK (client_type IN ('public','confidential')),
      client_secret_hash TEXT,
      redirect_uris_json TEXT NOT NULL,
      scopes_json TEXT NOT NULL,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );
    INSERT INTO oauth_clients_v2 (
      id, owner_user_id, name, client_type, client_secret_hash,
      redirect_uris_json, scopes_json, revoked_at, created_at
    )
    SELECT client_id, user_id, name,
      CASE WHEN client_secret_hash IS NULL THEN 'public' ELSE 'confidential' END,
      client_secret_hash, redirect_uris_json, scopes_json, revoked_at, created_at
    FROM oauth_clients;

    CREATE TABLE oauth_authorization_codes_v2 (
      id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL REFERENCES oauth_clients_v2(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL UNIQUE,
      redirect_uri TEXT NOT NULL,
      scopes_json TEXT NOT NULL,
      code_challenge TEXT NOT NULL,
      code_challenge_method TEXT NOT NULL DEFAULT 'S256' CHECK (code_challenge_method = 'S256'),
      expires_at TEXT NOT NULL,
      consumed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    INSERT INTO oauth_authorization_codes_v2 (
      id, client_id, user_id, code_hash, redirect_uri, scopes_json,
      code_challenge, code_challenge_method, expires_at, consumed_at, created_at
    )
    SELECT id, client_id, user_id, code_hash, redirect_uri, scopes_json,
      COALESCE(code_challenge, ''), 'S256', expires_at, consumed_at, created_at
    FROM oauth_authorization_codes;

    CREATE TABLE oauth_access_tokens_v2 (
      id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL REFERENCES oauth_clients_v2(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );
    INSERT INTO oauth_access_tokens_v2 (
      id, client_id, user_id, token_hash, scopes_json, expires_at, revoked_at, created_at
    )
    SELECT id, client_id, user_id, token_hash, scopes_json, expires_at, revoked_at, created_at
    FROM oauth_access_tokens;

    CREATE TABLE oauth_refresh_tokens_v2 (
      id TEXT PRIMARY KEY,
      access_token_id TEXT REFERENCES oauth_access_tokens_v2(id) ON DELETE CASCADE,
      client_id TEXT NOT NULL REFERENCES oauth_clients_v2(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      replaced_by_token_id TEXT REFERENCES oauth_refresh_tokens_v2(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );
    INSERT INTO oauth_refresh_tokens_v2 (
      id, access_token_id, client_id, user_id, token_hash, scopes_json,
      expires_at, revoked_at, replaced_by_token_id, created_at
    )
    SELECT id, access_token_id, client_id, user_id, token_hash, scopes_json,
      expires_at, revoked_at, rotated_to_id, created_at
    FROM oauth_refresh_tokens;

    DROP TABLE oauth_refresh_tokens;
    DROP TABLE oauth_access_tokens;
    DROP TABLE oauth_authorization_codes;
    DROP TABLE oauth_clients;

    ALTER TABLE oauth_clients_v2 RENAME TO oauth_clients;
    ALTER TABLE oauth_authorization_codes_v2 RENAME TO oauth_authorization_codes;
    ALTER TABLE oauth_access_tokens_v2 RENAME TO oauth_access_tokens;
    ALTER TABLE oauth_refresh_tokens_v2 RENAME TO oauth_refresh_tokens;

    CREATE INDEX idx_oauth_clients_active ON oauth_clients(description, client_type, revoked_at);
    CREATE INDEX idx_oauth_codes_lookup ON oauth_authorization_codes(client_id, expires_at, consumed_at);
    CREATE INDEX idx_oauth_access_lookup ON oauth_access_tokens(token_hash, expires_at, revoked_at);
    CREATE INDEX idx_oauth_refresh_lookup ON oauth_refresh_tokens(token_hash, expires_at, revoked_at);
  `);
}

module.exports = { up };
