'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Database = require('better-sqlite3');
const migration = require('../../server/db/migrations/009_oauth_companion');

test('OAuth companion migration preserves existing scaffold credentials including nullable access links', () => {
  const db = new Database(':memory:');
  db.pragma('foreign_keys = ON');
  db.exec(`
    CREATE TABLE users (id TEXT PRIMARY KEY);
    INSERT INTO users (id) VALUES ('user-1');
    CREATE TABLE oauth_clients (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL,
      client_id TEXT NOT NULL UNIQUE, client_secret_hash TEXT, redirect_uris_json TEXT NOT NULL,
      scopes_json TEXT NOT NULL, revoked_at TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE oauth_authorization_codes (
      id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES oauth_clients(client_id),
      user_id TEXT NOT NULL REFERENCES users(id), code_hash TEXT NOT NULL UNIQUE,
      redirect_uri TEXT NOT NULL, scopes_json TEXT NOT NULL, code_challenge TEXT,
      code_challenge_method TEXT, expires_at TEXT NOT NULL, consumed_at TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE oauth_access_tokens (
      id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES oauth_clients(client_id),
      user_id TEXT NOT NULL REFERENCES users(id), token_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL, expires_at TEXT NOT NULL, revoked_at TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE oauth_refresh_tokens (
      id TEXT PRIMARY KEY, access_token_id TEXT REFERENCES oauth_access_tokens(id),
      client_id TEXT NOT NULL REFERENCES oauth_clients(client_id), user_id TEXT NOT NULL REFERENCES users(id),
      token_hash TEXT NOT NULL UNIQUE, scopes_json TEXT NOT NULL, expires_at TEXT NOT NULL,
      revoked_at TEXT, rotated_to_id TEXT REFERENCES oauth_refresh_tokens(id), created_at TEXT NOT NULL
    );
  `);
  const timestamp = '2026-07-14T12:00:00.000Z';
  db.prepare(`INSERT INTO oauth_clients
    (id,user_id,name,client_id,client_secret_hash,redirect_uris_json,scopes_json,created_at)
    VALUES (?,?,?,?,?,?,?,?)`).run('legacy-row', 'user-1', 'Legacy client', 'nrc_legacy', 'secret-hash',
      '["https://agent.example.test/api/integrations/oauth/callback"]', '["search:read"]', timestamp);
  db.prepare(`INSERT INTO oauth_access_tokens
    (id,client_id,user_id,token_hash,scopes_json,expires_at,created_at) VALUES (?,?,?,?,?,?,?)`)
    .run('access-1', 'nrc_legacy', 'user-1', 'access-hash', '["search:read"]', timestamp, timestamp);
  db.prepare(`INSERT INTO oauth_refresh_tokens
    (id,access_token_id,client_id,user_id,token_hash,scopes_json,expires_at,created_at)
    VALUES (?,?,?,?,?,?,?,?)`).run('refresh-1', null, 'nrc_legacy', 'user-1', 'refresh-hash',
      '["search:read"]', timestamp, timestamp);

  db.transaction(() => migration.up(db))();

  const client = db.prepare('SELECT * FROM oauth_clients WHERE id=?').get('nrc_legacy');
  assert.equal(client.owner_user_id, 'user-1');
  assert.equal(client.client_type, 'confidential');
  assert.equal(client.client_secret_hash, 'secret-hash');
  assert.equal(db.prepare('SELECT token_hash FROM oauth_access_tokens WHERE id=?').get('access-1').token_hash, 'access-hash');
  assert.equal(db.prepare('SELECT access_token_id FROM oauth_refresh_tokens WHERE id=?').get('refresh-1').access_token_id, null);
  db.close();
});
