'use strict';

const fs = require('node:fs');
const { Readable } = require('node:stream');
const { getConfig } = require('../../../config');
const { joinUrl } = require('../instance_url');

// Write-only WebDAV: MKCOL + PUT. No GET, PROPFIND, or DELETE. Shared by
// audio copies and user-data dumps so neither path reimplements auth or
// directory creation.

function encodeSegment(segment) {
  return encodeURIComponent(String(segment)).replace(/'/g, '%27');
}

function davFileUrl(baseUrl, username, parts) {
  const encoded = ['remote.php', 'dav', 'files', encodeSegment(username), ...parts.map(encodeSegment)];
  return joinUrl(baseUrl, encoded.join('/'));
}

function prefixes(parts) {
  const out = [];
  for (let i = 1; i <= parts.length; i += 1) out.push(parts.slice(0, i));
  return out;
}

function authHeader(username, password) {
  return `Basic ${Buffer.from(`${username}:${password}`, 'utf8').toString('base64')}`;
}

function createWebDavSink({ baseUrl, username, password, folder = 'NeoRecall', fetchImpl = fetch, timeoutMs } = {}) {
  const timeout = timeoutMs || getConfig().cloudHttpTimeoutMs;
  const headers = {
    Authorization: authHeader(username, password),
    'User-Agent': 'NeoRecall',
  };

  async function request(method, url, { body, extraHeaders } = {}) {
    const response = await fetchImpl(url, {
      method,
      headers: { ...headers, ...(extraHeaders || {}) },
      body,
      ...(body ? { duplex: 'half' } : {}),
      redirect: 'manual',
      signal: AbortSignal.timeout(timeout),
    });
    return response;
  }

  async function mkcol(parts) {
    const url = davFileUrl(baseUrl, username, parts);
    const response = await request('MKCOL', url);
    if (response.status === 201 || response.status === 200) return;
    // Already exists is success: Nextcloud answers 405 or 409.
    if (response.status === 405 || response.status === 409 || response.status === 301) return;
    const text = await response.text().catch(() => '');
    const error = new Error(`Nextcloud MKCOL failed (${response.status}).`);
    error.code = response.status === 401 || response.status === 403 ? 'CLOUD_AUTH_FAILED' : 'CLOUD_MKCOL_FAILED';
    error.retryable = response.status !== 401 && response.status !== 403 && response.status >= 500;
    error.status = response.status;
    error.details = text.slice(0, 300);
    throw error;
  }

  async function ensureDirectories(relativeParts) {
    // The user's DAV root is assumed to exist; we create the NeoRecall folder
    // and every parent of the file we are about to PUT.
    for (const parts of prefixes(relativeParts.slice(0, -1))) {
      await mkcol(parts);
    }
  }

  async function put(localPath, remotePath) {
    // The bytes on the wire are the user's file as they would play or unzip
    // it. Sealing is a local-at-rest concern and must already have been
    // stripped by the caller.
    if (require('../../../utils/sealed_fs').isSealed(localPath)) {
      throw new Error('Refusing to upload a sealed file to Nextcloud.');
    }
    const relative = [folder, ...String(remotePath).split('/').filter(Boolean)];
    await ensureDirectories(relative);
    const url = davFileUrl(baseUrl, username, relative);
    const body = Readable.toWeb(fs.createReadStream(localPath));
    const response = await request('PUT', url, {
      body,
      extraHeaders: { 'Content-Type': 'application/octet-stream', Overwrite: 'T' },
    });
    if (response.status === 201 || response.status === 204 || response.status === 200) {
      return { remotePath: relative.join('/'), bytes: fs.statSync(localPath).size };
    }
    const text = await response.text().catch(() => '');
    const error = new Error(`Nextcloud PUT failed (${response.status}).`);
    error.code = response.status === 401 || response.status === 403 ? 'CLOUD_AUTH_FAILED' : 'CLOUD_PUT_FAILED';
    error.retryable = response.status !== 401 && response.status !== 403 && response.status !== 404 && response.status >= 500;
    error.status = response.status;
    error.details = text.slice(0, 300);
    throw error;
  }

  return { put, name: 'nextcloud' };
}

module.exports = { createWebDavSink, davFileUrl };
