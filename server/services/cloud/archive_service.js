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
const { concatRecording } = require('./concat_recording');
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

function assemblyRoot(id) {
  const dir = path.join(pendingDir(), 'assemblies', id);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

function remoteAudioPath(session, source) {
  const stamp = artifactStamp(new Date(session.device_started_at || Date.now()));
  const kind = String(source.kind || 'audio').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '') || 'audio';
  return `audio/${dateStamp(session.device_started_at)}/${stamp}-${kind}-${String(source.id).slice(0, 8)}.wav`;
}

function getAssembly(userId, sessionId, sourceId) {
  return getDatabase().prepare(`SELECT * FROM cloud_recording_assemblies
    WHERE user_id=? AND session_id=? AND source_id=? AND state='assembling'`).get(userId, sessionId, sourceId) || null;
}

function ensureAssembly(chunk, account) {
  const existing = getAssembly(chunk.user_id, chunk.session_id, chunk.source_id);
  if (existing) return existing;
  const db = getDatabase();
  const session = db.prepare('SELECT * FROM recording_sessions WHERE id=?').get(chunk.session_id);
  const source = db.prepare('SELECT * FROM recording_sources WHERE id=?').get(chunk.source_id);
  if (!session || !source) return null;
  const id = crypto.randomUUID();
  const localDir = assemblyRoot(id);
  try {
    db.prepare(`INSERT INTO cloud_recording_assemblies
      (id,user_id,account_id,session_id,source_id,local_dir,remote_path,state)
      VALUES (?,?,?,?,?,?,?,'assembling')`)
      .run(id, chunk.user_id, account.id, chunk.session_id, chunk.source_id, localDir, remoteAudioPath(session, source));
    return db.prepare('SELECT * FROM cloud_recording_assemblies WHERE id=?').get(id);
  } catch (error) {
    tempAudio.unlinkStrict(localDir);
    const raced = getAssembly(chunk.user_id, chunk.session_id, chunk.source_id);
    if (raced) return raced;
    throw error;
  }
}

function partName(chunk) {
  return `${String(chunk.sequence).padStart(6, '0')}.${extensionOf(chunk.temporary_path)}`;
}

function sessionClosed(session) {
  return !session || session.status !== 'active';
}

function assemblyReady(assembly, database = getDatabase()) {
  const session = database.prepare('SELECT status FROM recording_sessions WHERE id=?').get(assembly.session_id);
  if (!sessionClosed(session)) {
    const source = database.prepare('SELECT closed_at FROM recording_sources WHERE id=?').get(assembly.source_id);
    if (!source?.closed_at) return false;
  }
  const unfinished = database.prepare(`SELECT 1 FROM audio_chunks
    WHERE source_id=? AND state NOT IN ('transcribed','silent') LIMIT 1`).get(assembly.source_id);
  return !unfinished;
}

function dropAssembly(assembly, reason) {
  const db = getDatabase();
  tempAudio.unlinkStrict(assembly.local_dir);
  db.prepare(`UPDATE cloud_recording_assemblies SET state='dropped', last_error=?, updated_at=?
    WHERE id=?`).run(String(reason || 'dropped').slice(0, 500), new Date().toISOString(), assembly.id);
}

