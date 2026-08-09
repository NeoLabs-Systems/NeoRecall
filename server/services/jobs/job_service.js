'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

function enqueue({ userId = null, resourceType = null, resourceId = null, type, priority = 0, payload = {}, maxAttempts = getConfig().jobMaxAttempts }, database = getDatabase()) {
  const id = crypto.randomUUID();
  try {
    database.prepare(`INSERT INTO jobs
      (id,user_id,resource_type,resource_id,type,status,priority,max_attempts,payload_json)
      VALUES (?,?,?,?,?,'queued',?,?,?)`)
      .run(id, userId, resourceType, resourceId, type, priority, maxAttempts, JSON.stringify(payload));
    return id;
  } catch (error) {
    if (error.code === 'SQLITE_CONSTRAINT_UNIQUE' && resourceId) {
      return database.prepare("SELECT id FROM jobs WHERE type=? AND resource_id=? AND status IN ('queued','leased')").get(type, resourceId)?.id;
    }
    throw error;
  }
}

function claimNext(workerId, leaseMs = getConfig().jobLeaseMs, canTranscribe = true) {
  const db = getDatabase();
  const now = new Date().toISOString();
  const leaseExpiresAt = new Date(Date.now() + leaseMs).toISOString();
  return db.transaction(() => {
    db.prepare(`UPDATE jobs SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
      next_attempt_at=?, updated_at=? WHERE status='leased' AND lease_expires_at < ?`).run(now, now, now);
    const job = db.prepare(`SELECT j.* FROM jobs j WHERE j.status='queued' AND j.next_attempt_at <= ?
      AND (? OR j.type != 'transcribe_chunk')
      AND (j.type != 'transcribe_chunk' OR EXISTS (
        SELECT 1 FROM audio_chunks current_chunk WHERE current_chunk.id=j.resource_id
        AND (current_chunk.state='persisted_cleanup_pending' OR current_chunk.sequence=0 OR EXISTS (
          SELECT 1 FROM audio_chunks previous_chunk
          WHERE previous_chunk.source_id=current_chunk.source_id
            AND previous_chunk.sequence=current_chunk.sequence-1
            AND previous_chunk.state IN ('transcribed','silent')
        ) OR EXISTS (
          SELECT 1 FROM recording_gaps gap
          WHERE gap.source_id=current_chunk.source_id
            AND current_chunk.sequence-1 BETWEEN gap.start_sequence AND gap.end_sequence
        ))
      ))
      ORDER BY j.priority DESC, j.created_at ASC LIMIT 1`).get(now, Number(canTranscribe));
    if (!job) return null;
    const changed = db.prepare(`UPDATE jobs SET status='leased',lease_owner=?,lease_expires_at=?,
      attempts=attempts+1,started_at=COALESCE(started_at,?),updated_at=? WHERE id=? AND status='queued'`)
      .run(workerId, leaseExpiresAt, now, now, job.id).changes;
    if (!changed) return null;
    return { ...job, status: 'leased', lease_owner: workerId, lease_expires_at: leaseExpiresAt, attempts: job.attempts + 1, payload: JSON.parse(job.payload_json) };
  })();
}

function renewLease(id, workerId, leaseMs = getConfig().jobLeaseMs) {
  return getDatabase().prepare("UPDATE jobs SET lease_expires_at=?,updated_at=? WHERE id=? AND status='leased' AND lease_owner=?")
    .run(new Date(Date.now() + leaseMs).toISOString(), new Date().toISOString(), id, workerId).changes === 1;
}

function complete(id, workerId) {
  return getDatabase().prepare(`UPDATE jobs SET status='completed',lease_owner=NULL,lease_expires_at=NULL,
    completed_at=?,updated_at=? WHERE id=? AND status='leased' AND lease_owner=?`)
    .run(new Date().toISOString(), new Date().toISOString(), id, workerId).changes === 1;
}

function fail(id, workerId, error, retryable = true) {
  const db = getDatabase();
  return db.transaction(() => {
    const job = db.prepare("SELECT * FROM jobs WHERE id=? AND status='leased' AND lease_owner=?").get(id, workerId);
    if (!job) return false;
    const shouldRetry = retryable && job.attempts < job.max_attempts;
    const delayMs = Math.min(15 * 60_000, 2 ** Math.max(0, job.attempts - 1) * 5_000);
    db.prepare(`UPDATE jobs SET status=?,lease_owner=NULL,lease_expires_at=NULL,next_attempt_at=?,
      last_error_code=?,last_error_message=?,completed_at=?,updated_at=? WHERE id=?`)
      .run(shouldRetry ? 'queued' : 'failed', new Date(Date.now() + delayMs).toISOString(), error.code || 'JOB_FAILED',
        String(error.message || error).slice(0, 1000), shouldRetry ? null : new Date().toISOString(), new Date().toISOString(), id);
    return shouldRetry;
  })();
}

function retry(id) {
  return getDatabase().prepare(`UPDATE jobs SET status='queued',attempts=0,next_attempt_at=?,lease_owner=NULL,
    lease_expires_at=NULL,last_error_code=NULL,last_error_message=NULL,completed_at=NULL,updated_at=?
    WHERE id=? AND status='failed'`).run(new Date().toISOString(), new Date().toISOString(), id).changes === 1;
}

function cancel(id) {
  return getDatabase().prepare("UPDATE jobs SET status='cancelled',completed_at=?,updated_at=? WHERE id=? AND status IN ('queued','failed')")
    .run(new Date().toISOString(), new Date().toISOString(), id).changes === 1;
}

module.exports = { enqueue, claimNext, renewLease, complete, fail, retry, cancel };
