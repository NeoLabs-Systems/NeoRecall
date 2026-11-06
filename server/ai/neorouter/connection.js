'use strict';

const { getDatabase } = require('../../db/database');
const { encryptString, decryptString } = require('../../utils/crypto');

// The NeoRouter this server works through: one connection for the whole
// installation, set up by an admin with "Connect NeoRouter". The address and the
// switch for embeddings are plain settings; the key is encrypted like every
// other provider key. Whether summaries/chat and transcription go through the
// router is not stored twice: it is whether that workload's selected provider
// is `neorouter` (see provider_settings_service).
const PROVIDER_ID = 'neorouter';
// The kinds of work NeoRecall does: language-model generation (summaries,
// memories, chat), speech to text, and embeddings for search.
const ROLES = Object.freeze(['llm', 'transcription', 'embeddings']);
const KEYS = Object.freeze({ connection: 'neorouter.connection', apiKey: 'neorouter.api_key' });

function readSetting(key) {
  const row = getDatabase().prepare('SELECT value_json FROM app_settings WHERE key=?').get(key);
  return row ? JSON.parse(row.value_json) : null;
}

function writeSetting(key, value) {
  getDatabase().prepare(`INSERT INTO app_settings (key,value_json) VALUES (?,?)
    ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`)
    .run(key, JSON.stringify(value));
}

// "router.local:3333", "https://router.example.com/app/" → the /v1 API base.
function apiBaseFor(address) {
  const raw = String(address || '').trim();
  if (!raw) return null;
  try {
    const url = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`);
    if (url.username || url.password) return null;
    return `${url.origin}/v1`;
  } catch {
    return null;
  }
}

/** { apiBase, origin, apiKey, embeddings } or null when not connected. */
function get() {
  const stored = readSetting(KEYS.connection);
  const encrypted = readSetting(KEYS.apiKey);
  if (!stored?.apiBase || !encrypted) return null;
  return { apiBase: stored.apiBase, origin: new URL(stored.apiBase).origin, apiKey: decryptString(encrypted), embeddings: stored.embeddings === true };
}

function save({ apiBase, apiKey, embeddings }) {
  const db = getDatabase();
  db.transaction(() => {
    writeSetting(KEYS.connection, { apiBase, embeddings: embeddings === true });
    writeSetting(KEYS.apiKey, encryptString(apiKey));
  })();
}

function setEmbeddings(enabled) {
  const stored = readSetting(KEYS.connection);
  if (!stored) return;
  writeSetting(KEYS.connection, { ...stored, embeddings: enabled === true });
}

function clear() {
  getDatabase().prepare('DELETE FROM app_settings WHERE key IN (?,?)').run(KEYS.connection, KEYS.apiKey);
}

module.exports = { PROVIDER_ID, ROLES, apiBaseFor, clear, get, save, setEmbeddings };
