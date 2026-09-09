'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs, ensurePrivateDirectory } = require('../../../runtime/paths');
const { sha256File } = require('../../utils/crypto');
const jobs = require('../jobs/job_service');
const tempAudio = require('../ingest/temp_audio_service');
const accounts = require('./cloud_account_service');
const { createWebDavSink } = require('./sinks/webdav_sink');
const userExport = require('./user_export_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('cloud-archive');

const AUDIO_PUT_PRIORITY = 40;
const DATA_BACKUP_PRIORITY = -25;

function pendingDir() {
  const { cloudPending } = ensureRuntimeDirs();
  ensurePrivateDirectory(cloudPending);
  return cloudPending;
}

function extensionOf(file) {
  const ext = path.extname(file || '').replace(/^\./, '').replace(/[^a-z0-9]/gi, '').toLowerCase();
  return ext || 'bin';
}

function dateStamp(iso) {
  const value = iso && !Number.isNaN(Date.parse(iso)) ? new Date(iso) : new Date();
  return value.toISOString().slice(0, 10);
}

function artifactStamp(now = new Date()) {
  return now.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

function enqueuePut(userId, database = getDatabase()) {
  jobs.enqueue({
    userId,
    resourceType: 'user',
    resourceId: `cloud-put-${userId}`,
    type: 'cloud_put',
    priority: AUDIO_PUT_PRIORITY,
  }, database);
}

function enqueueDataBackup(userId, triggerKind = 'scheduled') {
  jobs.enqueue({
    userId,
    resourceType: 'user',
    resourceId: `cloud-backup-${userId}`,
    type: 'cloud_user_backup',
    priority: DATA_BACKUP_PRIORITY,
    payload: { triggerKind },
  });
}

function sinkFor(userId) {
  const account = accounts.get(userId);
  const password = accounts.appPassword(userId);
  if (!account || !password) {
    throw Object.assign(new Error('Nextcloud is not connected.'), { code: 'CLOUD_NOT_CONNECTED', retryable: false });
  }
  return createWebDavSink({
    baseUrl: account.baseUrl,
    username: account.username,
    password,
    folder: account.folder,
  });
}

function insertItem({ userId, accountId, kind, localPath, remotePath, bytes, checksum }, database = getDatabase()) {
  const id = crypto.randomUUID();
  database.prepare(`INSERT INTO cloud_archive_items
    (id,user_id,account_id,kind,local_path,remote_path,bytes,sha256,state)
    VALUES (?,?,?,?,?,?,?,?,'queued')`).run(id, userId, accountId, kind, localPath, remotePath, bytes, checksum);
  return id;
}

// Copy a transcribed chunk aside for Nextcloud. Must not throw to the receipt
// path: a failed copy is a missed backup, not a stuck recording.
function stageAudio(chunk) {
  if (!chunk?.temporary_path || !fs.existsSync(chunk.temporary_path)) return { skipped: true, reason: 'missing' };
  const account = accounts.get(chunk.user_id);
  if (!account || !account.audioEnabled) return { skipped: true, reason: 'disabled' };
  try {
    const id = crypto.randomUUID();
    const dest = path.join(pendingDir(), `${id}.${extensionOf(chunk.temporary_path)}`);
    fs.copyFileSync(chunk.temporary_path, dest);
    fs.chmodSync(dest, 0o600);
    const remotePath = `audio/${dateStamp(chunk.device_started_at)}/${chunk.session_id}/${chunk.id}.${extensionOf(chunk.temporary_path)}`;
    insertItem({
      userId: chunk.user_id,
      accountId: account.id,
      kind: 'audio',
      localPath: dest,
      remotePath,
      bytes: fs.statSync(dest).size,
      checksum: sha256File(dest),
    });
    enqueuePut(chunk.user_id);
    return { queued: true };
  } catch (error) {
    logger.warn('Cloud audio copy failed', { userId: chunk.user_id, chunkId: chunk.id, error });
    accounts.recordError(chunk.user_id, error.message);
    return { skipped: true, reason: 'copy_failed' };
  }
}

function dropItem(item, reason) {
  const db = getDatabase();
  tempAudio.unlinkStrict(item.local_path);
  db.prepare(`UPDATE cloud_archive_items SET state='dropped', local_path=NULL, last_error=?, uploaded_at=?
    WHERE id=?`).run(String(reason || 'dropped').slice(0, 500), new Date().toISOString(), item.id);
}

async function putOne(item) {
  const db = getDatabase();
  db.prepare(`UPDATE cloud_archive_items SET state='uploading', attempts=attempts+1 WHERE id=?`).run(item.id);
  try {
    const sink = sinkFor(item.user_id);
    await sink.put(item.local_path, item.remote_path);
    tempAudio.unlinkStrict(item.local_path);
    db.prepare(`UPDATE cloud_archive_items SET state='uploaded', local_path=NULL, uploaded_at=?, last_error=NULL
      WHERE id=?`).run(new Date().toISOString(), item.id);
    accounts.recordSuccess(item.user_id, item.kind);
    return { uploaded: true, id: item.id };
  } catch (error) {
    const maxAttempts = getConfig().cloudPutMaxAttempts;
    const attempts = (item.attempts || 0) + 1;
    const message = error.message || 'Upload failed';
    accounts.recordError(item.user_id, message);
    const retryable = error.retryable !== false && error.code !== 'CLOUD_AUTH_FAILED';
    if (!retryable || attempts >= maxAttempts) {
      dropItem({ ...item, attempts }, message);
      if (error.code === 'CLOUD_AUTH_FAILED') {
        throw Object.assign(error, { retryable: false });
      }
      return { dropped: true, id: item.id };
    }
    db.prepare(`UPDATE cloud_archive_items SET state='queued', last_error=? WHERE id=?`)
      .run(String(message).slice(0, 500), item.id);
    throw Object.assign(error, { retryable: true });
  }
}

async function drain(userId) {
  const db = getDatabase();
  let uploaded = 0;
  for (;;) {
    const item = db.prepare(`SELECT * FROM cloud_archive_items
      WHERE user_id=? AND state='queued' ORDER BY created_at ASC LIMIT 1`).get(userId);
    if (!item) break;
    if (!item.local_path || !fs.existsSync(item.local_path)) {
      dropItem(item, 'Pending file is missing.');
      continue;
    }
    const result = await putOne(item);
    if (result.uploaded) uploaded += 1;
  }
  return { uploaded };
}

async function backupUserData(userId, { force = false } = {}) {
  const account = accounts.get(userId);
  if (!account) return { skipped: true, reason: 'disconnected' };
  if (!force && !account.dataBackupEnabled) return { skipped: true, reason: 'disabled' };
  const bytes = userExport.build(userId);
  const id = crypto.randomUUID();
  const dest = path.join(pendingDir(), `${id}.zip`);
  fs.writeFileSync(dest, bytes, { mode: 0o600 });
  const remotePath = `backups/neorecall-user-${artifactStamp()}.zip`;
  insertItem({
    userId,
    accountId: account.id,
    kind: 'data',
    localPath: dest,
    remotePath,
    bytes: bytes.length,
    checksum: sha256File(dest),
  });
  enqueuePut(userId);
  return drain(userId);
}

function scheduleDueBackups() {
  const intervalMs = getConfig().cloudUserBackupIntervalHours * 60 * 60_000;
  for (const userId of accounts.listDueDataBackups(intervalMs)) {
    enqueueDataBackup(userId, 'scheduled');
  }
}

function enqueuePendingPuts() {
  const db = getDatabase();
  for (const row of db.prepare(`SELECT DISTINCT user_id FROM cloud_archive_items WHERE state='queued'`).all()) {
    enqueuePut(row.user_id);
  }
}

function sweepPending() {
  const db = getDatabase();
  const { cloudPending } = ensureRuntimeDirs();
  const maxAgeMs = getConfig().cloudPendingMaxAgeMs;
  const cutoff = new Date(Date.now() - maxAgeMs).toISOString();
  let removed = 0;
  for (const item of db.prepare(`SELECT * FROM cloud_archive_items
    WHERE state IN ('queued','uploading','failed') AND created_at < ?`).all(cutoff)) {
    dropItem(item, 'Pending copy expired.');
    removed += 1;
  }
  db.prepare("DELETE FROM cloud_archive_items WHERE state IN ('uploaded','dropped') AND created_at < ?")
    .run(new Date(Date.now() - 24 * 60 * 60_000).toISOString());
  const referenced = new Set(db.prepare('SELECT local_path FROM cloud_archive_items WHERE local_path IS NOT NULL')
    .all().map((row) => path.resolve(row.local_path)));
  if (fs.existsSync(cloudPending)) {
    for (const entry of fs.readdirSync(cloudPending, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const file = path.resolve(cloudPending, entry.name);
      if (referenced.has(file)) continue;
      if (Date.now() - fs.statSync(file).mtimeMs > 60_000) {
        tempAudio.unlinkStrict(file);
        removed += 1;
      }
    }
  }
  return { removed };
}

module.exports = {
  stageAudio, drain, backupUserData, scheduleDueBackups, enqueuePendingPuts, sweepPending,
  enqueueDataBackup, enqueuePut,
};