function listParts(assembly) {
  const db = getDatabase();
  const overlapBySequence = new Map(db.prepare('SELECT sequence, overlap_ms FROM audio_chunks WHERE source_id=?')
    .all(assembly.source_id).map((row) => [row.sequence, row.overlap_ms || 0]));
  if (!assembly.local_dir || !fs.existsSync(assembly.local_dir)) return [];
  return fs.readdirSync(assembly.local_dir)
    .map((name) => {
      const match = /^(\d+)\.[A-Za-z0-9]+$/.exec(name);
      if (!match) return null;
      const sequence = Number(match[1]);
      return {
        sequence,
        file: path.join(assembly.local_dir, name),
        overlapMs: overlapBySequence.get(sequence) || 0,
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.sequence - right.sequence);
}

function finalizeAssembly(assembly) {
  if (!assemblyReady(assembly)) return { skipped: true, reason: 'incomplete' };
  const parts = listParts(assembly);
  if (!parts.length) {
    dropAssembly(assembly, 'Recording assembly has no audio.');
    return { skipped: true, reason: 'empty' };
  }
  const dest = path.join(pendingDir(), `${assembly.id}.wav`);
  try {
    concatRecording(parts, dest);
    const bytes = fs.statSync(dest).size;
    const checksum = sha256File(dest);
    require('../../utils/sealed_fs').sealInPlace(dest);
    insertItem({
      userId: assembly.user_id,
      accountId: assembly.account_id,
      kind: 'audio',
      localPath: dest,
      remotePath: assembly.remote_path,
      bytes,
      checksum,
    });
    tempAudio.unlinkStrict(assembly.local_dir);
    getDatabase().prepare('DELETE FROM cloud_recording_assemblies WHERE id=?').run(assembly.id);
    return { queued: true };
  } catch (error) {
    tempAudio.unlinkStrict(dest);
    logger.warn('Cloud recording join failed', { userId: assembly.user_id, sessionId: assembly.session_id, error });
    accounts.recordError(assembly.user_id, error.message);
    getDatabase().prepare(`UPDATE cloud_recording_assemblies SET last_error=?, updated_at=? WHERE id=?`)
      .run(String(error.message || 'Join failed').slice(0, 500), new Date().toISOString(), assembly.id);
    return { skipped: true, reason: 'join_failed' };
  }
}

function finalizeReady(userId) {
  const db = getDatabase();
  let queued = 0;
  for (const assembly of db.prepare(`SELECT * FROM cloud_recording_assemblies
    WHERE user_id=? AND state='assembling'`).all(userId)) {
    const result = finalizeAssembly(assembly);
    if (result.queued) queued += 1;
  }
  return queued;
}

function maybeEnqueueAfterStage(chunk) {
  const session = getDatabase().prepare('SELECT status FROM recording_sessions WHERE id=?').get(chunk.session_id);
  const source = getDatabase().prepare('SELECT closed_at FROM recording_sources WHERE id=?').get(chunk.source_id);
  if (sessionClosed(session) || source?.closed_at) enqueuePut(chunk.user_id);
}

// Copy a transcribed chunk aside for Nextcloud. Must not throw to the receipt
// path: a failed copy is a missed backup, not a stuck recording. The PUT waits
// until the recording itself has ended so Nextcloud receives one file, not a
// folder of 30-second parts.
function stageAudio(chunk) {
  if (!chunk?.temporary_path || !fs.existsSync(chunk.temporary_path)) return { skipped: true, reason: 'missing' };
  const account = accounts.get(chunk.user_id);
  if (!account || !account.audioEnabled) return { skipped: true, reason: 'disabled' };
  try {
    const assembly = ensureAssembly(chunk, account);
    if (!assembly) return { skipped: true, reason: 'no_session' };
    const dest = path.join(assembly.local_dir, partName(chunk));
    require('../../utils/sealed_fs').copyPlain(chunk.temporary_path, dest);
    require('../../utils/sealed_fs').sealInPlace(dest);
    maybeEnqueueAfterStage(chunk);
    return { staged: true };
  } catch (error) {
    logger.warn('Cloud audio copy failed', { userId: chunk.user_id, chunkId: chunk.id, error });
    accounts.recordError(chunk.user_id, error.message);
    return { skipped: true, reason: 'copy_failed' };
  }
}

function finalizeSession(sessionId) {
  const db = getDatabase();
  const session = db.prepare('SELECT user_id FROM recording_sessions WHERE id=?').get(sessionId);
  if (!session) return { skipped: true };
  enqueuePut(session.user_id);
  return { queued: true };
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
    // Nextcloud is the owner's ordinary library: a playable WAV or a readable
    // zip, never a sealed NeoRecall blob. Local pending copies stay sealed.
    await require('../../utils/sealed_fs').withPlainAsync(item.local_path, async (plain) => {
      if (require('../../utils/sealed_fs').isSealed(plain)) {
        throw new Error('Refusing to upload a sealed file to Nextcloud.');
      }
      return sink.put(plain, item.remote_path);
    });
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
  finalizeReady(userId);
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
  const checksum = sha256File(dest);
  require('../../utils/sealed_fs').sealInPlace(dest);
  const remotePath = `backups/neorecall-user-${artifactStamp()}.zip`;
  insertItem({
    userId,
    accountId: account.id,
    kind: 'data',
    localPath: dest,
    remotePath,
    bytes: bytes.length,
    checksum,
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
  const users = new Set();
  for (const row of db.prepare(`SELECT DISTINCT user_id FROM cloud_archive_items WHERE state='queued'`).all()) {
    users.add(row.user_id);
  }
  for (const row of db.prepare(`SELECT DISTINCT a.user_id FROM cloud_recording_assemblies a
    LEFT JOIN recording_sessions s ON s.id=a.session_id
    WHERE a.state='assembling' AND (s.id IS NULL OR s.status != 'active')`).all()) {
    users.add(row.user_id);
  }
  for (const userId of users) enqueuePut(userId);
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
  for (const assembly of db.prepare(`SELECT a.* FROM cloud_recording_assemblies a
    LEFT JOIN recording_sessions s ON s.id=a.session_id
    WHERE a.state='assembling' AND a.created_at < ? AND (s.id IS NULL OR s.status != 'active')`).all(cutoff)) {
    dropAssembly(assembly, 'Pending recording copy expired.');
    removed += 1;
  }
  db.prepare("DELETE FROM cloud_recording_assemblies WHERE state='dropped' AND updated_at < ?")
    .run(new Date(Date.now() - 24 * 60 * 60_000).toISOString());
  const referenced = new Set([
    ...db.prepare('SELECT local_path FROM cloud_archive_items WHERE local_path IS NOT NULL').all()
      .map((row) => path.resolve(row.local_path)),
    ...db.prepare('SELECT local_dir FROM cloud_recording_assemblies WHERE local_dir IS NOT NULL').all()
      .map((row) => path.resolve(row.local_dir)),
  ]);
  if (fs.existsSync(cloudPending)) {
    for (const entry of fs.readdirSync(cloudPending, { withFileTypes: true })) {
      if (entry.name === 'assemblies') continue;
      if (!entry.isFile()) continue;
      const file = path.resolve(cloudPending, entry.name);
      if (referenced.has(file)) continue;
      if (Date.now() - fs.statSync(file).mtimeMs > 60_000) {
        tempAudio.unlinkStrict(file);
        removed += 1;
      }
    }
  }
  const assembliesRoot = path.join(cloudPending, 'assemblies');
  if (fs.existsSync(assembliesRoot)) {
    for (const entry of fs.readdirSync(assembliesRoot, { withFileTypes: true })) {
      const dir = path.resolve(assembliesRoot, entry.name);
      if (referenced.has(dir)) continue;
      if (Date.now() - fs.statSync(dir).mtimeMs > 60_000) {
        tempAudio.unlinkStrict(dir);
        removed += 1;
      }
    }
  }
  return { removed };
}

function discardPending(userId) {
  const db = getDatabase();
  for (const item of db.prepare('SELECT local_path FROM cloud_archive_items WHERE user_id=? AND local_path IS NOT NULL').all(userId)) {
    tempAudio.unlinkStrict(item.local_path);
  }
  for (const assembly of db.prepare('SELECT local_dir FROM cloud_recording_assemblies WHERE user_id=?').all(userId)) {
    tempAudio.unlinkStrict(assembly.local_dir);
  }
}

module.exports = {
  stageAudio, drain, backupUserData, scheduleDueBackups, enqueuePendingPuts, sweepPending,
  enqueueDataBackup, enqueuePut, finalizeSession, discardPending,
};
