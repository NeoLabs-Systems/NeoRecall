'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs, ensurePrivateDirectory } = require('../../../runtime/paths');
const { encryptFileStream, decryptFileStream, sha256File } = require('../../utils/crypto');
const { createDestination } = require('./destinations');
const { artifactKey } = require('./destinations/backup_destination');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('backup');

// One run at a time, per process.
//
// The job queue already dedupes the scheduled run by resource id, but a manual
// run from the dashboard can land while one is in flight. Two concurrent
// snapshots of the same database is wasted IO at best, so the second caller is
// told a run is already going rather than queued behind it.
let running = false;

function stagingDirectory() {
  const { backups } = ensureRuntimeDirs();
  const staging = path.join(backups, '.staging');
  ensurePrivateDirectory(staging);
  return staging;
}

// Removes staging files whatever happened. A crashed run leaves a plaintext
// snapshot behind, so the next run sweeps the directory before it starts.
function sweepStaging() {
  const staging = stagingDirectory();
  for (const name of fs.readdirSync(staging)) {
    try { fs.rmSync(path.join(staging, name), { force: true }); } catch (_) { /* best effort */ }
  }
}

// Takes a consistent snapshot of the live database.
//
// SQLite's online backup API, not a file copy: with WAL enabled the database
// file on disk is not a complete database on its own, and copying it under a
// concurrent write produces an artifact that restores to a corrupt or
// half-committed state.
async function snapshot(destinationPath) {
  await getDatabase().backup(destinationPath);
  await fs.promises.chmod(destinationPath, 0o600);
}

async function prune(destination, retain, db) {
  const artifacts = await destination.list();
  const expired = artifacts.slice(retain);
  for (const artifact of expired) {
    await destination.remove(artifact.key);
    db.prepare("UPDATE backups SET pruned_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE artifact_key=? AND pruned_at IS NULL")
      .run(artifact.key);
  }
  return expired.length;
}

async function run({ triggerKind = 'scheduled' } = {}) {
  const config = getConfig();
  if (running) return { skipped: true, reason: 'already_running' };
  running = true;
  const db = getDatabase();
  const id = crypto.randomUUID();
  const destination = createDestination(config.backupDestination);
  db.prepare("INSERT INTO backups (id,destination,trigger_kind,state) VALUES (?,?,?,'running')")
    .run(id, destination.name, triggerKind);
  const startedAt = Date.now();
  const staging = stagingDirectory();
  const plain = path.join(staging, `${id}.sqlite3`);
  const sealed = path.join(staging, `${id}.nrbak`);
  try {
    sweepStaging();
    await snapshot(plain);
    const checksum = sha256File(plain);
    await encryptFileStream(plain, sealed);
    const key = artifactKey(new Date());
    const stored = await destination.store(sealed, key);
    db.prepare(`UPDATE backups SET state='succeeded',artifact_key=?,bytes=?,checksum=?,
      completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(stored.key, stored.bytes, checksum, id);
    const pruned = await prune(destination, config.backupRetain, db);
    logger.info('Backup completed', {
      destination: destination.name, key: stored.key, megabytes: Number((stored.bytes / 1e6).toFixed(1)),
      seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)), pruned, trigger: triggerKind,
    });
    return { id, key: stored.key, bytes: stored.bytes, checksum, pruned };
  } catch (error) {
    db.prepare(`UPDATE backups SET state='failed',error_code=?,error_message=?,
      completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
      .run(error.code || 'BACKUP_FAILED', String(error.message).slice(0, 500), id);
    logger.error('Backup failed', { destination: destination.name, trigger: triggerKind, error });
    throw error;
  } finally {
    for (const file of [plain, sealed]) { try { fs.rmSync(file, { force: true }); } catch (_) { /* best effort */ } }
    running = false;
  }
}

// True when the schedule is due. Kept here rather than in the scheduler so the
// interval rule has exactly one definition, shared with the status view.
function due(db = getDatabase()) {
  const config = getConfig();
  if (!config.backupEnabled) return false;
  const last = db.prepare("SELECT completed_at FROM backups WHERE state='succeeded' ORDER BY completed_at DESC LIMIT 1").get();
  if (!last) return true;
  return Date.now() - Date.parse(last.completed_at) >= config.backupIntervalHours * 3_600_000;
}

async function status() {
  const config = getConfig();
  const db = getDatabase();
  const last = db.prepare('SELECT * FROM backups ORDER BY started_at DESC LIMIT 1').get() || null;
  const lastSuccess = db.prepare("SELECT * FROM backups WHERE state='succeeded' ORDER BY completed_at DESC LIMIT 1").get() || null;
  let location = null;
  let artifacts = [];
  let unreachable = null;
  try {
    const destination = createDestination(config.backupDestination);
    location = await destination.describe();
    artifacts = await destination.list();
  } catch (error) { unreachable = error.message; }
  return {
    enabled: config.backupEnabled,
    destination: config.backupDestination,
    location,
    unreachable,
    intervalHours: config.backupIntervalHours,
    retain: config.backupRetain,
    running,
    due: due(db),
    nextDueAt: lastSuccess ? new Date(Date.parse(lastSuccess.completed_at) + config.backupIntervalHours * 3_600_000).toISOString() : null,
    last,
    lastSuccessAt: lastSuccess?.completed_at || null,
    artifactCount: artifacts.length,
    artifactBytes: artifacts.reduce((total, artifact) => total + artifact.bytes, 0),
    artifacts: artifacts.slice(0, 20),
  };
}

function history(limit = 20) {
  return getDatabase().prepare('SELECT * FROM backups ORDER BY started_at DESC LIMIT ?')
    .all(Math.min(Number(limit) || 20, 100));
}

// Restores an artifact to a local path. Deliberately does not overwrite the
// live database: a restore replaces the file the server has open, so it belongs
// to the operator with the server stopped, not to a running process.
async function restore(key, outputPath) {
  const destination = createDestination(getConfig().backupDestination);
  const staging = stagingDirectory();
  const sealed = path.join(staging, `restore-${crypto.randomUUID()}.nrbak`);
  try {
    await destination.fetch(key, sealed);
    await decryptFileStream(sealed, outputPath);
    return { key, path: outputPath, checksum: sha256File(outputPath) };
  } finally {
    try { fs.rmSync(sealed, { force: true }); } catch (_) { /* best effort */ }
  }
}

module.exports = { run, status, history, restore, due };
