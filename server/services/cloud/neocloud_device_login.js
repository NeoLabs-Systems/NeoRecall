'use strict';

const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { normalizeInstanceUrl, sameOrigin, joinUrl } = require('./instance_url');

// NeoCloud device login: the same approval the NeoCloud desktop client uses.
// NeoRecall asks NeoCloud for a short code, the user opens NeoCloud's own
// approval page (signing in there with password, 2FA or passkey), and we poll
// until NeoCloud issues a device token. NeoRecall never sees the NeoCloud
// password, and the owner can revoke it under Settings › Devices in NeoCloud.

const DEVICE_NAME = 'NeoRecall';
// An empty platform is NeoCloud's "other client": it reaches files and
// uploads only — not account, settings, admin or WebDAV.
const DEVICE_PLATFORM = '';

const pending = new Map();

function unreachable() {
  return new HttpError(502, 'CLOUD_LOGIN_UNREACHABLE', 'Could not reach that NeoCloud server.');
}

function loginFailed(message = 'That NeoCloud server did not start a sign-in.') {
  return new HttpError(502, 'CLOUD_LOGIN_FAILED', message);
}

function expired(entry, now = Date.now()) {
  return now >= entry.expiresAt;
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

async function postJson(fetchImpl, url, body) {
  return fetchImpl(url, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'User-Agent': 'NeoRecall',
      Accept: 'application/json',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    redirect: 'manual',
    signal: AbortSignal.timeout(getConfig().cloudHttpTimeoutMs),
  });
}

async function readJson(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

// A plain "is this NeoCloud?" check, so a Nextcloud or random URL gets a clear
// answer instead of a confusing 404 from the device route.
async function assertNeoCloud(fetchImpl, baseUrl) {
  let response;
  try {
    response = await postJson(fetchImpl, joinUrl(baseUrl, 'api/version'));
  } catch {
    throw unreachable();
  }
  const body = response.status >= 200 && response.status < 300 ? await readJson(response) : null;
  if (body?.product !== 'neocloud') {
    throw new HttpError(400, 'NOT_NEOCLOUD', 'That address is not a NeoCloud server.');
  }
}

// NeoCloud answers with its own approval link. Only an http(s) link on the
// server we asked is shown; anything else is rebuilt from the code, the same
// rule the NeoCloud desktop client follows.
function approvalUrl(baseUrl, verificationUrl, userCode) {
  if (typeof verificationUrl === 'string' && sameOrigin(baseUrl, verificationUrl)) {
    try {
      const parsed = new URL(verificationUrl);
      if (parsed.protocol === 'https:' || parsed.protocol === 'http:') return parsed.toString();
    } catch {
      // Fall through to the rebuilt link.
    }
  }
  return `${joinUrl(baseUrl, 'app/device')}?code=${encodeURIComponent(userCode)}`;
}

async function start(userId, instanceUrl, { fetchImpl = fetch } = {}) {
  const baseUrl = normalizeInstanceUrl(instanceUrl, { label: 'NeoCloud' });
  await assertNeoCloud(fetchImpl, baseUrl);
  let response;
  try {
    response = await postJson(fetchImpl, joinUrl(baseUrl, 'api/devices/authorize'), {
      name: DEVICE_NAME,
      platform: DEVICE_PLATFORM,
    });
  } catch {
    throw unreachable();
  }
  if (response.status === 429) {
    throw new HttpError(429, 'CLOUD_LOGIN_RATE_LIMITED', 'NeoCloud asked to wait before starting another sign-in. Try again in a few minutes.');
  }
  if (response.status < 200 || response.status >= 300) throw loginFailed();
  const body = await readJson(response);
  const deviceCode = body?.deviceCode;
  const userCode = body?.userCode;
  if (typeof deviceCode !== 'string' || !deviceCode || typeof userCode !== 'string' || !userCode) {
    throw loginFailed();
  }
  const now = Date.now();
  const lifetimeMs = Math.min(
    Number.isFinite(body.expiresIn) && body.expiresIn > 0 ? body.expiresIn * 1000 : 600_000,
    getConfig().cloudLoginTimeoutMs,
  );
  const intervalMs = Math.max(1000, Math.min(Number.isFinite(body.interval) ? body.interval * 1000 : 3000, 30_000));
  const entry = {
    baseUrl,
    deviceCode,
    userCode,
    loginUrl: approvalUrl(baseUrl, body.verificationUrl, userCode),
    startedAt: now,
    expiresAt: now + lifetimeMs,
    intervalMs,
    lastPollAt: 0,
  };
  pending.set(userId, entry);
  return publicEntry(entry);
}

function publicEntry(entry) {
  return {
    status: 'connecting',
    type: 'neocloud',
    loginUrl: entry.loginUrl,
    userCode: entry.userCode,
    baseUrl: entry.baseUrl,
    expiresAt: new Date(entry.expiresAt).toISOString(),
  };
}

async function poll(userId, { fetchImpl = fetch, now = Date.now() } = {}) {
  const entry = getPending(userId);
  if (!entry) return null;
  // The app polls every couple of seconds; NeoCloud asks for its own pace and
  // rate-limits the token route, so extra ticks are answered locally.
  if (now - entry.lastPollAt < entry.intervalMs) return publicEntry(entry);
  entry.lastPollAt = now;
  let response;
  try {
    response = await postJson(fetchImpl, joinUrl(entry.baseUrl, 'api/devices/token'), {
      deviceCode: entry.deviceCode,
    });
  } catch {
    const wrapped = new Error('Could not reach that NeoCloud server.');
    wrapped.code = 'CLOUD_LOGIN_UNREACHABLE';
    wrapped.retryable = true;
    throw wrapped;
  }
  if (response.status === 428 || response.status === 429) return publicEntry(entry);
  if (response.status === 403) {
    pending.delete(userId);
    throw new HttpError(403, 'CLOUD_LOGIN_DENIED', 'The sign-in was declined in NeoCloud.');
  }
  if (response.status === 410) {
    pending.delete(userId);
    throw new HttpError(410, 'CLOUD_LOGIN_EXPIRED', 'The NeoCloud sign-in code expired. Start again.');
  }
  if (response.status < 200 || response.status >= 300) {
    throw loginFailed('NeoCloud sign-in did not complete.');
  }
  const body = await readJson(response);
  const token = body?.token;
  const username = body?.user?.username;
  if (typeof token !== 'string' || !token || typeof username !== 'string' || !username) {
    pending.delete(userId);
    throw loginFailed('NeoCloud sign-in did not complete.');
  }
  pending.delete(userId);
  return {
    status: 'connected',
    type: 'neocloud',
    baseUrl: entry.baseUrl,
    username,
    token,
    deviceId: typeof body.device?.id === 'string' ? body.device.id : null,
  };
}

function publicPending(userId) {
  const entry = getPending(userId);
  return entry ? publicEntry(entry) : null;
}

module.exports = { start, poll, cancel, getPending, publicPending, approvalUrl };
