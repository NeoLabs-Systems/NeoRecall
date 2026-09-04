'use strict';

const { getConfig } = require('../../config');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('plaud.embedded');

const USER_TOKEN_SECONDS = 86_400;
const PARTNER_REFRESH_SKEW_MS = 60_000;
const USER_ID_MIN = 6;
const USER_ID_MAX = 120;

let partnerToken = null;
let partnerExpiresAt = 0;

function isConfigured(config = getConfig()) {
  return Boolean(config.plaudClientId && config.plaudClientSecret);
}

function apiRoot(config) {
  return `https://${config.plaudApiHost}/developer/api`;
}

function resetCache() {
  partnerToken = null;
  partnerExpiresAt = 0;
}

async function readJson(response) {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
  }
}

async function partnerAccessToken(config, fetchImpl) {
  if (partnerToken && Date.now() < partnerExpiresAt - PARTNER_REFRESH_SKEW_MS) {
    return partnerToken;
  }
  const credentials = Buffer.from(`${config.plaudClientId}:${config.plaudClientSecret}`).toString('base64');
  const response = await fetchImpl(`${apiRoot(config)}/oauth/partner/access-token`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${credentials}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body: 'grant_type=client_credentials',
  });
  const body = await readJson(response);
  if (!response.ok || !body.access_token) {
    const error = new Error(`Plaud partner token failed (${response.status}).`);
    error.status = response.status;
    throw error;
  }
  const expiresIn = Number(body.expires_in) || 3600;
  partnerToken = body.access_token;
  partnerExpiresAt = Date.now() + expiresIn * 1000;
  return partnerToken;
}

function embedUserId(userId) {
  const compact = String(userId).replace(/-/g, '');
  if (compact.length >= USER_ID_MIN && compact.length <= USER_ID_MAX) return compact;
  return String(userId).slice(0, USER_ID_MAX);
}

async function mintUserSession(userId, { fetchImpl = fetch, config = getConfig() } = {}) {
  if (!isConfigured(config)) return null;
  const partner = await partnerAccessToken(config, fetchImpl);
  const response = await fetchImpl(`${apiRoot(config)}/open/partner/users/access-token`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${partner}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ user_id: embedUserId(userId), expires_in: USER_TOKEN_SECONDS }),
  });
  const body = await readJson(response);
  if (!response.ok || !body.access_token) {
    logger.error('Failed to mint Plaud user token', { status: response.status });
    const error = new Error(`Plaud user token failed (${response.status}).`);
    error.status = response.status;
    throw error;
  }
  return {
    accessToken: body.access_token,
    expiresIn: Number(body.expires_in) || USER_TOKEN_SECONDS,
    customDomain: config.plaudApiHost,
    userId: embedUserId(userId),
  };
}

module.exports = { isConfigured, mintUserSession, resetCache };
