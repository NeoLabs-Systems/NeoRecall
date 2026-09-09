'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { encryptString, decryptString } = require('../../utils/crypto');
const { HttpError } = require('../../middleware/error_handler');

const FOLDER_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

function nowIso() {
  return new Date().toISOString();
}

function encryptSecret(appPassword) {
  return encryptString(JSON.stringify({ version: 1, appPassword }));
}

function decryptSecret(payload) {
  const parsed = JSON.parse(decryptString(payload));
  if (!parsed || typeof parsed.appPassword !== 'string') throw new Error('Cloud secret is malformed.');
  return parsed.appPassword;
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

function appPassword(userId) {
  const row = getRow(userId);
  if (!row) return null;
  return decryptSecret(row.secret_encrypted);
}

function pendingCounts(userId) {
  const row = getDatabase().prepare(`SELECT COUNT(*) AS count FROM cloud_archive_items
    WHERE user_id=? AND state IN ('queued','uploading')`).get(userId);
  return row?.count || 0;
}

function publicAccount(userId) {
  const account = get(userId);
  if (!account) {
    return {
      connected: false,
      status: 'disconnected',
      type: 'nextcloud',
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
    pendingCount: pendingCounts(userId),
  };
}

function upsertConnected(userId, { baseUrl, username, appPassword: password }) {
  const db = getDatabase();
  const existing = getRow(userId);
  const id = existing?.id || crypto.randomUUID();
  const secret = encryptSecret(password);
  if (existing) {
    db.prepare(`UPDATE cloud_accounts SET base_url=?, username=?, secret_encrypted=?,
      status='connected', last_error=NULL, updated_at=? WHERE id=?`).run(baseUrl, username, secret, nowIso(), id);
  } else {
    db.prepare(`INSERT INTO cloud_accounts
      (id,user_id,type,base_url,username,secret_encrypted,status)
      VALUES (?,?,'nextcloud',?,?,?,'connected')`).run(id, userId, baseUrl, username, secret);
  }
  return get(userId);
}

function update(userId, patch) {
  const row = getRow(userId);
  if (!row) throw new HttpError(404, 'CLOUD_NOT_CONNECTED', 'Connect a Nextcloud instance first.');
  const next = {
    audioEnabled: patch.audioEnabled === undefined ? row.audio_enabled === 1 : Boolean(patch.audioEnabled),
    dataBackupEnabled: patch.dataBackupEnabled === undefined ? row.data_backup_enabled === 1 : Boolean(patch.dataBackupEnabled),
    folder: patch.folder === undefined ? row.folder : String(patch.folder).trim(),
  };
  if (!FOLDER_PATTERN.test(next.folder)) {
    throw new HttpError(400, 'INVALID_CLOUD_FOLDER', 'The Nextcloud folder name may only contain letters, numbers, dots, dashes and underscores.');
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
  const db = getDatabase();
  const items = db.prepare('SELECT local_path FROM cloud_archive_items WHERE user_id=? AND local_path IS NOT NULL').all(userId);
  const unlink = require('../ingest/temp_audio_service').unlinkStrict;
  for (const item of items) unlink(item.local_path);
  db.prepare('DELETE FROM cloud_accounts WHERE user_id=?').run(userId);
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
  get, getRow, appPassword, publicAccount, upsertConnected, update, recordSuccess, recordError,
  disconnect, listDueDataBackups, listAudioEnabled, pendingCounts,
};
