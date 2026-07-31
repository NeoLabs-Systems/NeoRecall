'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const imports = require('../ingest/import_service');

/// PLAUD cloud source.
///
/// PLAUD wearables (NotePin, Note, Note Pro) sync their recordings to PLAUD's
/// own cloud over the vendor app — their BLE protocol is closed on current
/// firmware, so there is no local path to the device. This source therefore
/// pulls the user's finished recordings from PLAUD's documented developer API
/// and hands each one to the ordinary durable import pipeline, so a PLAUD
/// recording is transcribed exactly like a manual upload.
///
/// API (from PLAUD's published developer client):
///   GET {base}/open/third-party/users/current
///   GET {base}/open/third-party/files/?page=N&page_size=M
///   GET {base}/open/third-party/files/{fileId}   -> includes a short-lived audio URL
/// Authenticated with `Authorization: Bearer <accessToken>`.
const DEFAULT_API_BASE = 'https://platform.plaud.ai/developer/api';
const DEFAULT_POLL_MINUTES = 15;
const MIN_POLL_MINUTES = 5;
const PAGE_SIZE = 50;
// Downloads are capped so a runaway/oversized response cannot fill the disk.
const MAX_AUDIO_BYTES = 512 * 1024 * 1024;

// One poll timer per source id.
const activePollers = new Map();

/// Deterministic import id for a PLAUD recording.
///
/// Re-polling must not re-import: the import pipeline is idempotent per import
/// id, so deriving the id from (user, source, PLAUD file id) makes a repeated
/// sweep resolve to the existing import instead of creating a duplicate. No
/// separate "already seen" bookkeeping is needed.
function importIdFor(userId, sourceId, fileId) {
  const digest = crypto
    .createHash('sha256')
    .update(`plaud:${userId}:${sourceId}:${fileId}`)
    .digest('hex');
  // Shape the digest into a v5-style UUID so it satisfies the imports schema.
  return [
    digest.slice(0, 8),
    digest.slice(8, 12),
    `5${digest.slice(13, 16)}`,
    ((parseInt(digest.slice(16, 18), 16) & 0x3f) | 0x80).toString(16).padStart(2, '0') + digest.slice(18, 20),
    digest.slice(20, 32),
  ].join('-');
}

function apiBase(config) {
  return (config.apiBase || DEFAULT_API_BASE).replace(/\/+$/, '');
}

async function apiRequest(config, requestPath) {
  const response = await fetch(`${apiBase(config)}${requestPath}`, {
    headers: {
      Authorization: `Bearer ${config.accessToken}`,
      Accept: 'application/json',
    },
  });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = new Error(`PLAUD API ${response.status}: ${body.slice(0, 200)}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

/// Verifies the token before a source is stored, so a typo surfaces in the setup
/// dialog rather than as a silent background failure hours later.
async function verifyAccess(config) {
  const user = await apiRequest(config, '/open/third-party/users/current');
  return user;
}

function pickAudioUrl(detail) {
  // The published client documents a temporary audio URL on the file detail; the
  // exact field name is not contractual, so accept the documented shape and the
  // obvious variants rather than failing on a rename.
  const candidates = [
    detail?.url,
    detail?.audio_url,
    detail?.download_url,
    detail?.data?.url,
    detail?.data?.audio_url,
    detail?.data?.download_url,
  ];
  return candidates.find((value) => typeof value === 'string' && value.startsWith('http')) || null;
}

function fileList(payload) {
  const data = payload?.data ?? payload;
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.items)) return data.items;
  if (Array.isArray(data?.list)) return data.list;
  return [];
}

function fileId(item) {
  return item?.id ?? item?.file_id ?? item?.fileId ?? null;
}

async function downloadTo(url, destination) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Audio download failed with ${response.status}`);
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > MAX_AUDIO_BYTES) throw new Error(`Recording exceeds the ${MAX_AUDIO_BYTES} byte limit.`);
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > MAX_AUDIO_BYTES) throw new Error(`Recording exceeds the ${MAX_AUDIO_BYTES} byte limit.`);
  if (buffer.length === 0) throw new Error('Audio download returned no data.');
  fs.writeFileSync(destination, buffer, { mode: 0o600 });
  return buffer.length;
}

