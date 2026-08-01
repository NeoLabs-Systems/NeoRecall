'use strict';

// Shared poll → download → importLocalFile loop for cloud recording sources.
//
// Platform adapters supply list/download; this module owns timers, idempotent
// import ids, failure isolation, and credential-error handling so each
// platform stays a thin API wrapper.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { ensureRuntimeDirs } = require('../../../../runtime/paths');
const imports = require('../../ingest/import_service');

const DEFAULT_POLL_MINUTES = 15;
const MIN_POLL_MINUTES = 5;
const MAX_AUDIO_BYTES = 512 * 1024 * 1024;

const activePollers = new Map();

function importIdFor(platform, userId, sourceId, externalId) {
  const digest = crypto
    .createHash('sha256')
    .update(`${platform}:${userId}:${sourceId}:${externalId}`)
    .digest('hex');
  return [
    digest.slice(0, 8),
    digest.slice(8, 12),
    `5${digest.slice(13, 16)}`,
    ((parseInt(digest.slice(16, 18), 16) & 0x3f) | 0x80).toString(16).padStart(2, '0') + digest.slice(18, 20),
    digest.slice(20, 32),
  ].join('-');
}

function normalizeTime(value) {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'number') {
    const millis = value > 1e12 ? value : value * 1000;
    return new Date(millis).toISOString();
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString();
}

function safeFilename(name, fallback) {
  const cleaned = String(name || fallback || 'recording')
    .replace(/[/\\?%*:|"<>]/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 120);
  return cleaned || fallback || 'recording';
}

async function downloadToFile(url, destination, { headers = {}, maxBytes = MAX_AUDIO_BYTES } = {}) {
  const response = await fetch(url, { headers });
  if (!response.ok) throw new Error(`Download failed with HTTP ${response.status}`);
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > maxBytes) throw new Error(`Recording exceeds the ${maxBytes} byte limit.`);
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > maxBytes) throw new Error(`Recording exceeds the ${maxBytes} byte limit.`);
  if (buffer.length === 0) throw new Error('Download returned no data.');
  fs.writeFileSync(destination, buffer, { mode: 0o600 });
  return buffer.length;
}

function alreadyImported(userId, importId) {
  try {
    const existing = imports.get(userId, importId);
    return ['assembled', 'processing', 'completed'].includes(existing.state);
  } catch (_) {
    return false;
  }
}

/// Runs one sweep for a source. Returns { available, imported }.
async function sweep(adapter, source, { updateConfig } = {}) {
  const items = await adapter.listRecordings(source, { updateConfig });
  let imported = 0;

  for (const item of items) {
    if (!item?.externalId) continue;
    const importId = importIdFor(adapter.id, source.user_id, source.id, item.externalId);
    if (alreadyImported(source.user_id, importId)) continue;

    let staged = null;
    try {
      const extension = item.extension || guessExtension(item.contentType);
      staged = path.join(ensureRuntimeDirs().importTmp, `${adapter.id}-${importId}.${extension}`);
      if (typeof item.download === 'function') {
        await item.download(staged, { updateConfig });
      } else if (item.downloadUrl) {
        await downloadToFile(item.downloadUrl, staged, {
          headers: item.downloadHeaders || {},
        });
      } else {
        console.warn(`[${adapter.id}] Recording ${item.externalId} has no download path; skipping.`);
        continue;
      }
      const title = safeFilename(item.title, `${adapter.label} recording`);
      await imports.importLocalFile(source.user_id, staged, {
        importId,
        originalName: `${title}.${extension}`,
        contentType: item.contentType || 'application/octet-stream',
        captureTime: normalizeTime(item.startedAt),
      });
      imported += 1;
    } catch (error) {
      console.error(`[${adapter.id}] Failed to import recording ${item.externalId}:`, error.message);
    } finally {
      if (staged) {
        try { fs.unlinkSync(staged); } catch (_) { /* best-effort */ }
      }
    }
  }

  const lastSyncAt = new Date().toISOString();
  if (typeof updateConfig === 'function') {
    const patch = {
      lastSyncAt,
      error: null,
      errorCode: null,
      erroredAt: null,
    };
    if (imported > 0) patch.lastImportAt = lastSyncAt;
    try {
      updateConfig(patch);
    } catch (_) { /* status write is best-effort */ }
  }

  return { available: items.length, imported };
}

