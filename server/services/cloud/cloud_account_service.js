'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { encryptString, decryptString } = require('../../utils/crypto');
const { HttpError } = require('../../middleware/error_handler');

const FOLDER_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

function nowIso() {
  return new Date().toISOString();
}

const PROVIDER_LABELS = { nextcloud: 'Nextcloud', neocloud: 'NeoCloud' };

function providerLabel(type) {
  return PROVIDER_LABELS[type] || 'cloud';
}

// Nextcloud keeps an app password, NeoCloud a device token. Both are the one
// credential the sink needs, so they share the encrypted slot; version 1 rows
// (Nextcloud before NeoCloud existed) read the same way.
function encryptSecret(type, credential) {
  if (type === 'neocloud') return encryptString(JSON.stringify({ version: 2, type, token: credential }));
  return encryptString(JSON.stringify({ version: 1, appPassword: credential }));
}

function decryptSecret(payload) {
  const parsed = JSON.parse(decryptString(payload));
  const credential = parsed?.type === 'neocloud' ? parsed.token : parsed?.appPassword;
  if (typeof credential !== 'string') throw new Error('Cloud secret is malformed.');
  return credential;
}

function hydrate(row) {
  return {
    id: row.id,
    userId: row.user_id,
    type: row.type,
    baseUrl: row.base_url,
    username: row.username,
    folder: row.folder,
    audioEnabled: row.audio_enabled === 1,
    dataBackupEnabled: row.data_backup_enabled === 1,
    status: row.status,
    lastError: row.last_error,
    lastAudioUploadAt: row.last_audio_upload_at,
    lastDataBackupAt: row.last_data_backup_at,
    remoteDeviceId: row.remote_device_id,
    quotaUsed: row.quota_used,
    quotaLimit: row.quota_limit,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function getRow(userId) {
  return getDatabase().prepare('SELECT * FROM cloud_accounts WHERE user_id=?').get(userId) || null;
}

function get(userId) {
  const row = getRow(userId);
  return row ? hydrate(row) : null;
}

function credential(userId) {
  const row = getRow(userId);
  if (!row) return null;
  return decryptSecret(row.secret_encrypted);
}

function pendingCounts(userId) {
  const row = getDatabase().prepare(`SELECT COUNT(*) AS count FROM cloud_archive_items
    WHERE user_id=? AND state IN ('queued','uploading')`).get(userId);
  return row?.count || 0;
}

function assemblingCount(userId) {
  const row = getDatabase().prepare(`SELECT COUNT(*) AS count FROM cloud_recording_assemblies
    WHERE user_id=? AND state='assembling'`).get(userId);
  return row?.count || 0;
}

function publicAccount(userId) {
  const account = get(userId);
  if (!account) {
    return {
      connected: false,
      status: 'disconnected',
      type: null,
      audioEnabled: false,
      dataBackupEnabled: false,
      pendingCount: 0,
    };
  }
  return {
    connected: true,
    type: account.type,
    baseUrl: account.baseUrl,
    username: account.username,
    folder: account.folder,
    audioEnabled: account.audioEnabled,
    dataBackupEnabled: account.dataBackupEnabled,
    status: account.status,
    lastError: account.lastError,
    lastAudioUploadAt: account.lastAudioUploadAt,
    lastDataBackupAt: account.lastDataBackupAt,
    pendingCount: pendingCounts(userId) + assemblingCount(userId),
    ...(account.type === 'neocloud' && account.quotaUsed !== null && account.quotaUsed !== undefined
      ? { quota: { used: account.quotaUsed, limit: account.quotaLimit ?? -1 } }
      : {}),
  };
}

// Connecting again (same or other provider) keeps the toggles and the queue:
// pending copies go to the new destination. A half-finished NeoCloud upload
// belongs to the old server, so its resume id is forgotten.
function upsertConnected(userId, { type = 'nextcloud', baseUrl, username, appPassword: password, token, deviceId = null, quota = null }) {
  const db = getDatabase();
  const existing = getRow(userId);
  const id = existing?.id || crypto.randomUUID();
  const secret = encryptSecret(type, type === 'neocloud' ? token : password);
  const quotaUsed = quota && Number.isFinite(quota.used) ? quota.used : null;
  const quotaLimit = quota && Number.isFinite(quota.limit) ? quota.limit : null;
  db.transaction(() => {
    if (existing) {
      db.prepare(`UPDATE cloud_accounts SET type=?, base_url=?, username=?, secret_encrypted=?, remote_device_id=?,
        quota_used=?, quota_limit=?, status='connected', last_error=NULL, updated_at=? WHERE id=?`)
        .run(type, baseUrl, username, secret, deviceId, quotaUsed, quotaLimit, nowIso(), id);
      db.prepare('UPDATE cloud_archive_items SET remote_upload_id=NULL WHERE account_id=?').run(id);
    } else {
      db.prepare(`INSERT INTO cloud_accounts
        (id,user_id,type,base_url,username,secret_encrypted,remote_device_id,quota_used,quota_limit,status)
        VALUES (?,?,?,?,?,?,?,?,?,'connected')`)
        .run(id, userId, type, baseUrl, username, secret, deviceId, quotaUsed, quotaLimit);
    }
  })();
  return get(userId);
}

// Finishes a NeoCloud device login. The quota is read with the fresh token
// first: it proves the token works and Settings can show how full NeoCloud is
// right away. A failed read still connects; the next upload refreshes it.
async function connectNeoCloud(userId, { baseUrl, username, token, deviceId }, { fetchImpl } = {}) {
  const { createNeoCloudSink } = require('./sinks/neocloud_sink');
  let quota = null;
  try {
    quota = (await createNeoCloudSink({ baseUrl, token, ...(fetchImpl ? { fetchImpl } : {}) }).me()).quota;
  } catch {
    quota = null;
  }
  return upsertConnected(userId, { type: 'neocloud', baseUrl, username, token, deviceId, quota });
}

function recordQuota(userId, quota) {
  if (!quota || !Number.isFinite(quota.used)) return;
  getDatabase().prepare('UPDATE cloud_accounts SET quota_used=?, quota_limit=? WHERE user_id=?')
    .run(quota.used, Number.isFinite(quota.limit) ? quota.limit : -1, userId);
}

function update(userId, patch) {
  const row = getRow(userId);
  if (!row) throw new HttpError(404, 'CLOUD_NOT_CONNECTED', 'Connect a cloud backup first.');
  const next = {
    audioEnabled: patch.audioEnabled === undefined ? row.audio_enabled === 1 : Boolean(patch.audioEnabled),
    dataBackupEnabled: patch.dataBackupEnabled === undefined ? row.data_backup_enabled === 1 : Boolean(patch.dataBackupEnabled),
    folder: patch.folder === undefined ? row.folder : String(patch.folder).trim(),
  };
  if (!FOLDER_PATTERN.test(next.folder)) {
    throw new HttpError(400, 'INVALID_CLOUD_FOLDER', `The ${providerLabel(row.type)} folder name may only contain letters, numbers, dots, dashes and underscores.`);
  }
  getDatabase().prepare(`UPDATE cloud_accounts SET audio_enabled=?, data_backup_enabled=?, folder=?, updated_at=?
    WHERE id=?`).run(Number(next.audioEnabled), Number(next.dataBackupEnabled), next.folder, nowIso(), row.id);
  return publicAccount(userId);
}

function recordSuccess(userId, kind) {
  const column = kind === 'data' ? 'last_data_backup_at' : 'last_audio_upload_at';
  getDatabase().prepare(`UPDATE cloud_accounts SET ${column}=?, status='connected', last_error=NULL, updated_at=?
    WHERE user_id=?`).run(nowIso(), nowIso(), userId);
}

function recordError(userId, message) {
  getDatabase().prepare(`UPDATE cloud_accounts SET status='error', last_error=?, updated_at=? WHERE user_id=?`)
    .run(String(message || 'Upload failed').slice(0, 500), nowIso(), userId);
}

function disconnect(userId) {
  const archive = require('./archive_service');
  archive.discardPending(userId);
  getDatabase().prepare('DELETE FROM cloud_accounts WHERE user_id=?').run(userId);
}

function listDueDataBackups(intervalMs, now = Date.now()) {
  const cutoff = new Date(now - intervalMs).toISOString();
  return getDatabase().prepare(`SELECT user_id FROM cloud_accounts
    WHERE data_backup_enabled=1 AND (last_data_backup_at IS NULL OR last_data_backup_at < ?)`)
    .all(cutoff).map((row) => row.user_id);
}

function listAudioEnabled(userId) {
  const row = getRow(userId);
  return Boolean(row && row.audio_enabled === 1);
}

module.exports = {
  get, getRow, credential, publicAccount, upsertConnected, update, recordSuccess, recordError, recordQuota,
  connectNeoCloud,
  disconnect, listDueDataBackups, listAudioEnabled, pendingCounts, providerLabel,
};
