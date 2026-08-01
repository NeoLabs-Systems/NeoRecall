'use strict';

// Outbound OAuth client for platform integrations (Google / Zoom / Microsoft).
//
// NeoRecall is the OAuth *client* here — distinct from the NeoAgent companion
// authorization server under server/services/auth/oauth_service.js. Users
// authorize once in the provider's own UI; we keep access/refresh tokens on
// the source row and refresh them on demand.

const crypto = require('node:crypto');
const { encryptString, decryptString, randomToken } = require('../../../utils/crypto');
const { HttpError } = require('../../../middleware/error_handler');

const STATE_TTL_MS = 10 * 60_000;
// Refresh a minute before the provider's stated expiry so a sweep never starts
// with a token that dies mid-request.
const REFRESH_SKEW_MS = 60_000;

// One-time states: a replayed callback must not mint a second connection.
const spentStates = new Map();

function pruneSpent() {
  const now = Date.now();
  for (const [key, expiresAt] of spentStates) {
    if (expiresAt <= now) spentStates.delete(key);
  }
}

function issueState(payload) {
  pruneSpent();
  const body = {
    ...payload,
    nonce: randomToken(16),
    exp: Date.now() + STATE_TTL_MS,
  };
  return encryptString(JSON.stringify(body));
}

function consumeState(state) {
  if (!state || typeof state !== 'string') {
    throw new HttpError(400, 'OAUTH_STATE_INVALID', 'The sign-in session is missing or invalid. Start again from NeoRecall.');
  }
  let body;
  try {
    body = JSON.parse(decryptString(state));
  } catch (_) {
    throw new HttpError(400, 'OAUTH_STATE_INVALID', 'The sign-in session could not be verified. Start again from NeoRecall.');
  }
  if (!body || typeof body !== 'object' || !body.userId || !body.provider || !body.exp || !body.nonce) {
    throw new HttpError(400, 'OAUTH_STATE_INVALID', 'The sign-in session is malformed. Start again from NeoRecall.');
  }
  if (Date.now() > body.exp) {
    throw new HttpError(400, 'OAUTH_STATE_EXPIRED', 'The sign-in session expired. Start again from NeoRecall.');
  }
  pruneSpent();
  if (spentStates.has(body.nonce)) {
    throw new HttpError(400, 'OAUTH_STATE_REUSED', 'This sign-in link was already used. Start again from NeoRecall.');
  }
  spentStates.set(body.nonce, body.exp);
  return body;
}

function pkcePair() {
  const verifier = randomToken(32);
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

async function exchangeCode(provider, { code, redirectUri, codeVerifier }) {
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri,
    client_id: provider.clientId,
    client_secret: provider.clientSecret,
  });
  if (codeVerifier) body.set('code_verifier', codeVerifier);

  const response = await fetch(provider.tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body,
  });
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch (_) {
    json = null;
  }
  if (!response.ok) {
    const detail = (json && (json.error_description || json.error || json.message)) || text.slice(0, 200);
    const error = new HttpError(400, 'OAUTH_TOKEN_EXCHANGE_FAILED', `Could not finish sign-in with ${provider.label}: ${detail}`);
    throw error;
  }
  return normalizeTokenResponse(json);
}

async function refreshTokens(provider, refreshToken) {
  if (!refreshToken) {
    throw new HttpError(401, 'OAUTH_REFRESH_MISSING', `${provider.label} access has expired and no refresh token is stored. Reconnect the source.`);
  }
  const body = new URLSearchParams({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    client_id: provider.clientId,
    client_secret: provider.clientSecret,
  });
  const response = await fetch(provider.tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body,
  });
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch (_) {
    json = null;
  }
  if (!response.ok) {
    const detail = (json && (json.error_description || json.error || json.message)) || text.slice(0, 200);
    const error = new Error(`${provider.label} refused to refresh the access token: ${detail}`);
    error.status = response.status;
    error.code = 'OAUTH_REFRESH_FAILED';
    throw error;
  }
  return normalizeTokenResponse(json, refreshToken);
}