function guessExtension(contentType) {
  if (!contentType) return 'bin';
  if (contentType.includes('mpeg') || contentType.includes('mp3')) return 'mp3';
  if (contentType.includes('mp4') || contentType.includes('m4a')) return 'mp4';
  if (contentType.includes('wav')) return 'wav';
  if (contentType.includes('webm')) return 'webm';
  return 'bin';
}

function recordAuthFailure(source, message) {
  try {
    require('../index').update(source.user_id, source.id, {
      enabled: false,
      config: {
        ...source.config,
        error: message,
        errorCode: 'auth_failed',
        erroredAt: new Date().toISOString(),
      },
    });
  } catch (error) {
    console.error(`[${source.type}] Could not record auth failure for ${source.id}:`, error.message);
  }
}

function createCloudSource(adapter) {
  if (!adapter?.id || typeof adapter.listRecordings !== 'function') {
    throw new Error('Cloud source adapter must expose id and listRecordings');
  }

  async function runSweep(source) {
    const updateConfig = (patch) => {
      require('../index').update(source.user_id, source.id, {
        config: { ...source.config, ...patch },
      });
      source.config = { ...source.config, ...patch };
    };

    try {
      const result = await sweep(adapter, source, { updateConfig });
      if (result.imported > 0) {
        console.log(`[${adapter.id}] Imported ${result.imported} recording(s) for source ${source.id}`);
      }
      return result;
    } catch (error) {
      console.error(`[${adapter.id}] Sweep failed for source ${source.id}:`, error.message);
      if (error.status === 401 || error.status === 403 || error.code === 'OAUTH_REFRESH_FAILED') {
        stopSource(source.id);
        recordAuthFailure(source, error.message || `${adapter.label} rejected the credentials. Reconnect the source.`);
      } else {
        try {
          updateConfig({
            error: error.message,
            errorCode: 'sync_failed',
            erroredAt: new Date().toISOString(),
          });
        } catch (_) { /* best-effort */ }
      }
      throw error;
    }
  }

  async function startSource(source) {
    stopSource(source.id);
    if (!source.enabled) return;
    if (!source.config?.accessToken && !source.config?.refreshToken) return;

    const minutes = Math.max(
      MIN_POLL_MINUTES,
      Number(source.config.pollMinutes) || DEFAULT_POLL_MINUTES,
    );
    // Hold the latest known row in the closure so unit tests (and the first
    // boot sweep before the registry is fully warm) still run. Interval ticks
    // prefer a fresh load so token refreshes from other paths are visible.
    let latest = source;
    const run = async () => {
      try {
        latest = require('../index').get(source.user_id, source.id);
      } catch (_) {
        // Keep using the last known row for this tick; if the source was
        // deleted, the next update/delete path will stop the poller.
      }
      if (!latest?.enabled) {
        stopSource(source.id);
        return;
      }
      try {
        await runSweep(latest);
      } catch (_) {
        /* logged inside runSweep */
      }
    };

    const timer = setInterval(run, minutes * 60_000);
    if (typeof timer.unref === 'function') timer.unref();
    activePollers.set(source.id, timer);
    console.log(`[${adapter.id}] Started source ${source.id} (polling every ${minutes} min)`);
    await run();
  }

  function stopSource(sourceId) {
    const timer = activePollers.get(sourceId);
    if (timer) {
      clearInterval(timer);
      activePollers.delete(sourceId);
      console.log(`[${adapter.id}] Stopped source ${sourceId}`);
    }
  }

  async function syncNow(source) {
    return runSweep(source);
  }

  async function verifyAccess(config) {
    if (typeof adapter.verifyAccess === 'function') {
      return adapter.verifyAccess(config);
    }
    if (!config?.accessToken && !config?.refreshToken) {
      throw new Error('Connect your account with OAuth before verifying.');
    }
    return { accountEmail: config.accountEmail || null };
  }

  return {
    adapter,
    verifyAccess,
    startSource,
    stopSource,
    syncNow,
    // exposed for tests
    _sweep: (source, opts) => sweep(adapter, source, opts),
    _activePollers: activePollers,
  };
}

module.exports = {
  createCloudSource,
  importIdFor,
  normalizeTime,
  downloadToFile,
  DEFAULT_POLL_MINUTES,
  MIN_POLL_MINUTES,
  MAX_AUDIO_BYTES,
};
