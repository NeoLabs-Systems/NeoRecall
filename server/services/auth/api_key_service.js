'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { randomToken, sha256 } = require('../../utils/crypto');
const { HttpError } = require('../../middleware/error_handler');

const allowedScopes = new Set([
  'ingest:write', 'devices:read', 'devices:write', 'recordings:read', 'recordings:write',
  'memories:read', 'memories:write', 'speakers:read', 'speakers:write',
  'search:read', 'search:ask', 'settings:read', 'settings:write', '*',
]);

function normalizeScopes(scopes) {
  const result = [...new Set(scopes || [])];
  if (!result.length || result.some((scope) => !allowedScopes.has(scope))) throw new HttpError(400, 'INVALID_SCOPES', 'One or more API key scopes are invalid.');
  return result;
}

function create(userId, { name, scopes, expiresAt = null }) {
  const normalized = normalizeScopes(scopes);
  const secret = randomToken(32);
  const prefix = randomToken(6);
  const token = `nrk_${prefix}_${secret}`;
  const id = crypto.randomUUID();
  getDatabase().prepare(`INSERT INTO api_keys (id,user_id,name,key_prefix,key_hash,scopes_json,expires_at)
    VALUES (?,?,?,?,?,?,?)`).run(id, userId, String(name).trim(), prefix, sha256(token), JSON.stringify(normalized), expiresAt);
  return { id, name: String(name).trim(), scopes: normalized, expiresAt, token, prefix };
}

function list(userId) {
  return getDatabase().prepare(`SELECT id,name,key_prefix prefix,scopes_json,expires_at,revoked_at,created_at,last_used_at
    FROM api_keys WHERE user_id=? ORDER BY created_at DESC`).all(userId)
    .map((row) => ({ ...row, scopes: JSON.parse(row.scopes_json), scopes_json: undefined }));
}

function revoke(userId, id) {
  const result = getDatabase().prepare("UPDATE api_keys SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=? AND revoked_at IS NULL").run(id, userId);
  if (!result.changes) throw new HttpError(404, 'NOT_FOUND', 'API key not found.');
}

function authenticate(token) {
  if (!String(token || '').startsWith('nrk_')) return null;
  const row = getDatabase().prepare(`SELECT k.*,u.username,u.email,u.role,u.disabled_at,u.created_at
    FROM api_keys k JOIN users u ON u.id=k.user_id
    WHERE k.key_hash=? AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at > ?)`)
    .get(sha256(token), new Date().toISOString());
  if (!row || row.disabled_at) return null;
  getDatabase().prepare("UPDATE api_keys SET last_used_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(row.id);
  return {
    type: 'api_key', apiKeyId: row.id, userId: row.user_id, scopes: JSON.parse(row.scopes_json),
    user: { id: row.user_id, username: row.username, email: row.email, role: row.role, createdAt: row.created_at },
  };
}

module.exports = { create, list, revoke, authenticate, allowedScopes };
