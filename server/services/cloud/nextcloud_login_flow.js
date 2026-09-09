'use strict';

const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { normalizeInstanceUrl, sameOrigin, joinUrl } = require('./instance_url');

// Nextcloud Login Flow v2. The user opens a browser URL, signs in on their
// instance, and we poll until an app password is issued. No OAuth client
// registration is required on the Nextcloud side.

const pending = new Map();

function expired(entry, now = Date.now()) {
  return now - entry.startedAt > getConfig().cloudLoginTimeoutMs;
}

function getPending(userId) {
  const entry = pending.get(userId);
  if (!entry) return null;
  if (expired(entry)) {
    pending.delete(userId);
    return null;
  }
  return entry;
}

function cancel(userId) {
  pending.delete(userId);
}

async function start(userId, instanceUrl, { fetchImpl = fetch } = {}) {
  const baseUrl = normalizeInstanceUrl(instanceUrl);
  const url = joinUrl(baseUrl, 'index.php/login/v2');
  let response;
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: { 'User-Agent': 'NeoRecall', Accept: 'application/json' },
      redirect: 'manual',
      signal: AbortSignal.timeout(getConfig().cloudHttpTimeoutMs),
    });
  } catch {
    throw new HttpError(502, 'CLOUD_LOGIN_UNREACHABLE', 'Could not reach that Nextcloud instance.');
  }
  if (response.status < 200 || response.status >= 300) {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'That Nextcloud instance did not start a login.');
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'That Nextcloud instance did not start a login.');
  }
  const loginUrl = body?.login;
  const pollToken = body?.poll?.token;
  const pollEndpoint = body?.poll?.endpoint;
  if (!loginUrl || !pollToken || !pollEndpoint) {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'That Nextcloud instance did not start a login.');
  }
  if (!sameOrigin(baseUrl, pollEndpoint) || !sameOrigin(baseUrl, loginUrl)) {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'That Nextcloud instance returned an unexpected login URL.');
  }
  const entry = {
    baseUrl,
    loginUrl,
    pollToken,
    pollEndpoint,
    startedAt: Date.now(),
  };
  pending.set(userId, entry);
  return { status: 'connecting', loginUrl, baseUrl };
}

async function poll(userId, { fetchImpl = fetch } = {}) {
  const entry = getPending(userId);
  if (!entry) return null;
  let response;
  try {
    response = await fetchImpl(entry.pollEndpoint, {
      method: 'POST',
      headers: {
        'User-Agent': 'NeoRecall',
        Accept: 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ token: entry.pollToken }).toString(),
      redirect: 'manual',
      signal: AbortSignal.timeout(getConfig().cloudHttpTimeoutMs),
    });
  } catch {
    const wrapped = new Error('Could not reach that Nextcloud instance.');
    wrapped.code = 'CLOUD_LOGIN_UNREACHABLE';
    wrapped.retryable = true;
    throw wrapped;
  }
  if (response.status === 404) return { status: 'connecting', loginUrl: entry.loginUrl, baseUrl: entry.baseUrl };
  if (response.status < 200 || response.status >= 300) {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'Nextcloud login did not complete.');
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'Nextcloud login did not complete.');
  }
  const loginName = body?.loginName;
  const appPassword = body?.appPassword;
  if (!loginName || !appPassword) {
    throw new HttpError(502, 'CLOUD_LOGIN_FAILED', 'Nextcloud login did not complete.');
  }
  pending.delete(userId);
  return {
    status: 'connected',
    baseUrl: entry.baseUrl,
    username: String(loginName),
    appPassword: String(appPassword),
  };
}

function publicPending(userId) {
  const entry = getPending(userId);
  if (!entry) return null;
  return { status: 'connecting', loginUrl: entry.loginUrl, baseUrl: entry.baseUrl };
}

module.exports = { start, poll, cancel, getPending, publicPending };
