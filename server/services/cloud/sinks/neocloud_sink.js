'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { getConfig } = require('../../../config');
const { joinUrl } = require('../instance_url');

// Write-only NeoCloud client over its REST API, with a device token from the
// NeoCloud device login. Compared to plain WebDAV it gets three things for
// free from NeoCloud:
//   - every upload carries its SHA-256 and NeoCloud refuses damaged bytes;
//   - a retry after a lost answer finds the file it already sent instead of
//     storing a second copy (conflict=rename + declared SHA-256);
//   - large recordings go up in parts and continue where they stopped.
// Nothing here lists, downloads or deletes.

const SINGLE_PUT_MAX_BYTES = 8 * 1024 * 1024;

function sha256OfFile(file) {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    for (;;) {
      const read = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!read) break;
      hash.update(buffer.subarray(0, read));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

function readRange(file, start, length) {
  const fd = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const read = fs.readSync(fd, buffer, offset, length - offset, start + offset);
      if (!read) throw new Error('The pending copy ended early.');
      offset += read;
    }
    return buffer;
  } finally {
    fs.closeSync(fd);
  }
}

function splitRemote(folder, remotePath) {
  const parts = [folder, ...String(remotePath).split('/').filter(Boolean)];
  if (parts.some((part) => part === '.' || part === '..')) throw new Error('Invalid remote path.');
  return { dir: parts.slice(0, -1).join('/'), name: parts[parts.length - 1], full: parts.join('/') };
}

