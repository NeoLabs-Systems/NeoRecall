'use strict';

const fs = require('node:fs');
const { getDatabase, isVectorReady, expectedVecVersion } = require('../../db/database');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const jobs = require('../jobs/job_service');
const { HttpError } = require('../../middleware/error_handler');

function directoryBytes(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).reduce((sum, entry) => {
    const filename = require('node:path').join(directory, entry.name);
    return sum + (entry.isDirectory() ? directoryBytes(filename) : entry.isFile() ? fs.statSync(filename).size : 0);
  }, 0);
}

function temporaryBytes() {
  const runtime = ensureRuntimeDirs();
  return directoryBytes(runtime.audioTmp) + directoryBytes(runtime.importTmp);
}

function stats() {
  const db = getDatabase();
  return {
    users: db.prepare('SELECT COUNT(*) count FROM users').get().count,
    devices: db.prepare('SELECT COUNT(*) count FROM devices WHERE revoked_at IS NULL').get().count,
    recordings: db.prepare('SELECT COUNT(*) count FROM recording_sessions').get().count,
    queue: db.prepare("SELECT status,COUNT(*) count FROM jobs GROUP BY status").all(),
    oldestQueuedAt: db.prepare("SELECT MIN(created_at) value FROM jobs WHERE status='queued'").get().value,
    workers: db.prepare('SELECT * FROM worker_heartbeats ORDER BY heartbeat_at DESC').all(),
    temporaryAudioBytes: temporaryBytes(),
    temporaryChunkBytes: directoryBytes(ensureRuntimeDirs().audioTmp),
    temporaryImportBytes: directoryBytes(ensureRuntimeDirs().importTmp),
    cleanupPending: db.prepare("SELECT COUNT(*) count FROM audio_chunks WHERE state='persisted_cleanup_pending'").get().count,
    vector: { ready: isVectorReady(), version: expectedVecVersion },
    ai: db.prepare(`SELECT purpose,COUNT(*) attempts,COALESCE(SUM(prompt_tokens),0) prompt_tokens,
      COALESCE(SUM(completion_tokens),0) completion_tokens,COALESCE(SUM(cost_usd),0) cost_usd FROM ai_requests GROUP BY purpose`).all(),
    processing: db.prepare(`SELECT metric,AVG(value) average,MAX(value) maximum,unit FROM processing_metrics
      WHERE created_at>? GROUP BY metric,unit`).all(new Date(Date.now() - 24 * 60 * 60_000).toISOString()),
  };
}

function users(limit = 100) {
  return getDatabase().prepare(`SELECT id,username,email,role,disabled_at,created_at,last_login_at,
    (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) device_count,
    (SELECT COUNT(*) FROM recording_sessions r WHERE r.user_id=u.id) recording_count
    FROM users u ORDER BY created_at DESC LIMIT ?`).all(Math.min(500, Math.max(1, Number(limit) || 100)));
}

function setUserDisabled(id, disabled) {
  const result = getDatabase().prepare(`UPDATE users SET disabled_at=? WHERE id=?`).run(disabled ? new Date().toISOString() : null, id);
  if (!result.changes) throw new HttpError(404, 'NOT_FOUND', 'User not found.');
  if (disabled) getDatabase().prepare("UPDATE user_sessions SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=? AND revoked_at IS NULL").run(id);
}

function listJobs(query = {}) {
  const status = query.status || null;
  return getDatabase().prepare('SELECT * FROM jobs WHERE (? IS NULL OR status=?) ORDER BY created_at DESC LIMIT ?').all(status, status, Math.min(500, Math.max(1, Number(query.limit) || 100)));
}

function retryJob(id) { if (!jobs.retry(id)) throw new HttpError(409, 'JOB_NOT_RETRYABLE', 'Job is not in a retryable state.'); }
function cancelJob(id) { if (!jobs.cancel(id)) throw new HttpError(409, 'JOB_NOT_CANCELLABLE', 'Job is not in a cancellable state.'); }
function aiRequests(limit = 100) { return getDatabase().prepare('SELECT * FROM ai_requests ORDER BY reserved_at DESC LIMIT ?').all(Math.min(500, Math.max(1, Number(limit) || 100))); }
function audit(limit = 100) { return getDatabase().prepare('SELECT * FROM audit_log ORDER BY id DESC LIMIT ?').all(Math.min(500, Math.max(1, Number(limit) || 100))); }

module.exports = { stats, users, setUserDisabled, listJobs, retryJob, cancelJob, aiRequests, audit, temporaryBytes };