/// Pulls every recording on the first page(s) and imports the ones not yet seen.
async function sweep(source) {
  const { config } = source;
  const listing = await apiRequest(config, `/open/third-party/files/?page=1&page_size=${PAGE_SIZE}`);
  const items = fileList(listing);
  let imported = 0;

  for (const item of items) {
    const id = fileId(item);
    if (!id) continue;
    const importId = importIdFor(source.user_id, source.id, id);
    // Skip work for a recording a previous sweep already pulled.
    try {
      const existing = imports.get(source.user_id, importId);
      if (['assembled', 'processing', 'completed'].includes(existing.state)) continue;
    } catch (_) {
      // Not imported yet — fall through and pull it.
    }

    let staged = null;
    try {
      const detail = await apiRequest(config, `/open/third-party/files/${encodeURIComponent(id)}`);
      const url = pickAudioUrl(detail);
      if (!url) {
        console.warn(`[PlaudSource] Recording ${id} has no audio URL; skipping.`);
        continue;
      }
      staged = path.join(ensureRuntimeDirs().importTmp, `plaud-${importId}.download`);
      await downloadTo(url, staged);
      const name = (item.name || item.file_name || item.title || `PLAUD ${id}`).toString();
      await imports.importLocalFile(source.user_id, staged, {
        importId,
        originalName: `${name.replace(/[/\\]/g, '_')}.mp3`,
        contentType: 'audio/mpeg',
        captureTime: normalizeTime(item.created_at ?? item.start_time ?? item.createdAt),
      });
      imported += 1;
    } catch (error) {
      // One bad recording must not stop the rest of the sweep; it is retried on
      // the next poll because nothing was recorded as imported.
      console.error(`[PlaudSource] Failed to import recording ${id}:`, error.message);
    } finally {
      if (staged) { try { fs.unlinkSync(staged); } catch (_) { /* best-effort */ } }
    }
  }
  return { available: items.length, imported };
}

function normalizeTime(value) {
  if (value === undefined || value === null) return undefined;
  // Accept ISO strings and epoch seconds/milliseconds alike.
  if (typeof value === 'number') {
    const millis = value > 1e12 ? value : value * 1000;
    return new Date(millis).toISOString();
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString();
}

const plaudSourceService = {
  verifyAccess,

  async startSource(source) {
    // Restart cleanly if the source is reconfigured while running.
    this.stopSource(source.id);
    if (!source.enabled || !source.config?.accessToken) return;

    const minutes = Math.max(MIN_POLL_MINUTES, Number(source.config.pollMinutes) || DEFAULT_POLL_MINUTES);
    const run = async () => {
      try {
        const result = await sweep(source);
        if (result.imported > 0) {
          console.log(`[PlaudSource] Imported ${result.imported} recording(s) for source ${source.id}`);
        }
      } catch (error) {
        console.error(`[PlaudSource] Sweep failed for source ${source.id}:`, error.message);
        // An expired or revoked token can never recover on its own, so disable
        // the source and surface why instead of retrying every poll forever.
        if (error.status === 401 || error.status === 403) {
          this.stopSource(source.id);
          require('./index').update(source.user_id, source.id, {
            enabled: false,
            config: { ...source.config, error: 'PLAUD rejected the access token. Reconnect the source.' },
          });
        }
      }
    };

    const timer = setInterval(run, minutes * 60_000);
    if (typeof timer.unref === 'function') timer.unref();
    activePollers.set(source.id, timer);
    console.log(`[PlaudSource] Started source ${source.id} (polling every ${minutes} min)`);
    await run();
  },

  stopSource(sourceId) {
    const timer = activePollers.get(sourceId);
    if (timer) {
      clearInterval(timer);
      activePollers.delete(sourceId);
      console.log(`[PlaudSource] Stopped source ${sourceId}`);
    }
  },
};

module.exports = plaudSourceService;
