'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { randomToken, sha256 } = require('../../utils/crypto');

function createClient(userId, { name, redirectUris, scopes, confidential = true }) {
  const id = crypto.randomUUID(); const clientId = `nrc_${randomToken(16)}`; const clientSecret = confidential ? randomToken(32) : null;
  getDatabase().prepare(`INSERT INTO oauth_clients (id,user_id,name,client_id,client_secret_hash,redirect_uris_json,scopes_json)
    VALUES (?,?,?,?,?,?,?)`).run(id, userId, name, clientId, clientSecret ? sha256(clientSecret) : null, JSON.stringify(redirectUris), JSON.stringify(scopes));
  return { id, clientId, clientSecret, name, redirectUris, scopes };
}

function issueAuthorizationCode({ clientId, userId, redirectUri, scopes, codeChallenge = null, codeChallengeMethod = null, ttlMs = 300_000 }) {
  const code = randomToken(32);
  getDatabase().prepare(`INSERT INTO oauth_authorization_codes
    (id,client_id,user_id,code_hash,redirect_uri,scopes_json,code_challenge,code_challenge_method,expires_at)
    VALUES (?,?,?,?,?,?,?,?,?)`).run(crypto.randomUUID(), clientId, userId, sha256(code), redirectUri, JSON.stringify(scopes), codeChallenge, codeChallengeMethod, new Date(Date.now() + ttlMs).toISOString());
  return code;
}

function consumeAuthorizationCode(code) {
  const db = getDatabase();
  return db.transaction(() => {
    const row = db.prepare('SELECT * FROM oauth_authorization_codes WHERE code_hash=? AND consumed_at IS NULL AND expires_at>?').get(sha256(code), new Date().toISOString());
    if (!row) return null;
    db.prepare("UPDATE oauth_authorization_codes SET consumed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(row.id);
    return { ...row, scopes: JSON.parse(row.scopes_json) };
  })();
}

module.exports = { createClient, issueAuthorizationCode, consumeAuthorizationCode };
