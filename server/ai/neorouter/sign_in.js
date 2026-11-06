'use strict';

const crypto = require('node:crypto');
const os = require('node:os');
const { getConfig } = require('../../config');
const { createLogger } = require('../../utils/logger');
const connection = require('./connection');
const roles = require('./roles');

// "Connect NeoRouter": NeoRouter's device sign-in (OAuth 2.0 device flow, RFC
// 8628). The admin approves NeoRecall in NeoRouter, choosing what it may use,
// while this server polls for the key. No callback reaches NeoRecall, so it
// works the same for a NeoRouter on the home network as for a public one, and
// the key never passes through the app. NeoRouter needs no registration: an
// app names itself with client_id.
const CLIENT_ID = 'neorecall';
const SCOPES = 'chat transcription embedding';
const FORM = { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' };

const logger = createLogger('neorouter-sign-in');
// id -> { userId, apiBase, deviceCode, intervalMs, expiresAt, status, error }
const flows = new Map();

function pruneExpired(now = Date.now()) {
  for (const [id, flow] of flows) if (flow.expiresAt <= now && flow.status === 'pending') flows.delete(id);
}

async function postForm(url, fields) {
  const response = await fetch(url, {
    method: 'POST', headers: FORM, body: new URLSearchParams(fields).toString(),
    signal: AbortSignal.timeout(getConfig().neorouterRequestTimeoutMs),
  });
  return { ok: response.ok, data: await response.json().catch(() => null) };
}

function schedule(id, delayMs) {
  setTimeout(() => poll(id).catch((error) => logger.warn('Polling NeoRouter failed', { reason: error.message })), delayMs).unref?.();
}

async function poll(id) {
  const flow = flows.get(id);
  if (!flow || flow.status !== 'pending') return;
  if (Date.now() >= flow.expiresAt) {
    Object.assign(flow, { status: 'failed', error: 'The sign-in expired. Start again.' });
    return;
  }
  const { ok, data } = await postForm(`${new URL(flow.apiBase).origin}/oauth/token`, {
    grant_type: 'urn:ietf:params:oauth:grant-type:device_code', device_code: flow.deviceCode, client_id: CLIENT_ID,
  }).catch((error) => ({ ok: false, data: { error: 'network', error_description: error.message } }));
  if (ok && data?.access_token) {
    try {
      roles.applyConnection({ apiBase: flow.apiBase, apiKey: String(data.access_token) });
      flow.status = 'completed';
    } catch (error) {
      Object.assign(flow, { status: 'failed', error: error.message });
    }
    return;
  }
  const code = data?.error;
  if (code === 'slow_down') flow.intervalMs += 5000;
  if (code === 'authorization_pending' || code === 'slow_down' || code === 'network') {
    schedule(id, flow.intervalMs);
    return;
  }
  Object.assign(flow, {
    status: 'failed',
    error: code === 'access_denied' ? 'The connection was declined in NeoRouter.' : (data?.error_description || 'NeoRouter did not hand out a key.'),
  });
}

/** Starts connecting: the link that opens NeoRouter's approval page and the code it shows. */
async function begin({ userId, address }) {
  pruneExpired();
  const apiBase = connection.apiBaseFor(address);
  if (!apiBase) throw Object.assign(new Error('Enter the address of your NeoRouter, for example https://router.example.com.'), { code: 'NEOROUTER_BAD_ADDRESS' });
  const origin = new URL(apiBase).origin;
  let started;
  try {
    started = await postForm(`${origin}/oauth/device/code`, { client_id: CLIENT_ID, client_name: `NeoRecall (${os.hostname()})`, scope: SCOPES });
  } catch {
    throw Object.assign(new Error(`Could not reach NeoRouter at ${origin}.`), { code: 'NEOROUTER_UNREACHABLE' });
  }
  if (!started.ok || !started.data?.device_code) {
    throw Object.assign(new Error(`${origin} did not answer like a NeoRouter. Check the address.`), { code: 'NEOROUTER_NOT_A_ROUTER' });
  }
  const id = crypto.randomBytes(18).toString('hex');
  const intervalMs = Math.max(1, Number(started.data.interval) || 5) * 1000;
  flows.set(id, {
    userId, apiBase, deviceCode: String(started.data.device_code), intervalMs,
    expiresAt: Date.now() + Math.min(getConfig().neorouterSignInTtlMs, (Number(started.data.expires_in) || 600) * 1000),
    status: 'pending', error: null,
  });
  schedule(id, intervalMs);
  return { id, url: String(started.data.verification_uri_complete || started.data.verification_uri), userCode: String(started.data.user_code || '') };
}

// Only the admin who started it may read it; a finished result is handed out once.
function status(id, userId) {
  pruneExpired();
  const flow = flows.get(String(id || ''));
  if (!flow || flow.userId !== userId) return null;
  if (flow.status !== 'pending') flows.delete(String(id));
  return { status: flow.status, error: flow.error };
}

module.exports = { CLIENT_ID, SCOPES, begin, status };
