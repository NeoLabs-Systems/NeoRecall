'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const BACKOFF_BASE_MS = 500;
const BACKOFF_MAX_MS = 15_000;
// A missing or forbidden file will not appear by asking again.
const PERMANENT_STATUSES = new Set([400, 401, 403, 404, 410]);

class DownloadError extends Error {
  constructor(code, message, { permanent = false, cause } = {}) {
    super(message, { cause });
    this.code = code;
    this.permanent = permanent;
  }
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason); }, { once: true });
  });
}

async function sha256File(filename) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(filename)) hash.update(chunk);
  return hash.digest('hex');
}

async function matches(filename, { size, sha256 }) {
  try {
    return fs.statSync(filename).size === size && await sha256File(filename) === sha256;
  } catch {
    return false;
  }
}

// One attempt. Appends to `<destination>.partial`, asking the server to resume
// where an earlier attempt stopped. The idle timer covers the wait for headers
// as well as the body: a connection that opens and then says nothing is the
// failure a plain timeout on the whole request cannot tell from a slow download.
async function attempt({ url, partial, size, idleTimeoutMs, onProgress, fetchImpl }) {
  let offset = fs.existsSync(partial) ? fs.statSync(partial).size : 0;
  if (offset > size) { fs.rmSync(partial, { force: true }); offset = 0; }
  if (offset === size) return;
  const controller = new AbortController();
  let timer;
  const arm = () => {
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(new DownloadError('LOCAL_DOWNLOAD_STALLED', `No data received for ${idleTimeoutMs} ms.`)), idleTimeoutMs);
  };
  arm();
  try {
    const response = await fetchImpl(url, { headers: offset ? { Range: `bytes=${offset}-` } : {}, signal: controller.signal });
    if (response.status === 416) { fs.rmSync(partial, { force: true }); throw new DownloadError('LOCAL_DOWNLOAD_RESTART', 'The server rejected the resume point.'); }
    if (!response.ok) {
      throw new DownloadError('LOCAL_DOWNLOAD_HTTP', `Download failed with HTTP ${response.status}: ${url}`, { permanent: PERMANENT_STATUSES.has(response.status) });
    }
    // 200 to a ranged request means the server ignored the range and is sending
    // the whole file again; appending that to what we have would corrupt it.
    if (offset && response.status !== 206) { offset = 0; fs.rmSync(partial, { force: true }); }
    let received = offset;
    onProgress?.(received, size);
    const counting = async function* counting(source) {
      for await (const chunk of source) { arm(); received += chunk.length; onProgress?.(received, size); yield chunk; }
    };
    await pipeline(Readable.fromWeb(response.body), counting, fs.createWriteStream(partial, { flags: offset ? 'a' : 'w', mode: 0o600 }), { signal: controller.signal });
  } catch (error) {
    throw controller.signal.aborted && controller.signal.reason instanceof DownloadError ? controller.signal.reason : error;
  } finally {
    clearTimeout(timer);
  }
}

// Downloads `file` ({ url, size, sha256 }) to `destination` and returns only
// once the bytes on disk are exactly the pinned ones.
//
// A transfer interrupted by a stall, a dropped connection or a restart of this
// process resumes from the partial file, and a finished file that fails its hash
// is thrown away and fetched again from the start — a hash mismatch is the one
// failure that resuming would only repeat.
async function downloadVerified(file, destination, {
  attempts = 8, idleTimeoutMs = 30_000, onProgress, signal, fetchImpl = fetch,
} = {}) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  if (await matches(destination, file)) return { path: destination, cached: true };
  const partial = `${destination}.partial`;
  let lastError;
  for (let number = 1; number <= attempts; number += 1) {
    signal?.throwIfAborted();
    try {
      await attempt({ url: file.url, partial, size: file.size, idleTimeoutMs, onProgress, fetchImpl });
      if (fs.statSync(partial).size !== file.size) throw new DownloadError('LOCAL_DOWNLOAD_SIZE', `Downloaded size for ${path.basename(destination)} is incorrect.`);
      if (await sha256File(partial) !== file.sha256) {
        fs.rmSync(partial, { force: true });
        throw new DownloadError('LOCAL_CHECKSUM_MISMATCH', `SHA-256 verification failed for ${path.basename(destination)}.`);
      }
      fs.renameSync(partial, destination);
      return { path: destination, cached: false };
    } catch (error) {
      if (signal?.aborted) throw signal.reason;
      lastError = error;
      if (error.permanent || number === attempts) break;
      await sleep(Math.min(BACKOFF_BASE_MS * 2 ** (number - 1), BACKOFF_MAX_MS), signal);
    }
  }
  throw lastError instanceof DownloadError ? lastError
    : new DownloadError('LOCAL_DOWNLOAD_FAILED', `Could not download ${path.basename(destination)}: ${lastError?.cause?.message || lastError?.message}`, { cause: lastError });
}

module.exports = { downloadVerified, sha256File, matches, DownloadError };