async function readBody(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

// Errors carry the same contract as the WebDAV sink: code, retryable, status.
// Messages are what the owner sees in Settings, so they say what happened,
// not which route answered.
async function failure(response, action) {
  const body = await readBody(response);
  const remoteCode = typeof body?.code === 'string' ? body.code : null;
  const status = response.status;
  let message = `NeoCloud ${action} failed (${status}).`;
  let code = 'CLOUD_PUT_FAILED';
  let retryable = status >= 500 || status === 429 || status === 408;
  if (status === 401 || status === 403) {
    code = 'CLOUD_AUTH_FAILED';
    retryable = false;
    message = 'NeoCloud no longer accepts NeoRecall. Reconnect NeoCloud in Settings.';
  } else if (status === 413 && remoteCode === 'QUOTA_EXCEEDED') {
    code = 'CLOUD_QUOTA_EXCEEDED';
    retryable = false;
    message = 'Your NeoCloud storage is full. Free up space there; new copies resume after that.';
  } else if (status === 413) {
    code = 'CLOUD_FILE_TOO_LARGE';
    retryable = false;
    message = 'This file is larger than your NeoCloud allows per file.';
  } else if (status === 507) {
    // Server disk or node limit: the admin can fix it, so later attempts may pass.
    code = 'CLOUD_SERVER_FULL';
    retryable = true;
    message = 'The NeoCloud server has no space left right now.';
  } else if (status === 422 && remoteCode === 'CHECKSUM_MISMATCH') {
    code = 'CLOUD_CHECKSUM_MISMATCH';
    retryable = true;
    message = 'The copy arrived damaged at NeoCloud and was refused; it will be sent again.';
  }
  const error = new Error(message);
  error.code = code;
  error.retryable = retryable;
  error.status = status;
  error.remoteCode = remoteCode;
  return error;
}

function createNeoCloudSink({ baseUrl, token, folder = 'NeoRecall', fetchImpl = fetch, timeoutMs } = {}) {
  const timeout = timeoutMs || getConfig().cloudHttpTimeoutMs;

  async function request(method, path, { json, body, headers } = {}) {
    return fetchImpl(joinUrl(baseUrl, path), {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        'User-Agent': 'NeoRecall',
        Accept: 'application/json',
        ...(json !== undefined ? { 'Content-Type': 'application/json' } : {}),
        ...(headers || {}),
      },
      ...(json !== undefined ? { body: JSON.stringify(json) } : {}),
      ...(body !== undefined ? { body } : {}),
      redirect: 'manual',
      signal: AbortSignal.timeout(timeout),
    });
  }

  async function me() {
    const response = await request('GET', 'api/devices/me');
    if (response.status !== 200) throw await failure(response, 'account check');
    const body = await readBody(response);
    const used = Number(body?.quota?.used);
    const limit = Number(body?.quota?.limit);
    return {
      username: typeof body?.user?.username === 'string' ? body.user.username : null,
      deviceId: typeof body?.device?.id === 'string' ? body.device.id : null,
      quota: {
        used: Number.isFinite(used) ? used : null,
        limit: Number.isFinite(limit) ? limit : null,
      },
    };
  }

  async function ensureFolder(dir) {
    const response = await request('POST', 'api/folders', { json: { parentId: 'root', path: dir } });
    if (response.status !== 200 && response.status !== 201) throw await failure(response, 'folder');
    const node = await readBody(response);
    if (!node?.id) throw Object.assign(new Error('NeoCloud did not return the backup folder.'), { retryable: true });
    return node.id;
  }

  function dateHeaders(capturedAt) {
    if (!capturedAt || Number.isNaN(Date.parse(capturedAt))) return {};
    const iso = new Date(capturedAt).toISOString();
    return { 'X-File-Created': iso, 'X-File-Modified': iso };
  }

  async function putSingle({ parentId, name, sha256, file, size, capturedAt }) {
    const query = new URLSearchParams({ parentId, name, conflict: 'rename' });
    const response = await request('PUT', `api/upload?${query}`, {
      body: readRange(file, 0, size),
      headers: { 'Content-Type': 'application/octet-stream', 'X-Content-SHA256': sha256, ...dateHeaders(capturedAt) },
    });
    if (response.status !== 200 && response.status !== 201) throw await failure(response, 'upload');
    return readBody(response);
  }

  async function existingSession(uploadId, { size, name }) {
    if (!uploadId) return null;
    const response = await request('GET', `api/uploads/${encodeURIComponent(uploadId)}`);
    if (response.status === 404) return null;
    if (response.status !== 200) throw await failure(response, 'upload');
    const session = await readBody(response);
    if (!session || session.size !== size || session.name !== name) return null;
    return session;
  }

  async function putResumable({ parentId, name, sha256, file, size, capturedAt, resumeUploadId, onUploadStarted }) {
    let session = await existingSession(resumeUploadId, { size, name });
    if (!session) {
      const dates = dateHeaders(capturedAt);
      const response = await request('POST', 'api/uploads', {
        json: {
          parentId, name, size, sha256, conflict: 'rename',
          ...(dates['X-File-Created'] ? { createdAt: dates['X-File-Created'], modifiedAt: dates['X-File-Modified'] } : {}),
        },
      });
      if (response.status !== 200 && response.status !== 201) throw await failure(response, 'upload');
      session = await readBody(response);
      if (!session?.id || !Number.isInteger(session.partSize) || session.partSize <= 0) {
        throw Object.assign(new Error('NeoCloud did not start the upload.'), { retryable: true });
      }
      if (onUploadStarted) onUploadStarted(session.id);
    }
    const partCount = Math.max(1, Math.ceil(size / session.partSize));
    const received = new Set(Array.isArray(session.receivedParts) ? session.receivedParts : []);
    for (let index = 0; index < partCount; index += 1) {
      if (received.has(index)) continue;
      const start = index * session.partSize;
      const length = Math.min(session.partSize, size - start);
      const response = await request('PUT', `api/uploads/${encodeURIComponent(session.id)}/parts/${index}`, {
        body: readRange(file, start, length),
        headers: { 'Content-Type': 'application/octet-stream' },
      });
      if (response.status !== 200 && response.status !== 201 && response.status !== 204) {
        const error = await failure(response, 'upload');
        // An expired session cannot be resumed; the next attempt starts over.
        if (response.status === 404 && onUploadStarted) onUploadStarted(null);
        if (response.status === 404) error.retryable = true;
        throw error;
      }
    }
    const done = await request('POST', `api/uploads/${encodeURIComponent(session.id)}/complete`, { json: {} });
    if (done.status !== 200 && done.status !== 201) {
      const error = await failure(done, 'upload');
      if (done.status === 404 && onUploadStarted) onUploadStarted(null);
      if (done.status === 404) error.retryable = true;
      throw error;
    }
    return readBody(done);
  }

  async function put(localPath, remotePath, { capturedAt = null, resumeUploadId = null, onUploadStarted = null } = {}) {
    if (require('../../../utils/sealed_fs').isSealed(localPath)) {
      throw new Error('Refusing to upload a sealed file to NeoCloud.');
    }
    const target = splitRemote(folder, remotePath);
    const size = fs.statSync(localPath).size;
    const sha256 = sha256OfFile(localPath);
    const parentId = await ensureFolder(target.dir);
    const args = { parentId, name: target.name, sha256, file: localPath, size, capturedAt, resumeUploadId, onUploadStarted };
    const node = size <= SINGLE_PUT_MAX_BYTES ? await putSingle(args) : await putResumable(args);
    return { remotePath: target.full, bytes: size, nodeId: node?.id || null };
  }

  return { put, me, name: 'neocloud' };
}

module.exports = { createNeoCloudSink, SINGLE_PUT_MAX_BYTES };
