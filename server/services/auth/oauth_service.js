'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { randomToken, sha256, encryptString, decryptString } = require('../../utils/crypto');
const { publicUser } = require('./auth_service');

const SCOPES = Object.freeze(['search:read', 'memories:read', 'recordings:read']);
const ACCESS_TTL_SECONDS = 60 * 60;
const REFRESH_TTL_SECONDS = 30 * 24 * 60 * 60;
const CODE_TTL_SECONDS = 10 * 60;

function statusError(message, statusCode = 400) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}

function parseJsonArray(value) {
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function parseScopes(value) {
  const requested = Array.isArray(value)
    ? value
    : String(value || '').trim().split(/\s+/);
  const scopes = [...new Set(requested.map((scope) => String(scope || '').trim()).filter(Boolean))];
  if (!scopes.length) return SCOPES.slice();
  if (scopes.some((scope) => !SCOPES.includes(scope))) throw statusError('Invalid OAuth scope.');
  return scopes;
}

function expiresAt(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

function activeClient(clientId) {
  const client = getDatabase().prepare('SELECT * FROM oauth_clients WHERE id=? AND revoked_at IS NULL')
    .get(String(clientId || '').trim());
  if (!client) throw statusError('OAuth client not found.', 404);
  return client;
}

function validateRedirectUri(client, redirectUri) {
  const value = String(redirectUri || '').trim();
  if (!value || !parseJsonArray(client.redirect_uris_json).includes(value)) throw statusError('Invalid redirect_uri.');
  return value;
}

function isPrivateOrLoopbackHost(hostname) {
  const value = String(hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
  return value === 'localhost' || value === '::1' || value.startsWith('127.') || value.startsWith('10.') ||
    value.startsWith('192.168.') || /^172\.(1[6-9]|2\d|3[01])\./.test(value);
}

function createCompanionClient({ redirectUri, appName }) {
  let parsed;
  try {
    parsed = new URL(String(redirectUri || '').trim());
  } catch {
    throw statusError('redirectUri must be a valid HTTP or HTTPS URL.');
  }
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.hash || parsed.search ||
      (parsed.protocol === 'http:' && !isPrivateOrLoopbackHost(parsed.hostname)) ||
      parsed.pathname !== '/api/integrations/oauth/callback') {
    throw statusError('redirectUri must be an HTTPS NeoAgent callback, or HTTP on a private/loopback address.');
  }
  if (appName && String(appName).trim() !== 'NeoAgent') throw statusError('Only the NeoAgent companion is supported.');
  const canonicalRedirect = parsed.toString();
  const existing = getDatabase().prepare(`SELECT * FROM oauth_clients
    WHERE description='companion:neoagent' AND client_type='public' AND revoked_at IS NULL`).all()
    .find((client) => parseJsonArray(client.redirect_uris_json).length === 1 &&
      parseJsonArray(client.redirect_uris_json)[0] === canonicalRedirect &&
      JSON.stringify(parseJsonArray(client.scopes_json)) === JSON.stringify(SCOPES));
  if (existing) return { client: existing, created: false };
  const id = `nrc_${randomToken(18)}`;
  getDatabase().prepare(`INSERT INTO oauth_clients
    (id,name,description,client_type,redirect_uris_json,scopes_json) VALUES (?,?,?,?,?,?)`)
    .run(id, 'NeoAgent', 'companion:neoagent', 'public', JSON.stringify([canonicalRedirect]), JSON.stringify(SCOPES));
  return { client: activeClient(id), created: true };
}

function validateAuthorizationRequest(params = {}) {
  if (String(params.response_type || '').trim() !== 'code') throw statusError('Unsupported response_type.');
  const client = activeClient(params.client_id);
  const redirectUri = validateRedirectUri(client, params.redirect_uri);
  const state = String(params.state || '').trim();
  const codeChallenge = String(params.code_challenge || '').trim();
  if (state.length < 16 || state.length > 512 || !/^[A-Za-z0-9._~-]+$/.test(state) ||
      !/^[A-Za-z0-9_-]{43}$/.test(codeChallenge) ||
      String(params.code_challenge_method || '').trim().toUpperCase() !== 'S256') {
    throw statusError('state and PKCE S256 are required.');
  }
  const scopes = parseScopes(params.scope);
  const allowed = parseJsonArray(client.scopes_json);
  if (scopes.some((scope) => !allowed.includes(scope))) throw statusError('Requested scope is not allowed.');
  return { client, redirectUri, state, codeChallenge, scopes };
}

function createBrowserGrant(userId) {
  return encryptString(JSON.stringify({ version: 1, userId, expiresAt: Date.now() + 15 * 60_000 }));
}

function authenticateBrowserGrant(value) {
  if (!value) return null;
  try {
    const grant = JSON.parse(decryptString(value));
    if (grant.version !== 1 || Date.now() >= Number(grant.expiresAt)) return null;
    const user = getDatabase().prepare('SELECT * FROM users WHERE id=? AND disabled_at IS NULL').get(String(grant.userId || ''));
    return user ? { userId: user.id, user: publicUser(user) } : null;
  } catch {
    return null;
  }
}

function createAuthorizationCode({ clientId, userId, redirectUri, scopes, codeChallenge }) {
  const code = `nroc_${randomToken(32)}`;
  getDatabase().prepare(`INSERT INTO oauth_authorization_codes
    (id,client_id,user_id,code_hash,redirect_uri,scopes_json,code_challenge,code_challenge_method,expires_at)
    VALUES (?,?,?,?,?,?,?,?,?)`).run(crypto.randomUUID(), clientId, userId, sha256(code), redirectUri,
      JSON.stringify(scopes), codeChallenge, 'S256', expiresAt(CODE_TTL_SECONDS));
  return code;
}

function verifyPkce(verifier, challenge) {
  return crypto.createHash('sha256').update(String(verifier || '')).digest('base64url') === challenge;
}

function issueTokenSet(database, { clientId, userId, scopes }) {
  const accessToken = `nro_${randomToken(32)}`;
  const refreshToken = `nrr_${randomToken(32)}`;
  const accessId = crypto.randomUUID();
  const refreshId = crypto.randomUUID();
  database.prepare(`INSERT INTO oauth_access_tokens
    (id,client_id,user_id,token_hash,scopes_json,expires_at) VALUES (?,?,?,?,?,?)`)
    .run(accessId, clientId, userId, sha256(accessToken), JSON.stringify(scopes), expiresAt(ACCESS_TTL_SECONDS));
  database.prepare(`INSERT INTO oauth_refresh_tokens
    (id,access_token_id,client_id,user_id,token_hash,scopes_json,expires_at) VALUES (?,?,?,?,?,?,?)`)
    .run(refreshId, accessId, clientId, userId, sha256(refreshToken), JSON.stringify(scopes), expiresAt(REFRESH_TTL_SECONDS));
  return { accessToken, refreshToken, expiresIn: ACCESS_TTL_SECONDS, scope: scopes.join(' '), refreshId };
}

function exchangeAuthorizationCode({ clientId, code, redirectUri, codeVerifier }) {
  const database = getDatabase();
  return database.transaction(() => {
    const client = activeClient(clientId);
    const normalizedRedirectUri = validateRedirectUri(client, redirectUri);
    const row = database.prepare(`SELECT * FROM oauth_authorization_codes
      WHERE code_hash=? AND client_id=? AND consumed_at IS NULL AND expires_at>?`)
      .get(sha256(String(code || '')), client.id, new Date().toISOString());
    if (!row || row.redirect_uri !== normalizedRedirectUri || !verifyPkce(codeVerifier, row.code_challenge)) {
      throw statusError('Invalid authorization code.');
    }
    const consumed = database.prepare(`UPDATE oauth_authorization_codes
      SET consumed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND consumed_at IS NULL`).run(row.id);
    if (consumed.changes !== 1) throw statusError('Invalid authorization code.');
    return issueTokenSet(database, { clientId: client.id, userId: row.user_id, scopes: parseJsonArray(row.scopes_json) });
  })();
}

function refreshTokenSet({ clientId, refreshToken }) {
  const database = getDatabase();
  return database.transaction(() => {
    const client = activeClient(clientId);
    const row = database.prepare(`SELECT * FROM oauth_refresh_tokens
      WHERE token_hash=? AND client_id=? AND revoked_at IS NULL AND expires_at>?`)
      .get(sha256(String(refreshToken || '')), client.id, new Date().toISOString());
    if (!row) throw statusError('Invalid refresh token.');
    const issued = issueTokenSet(database, { clientId: client.id, userId: row.user_id, scopes: parseJsonArray(row.scopes_json) });
    const revoked = database.prepare(`UPDATE oauth_refresh_tokens SET
      revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),last_used_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
      replaced_by_token_id=? WHERE id=? AND revoked_at IS NULL`).run(issued.refreshId, row.id);
    if (revoked.changes !== 1) throw statusError('Invalid refresh token.');
    database.prepare("UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
      .run(row.access_token_id);
    return issued;
  })();
}

function revokeToken({ clientId, token }) {
  const client = activeClient(clientId);
  const hash = sha256(String(token || ''));
  getDatabase().transaction(() => {
    const refresh = getDatabase().prepare('SELECT access_token_id FROM oauth_refresh_tokens WHERE client_id=? AND token_hash=?')
      .get(client.id, hash);
    getDatabase().prepare("UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND token_hash=? AND revoked_at IS NULL")
      .run(client.id, hash);
    getDatabase().prepare("UPDATE oauth_refresh_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND token_hash=? AND revoked_at IS NULL")
      .run(client.id, hash);
    if (refresh?.access_token_id) {
      getDatabase().prepare("UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND client_id=? AND revoked_at IS NULL")
        .run(refresh.access_token_id, client.id);
    }
  })();
}

function authenticateAccessToken(token) {
  if (!String(token || '').startsWith('nro_')) return null;
  const row = getDatabase().prepare(`SELECT t.*,u.username,u.email,u.role,u.disabled_at,u.created_at,c.name client_name
    FROM oauth_access_tokens t JOIN users u ON u.id=t.user_id JOIN oauth_clients c ON c.id=t.client_id
    WHERE t.token_hash=? AND t.revoked_at IS NULL AND t.expires_at>? AND c.revoked_at IS NULL`)
    .get(sha256(token), new Date().toISOString());
  if (!row || row.disabled_at) return null;
  getDatabase().prepare("UPDATE oauth_access_tokens SET last_used_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(row.id);
  return {
    type: 'oauth', oauthTokenId: row.id, clientId: row.client_id, clientName: row.client_name,
    userId: row.user_id, scopes: parseJsonArray(row.scopes_json),
    user: publicUser({ id: row.user_id, ...row }),
  };
}

module.exports = {
  SCOPES, createCompanionClient, validateAuthorizationRequest, createAuthorizationCode,
  createBrowserGrant, authenticateBrowserGrant,
  exchangeAuthorizationCode, refreshTokenSet, revokeToken, authenticateAccessToken,
};