function normalizeTokenResponse(json, previousRefreshToken) {
  if (!json || !json.access_token) {
    throw new HttpError(400, 'OAUTH_TOKEN_INVALID', 'The provider returned no access token.');
  }
  const expiresIn = Number(json.expires_in);
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token || previousRefreshToken || null,
    expiresAt: Number.isFinite(expiresIn)
      ? new Date(Date.now() + expiresIn * 1000).toISOString()
      : null,
    tokenType: json.token_type || 'Bearer',
    scope: json.scope || null,
  };
}

function tokensFromConfig(config = {}) {
  return {
    accessToken: config.accessToken || null,
    refreshToken: config.refreshToken || null,
    expiresAt: config.expiresAt || null,
  };
}

function configFromTokens(tokens, extras = {}) {
  return {
    ...extras,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresAt: tokens.expiresAt,
    error: null,
    errorCode: null,
    erroredAt: null,
  };
}

function needsRefresh(tokens) {
  if (!tokens.accessToken) return true;
  if (!tokens.expiresAt) return false;
  const expiresAt = Date.parse(tokens.expiresAt);
  if (!Number.isFinite(expiresAt)) return false;
  return Date.now() >= expiresAt - REFRESH_SKEW_MS;
}

/// Ensures the source has a usable access token, refreshing when needed and
/// writing the new tokens back through the provided updater so the next sweep
/// does not re-refresh.
async function ensureAccessToken(provider, source, { updateConfig }) {
  let tokens = tokensFromConfig(source.config);
  if (!needsRefresh(tokens)) return tokens.accessToken;

  const refreshed = await refreshTokens(provider, tokens.refreshToken);
  // Keep a prior refresh token when the provider omits a new one.
  tokens = {
    accessToken: refreshed.accessToken,
    refreshToken: refreshed.refreshToken || tokens.refreshToken,
    expiresAt: refreshed.expiresAt,
  };
  if (typeof updateConfig === 'function') {
    await updateConfig(configFromTokens(tokens));
  }
  source.config = { ...source.config, ...configFromTokens(tokens) };
  return tokens.accessToken;
}

/// Authenticated fetch that refreshes once on 401.
async function authorizedFetch(provider, source, url, init = {}, { updateConfig } = {}) {
  const accessToken = await ensureAccessToken(provider, source, { updateConfig });
  const headers = {
    ...(init.headers || {}),
    Authorization: `Bearer ${accessToken}`,
    Accept: init.headers?.Accept || 'application/json',
  };
  let response = await fetch(url, { ...init, headers });
  if (response.status !== 401) return response;

  // Force a refresh and retry once.
  source.config = { ...source.config, expiresAt: new Date(0).toISOString() };
  const retryToken = await ensureAccessToken(provider, source, { updateConfig });
  response = await fetch(url, {
    ...init,
    headers: { ...headers, Authorization: `Bearer ${retryToken}` },
  });
  return response;
}

function buildAuthorizeUrl(provider, { redirectUri, state, codeChallenge }) {
  const url = new URL(provider.authorizationUrl);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', provider.clientId);
  url.searchParams.set('redirect_uri', redirectUri);
  url.searchParams.set('state', state);
  if (provider.scopes?.length) url.searchParams.set('scope', provider.scopes.join(' '));
  if (codeChallenge) {
    url.searchParams.set('code_challenge', codeChallenge);
    url.searchParams.set('code_challenge_method', 'S256');
  }
  if (provider.extraAuthorizeParams) {
    for (const [key, value] of Object.entries(provider.extraAuthorizeParams)) {
      url.searchParams.set(key, value);
    }
  }
  return url.toString();
}

module.exports = {
  STATE_TTL_MS,
  issueState,
  consumeState,
  pkcePair,
  exchangeCode,
  refreshTokens,
  tokensFromConfig,
  configFromTokens,
  needsRefresh,
  ensureAccessToken,
  authorizedFetch,
  buildAuthorizeUrl,
  // test helpers
  _spentStates: spentStates,
  _pruneSpent: pruneSpent,
};
