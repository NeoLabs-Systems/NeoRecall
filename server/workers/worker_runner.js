'use strict';

const os = require('node:os');
const crypto = require('node:crypto');
const { getDatabase } = require('../db/database');
const jobs = require('../services/jobs/job_service');
const tempAudio = require('../services/ingest/temp_audio_service');
const { createLogger } = require('../utils/logger');

const logger = createLogger('worker-runner');

function handlerFor(type) {
  if (type === 'transcribe_chunk') return require('./handlers/transcribe_handler');
  if (['cleanup_chunk_audio', 'sweep_temp_audio'].includes(type)) return require('./handlers/cleanup_handler');
  if (type === 'embed_search_documents') return require('./handlers/embed_handler');
  if (type === 'detect_boundaries') return require('./handlers/boundary_handler');
  if (type === 'preview_conversation') return require('./handlers/conversation_preview_handler');
  if (type === 'consolidate_memories') return require('./handlers/consolidation_handler');
  if (type === 'rewrite_merged_memory') return require('./handlers/memory_merge_handler');
  if (['maintenance', 'prune_events'].includes(type)) return require('./handlers/maintenance_handler');
  if (type === 'process_import') return require('./handlers/import_handler');
  if (type === 'backup') return require('./handlers/backup_handler');
  throw Object.assign(new Error(`Unknown job type: ${type}`), { code: 'UNKNOWN_JOB_TYPE', retryable: false });
}

function heartbeat(workerId, currentJobId, modelState = 'ready') {
  getDatabase().prepare(`INSERT INTO worker_heartbeats (worker_id,host,role,process_id,model_state,current_job_id,started_at,heartbeat_at)
    VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(worker_id) DO UPDATE SET model_state=excluded.model_state,current_job_id=excluded.current_job_id,
    process_id=excluded.process_id,heartbeat_at=excluded.heartbeat_at`).run(workerId, os.hostname(), 'processor', process.pid, modelState, currentJobId || null,
    new Date().toISOString(), new Date().toISOString());
}

function markChunkFailure(job, error, willRetry) {
  if (job.type !== 'transcribe_chunk') return;
  const db = getDatabase();
  const chunk = db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(job.resource_id);
  if (!chunk || chunk.state === 'persisted_cleanup_pending') return;
  if (willRetry) {
    db.prepare("UPDATE audio_chunks SET state='retryable_failed',error_code=?,error_message=?,updated_at=? WHERE id=?")
      .run(error.code || 'TRANSCRIPTION_FAILED', String(error.message).slice(0, 500), new Date().toISOString(), chunk.id);
  } else {
    const source = db.prepare('SELECT kind FROM recording_sources WHERE id=?').get(chunk.source_id);
    if (source?.kind === 'import') {
      const expiresAt = new Date(Date.now() + require('../config').getConfig().importFailedTtlHours * 60 * 60_000).toISOString();
      db.prepare("UPDATE audio_chunks SET state='retryable_failed',error_code=?,error_message=?,updated_at=? WHERE id=?")
        .run(error.code || 'TRANSCRIPTION_FAILED', String(error.message).slice(0, 500), new Date().toISOString(), chunk.id);
      // The failing import is identified by the chunk's source; a session can
      // hold several imports from the same device, so blaming the session would
      // fail whichever import happened to create it.
      db.prepare(`UPDATE imports SET state='failed',error_code=?,expires_at=?,updated_at=? WHERE user_id=?
        AND id=(SELECT substr(client_uuid,15) FROM recording_sources WHERE id=?)`)
        .run(error.code || 'TRANSCRIPTION_FAILED', expiresAt, new Date().toISOString(), chunk.user_id, chunk.source_id);
    } else {
      try {
        tempAudio.unlinkStrict(chunk.temporary_path);
        db.prepare("UPDATE audio_chunks SET state='reupload_required',temporary_path=NULL,error_code=?,error_message=?,updated_at=? WHERE id=?")
          .run(error.code || 'TRANSCRIPTION_FAILED', String(error.message).slice(0, 500), new Date().toISOString(), chunk.id);
      } catch (cleanupError) {
        db.prepare("UPDATE audio_chunks SET state='retryable_failed',error_code='AUDIO_CLEANUP_FAILED',error_message=?,updated_at=? WHERE id=?")
          .run(String(cleanupError.message).slice(0, 500), new Date().toISOString(), chunk.id);
        jobs.enqueue({ userId: chunk.user_id, resourceType: 'audio_chunk', resourceId: chunk.id, type: 'cleanup_chunk_audio', priority: 110 }, db);
      }
    }
  }
}

async function run({ inference, isInferenceReady = () => true, signal }) {
  const workerId = `${os.hostname()}-${process.pid}-${crypto.randomUUID()}`;
  let currentJob = null;
  const heartbeatTimer = setInterval(
    () => heartbeat(workerId, currentJob?.id, isInferenceReady() ? 'ready' : 'not_ready'),
    5_000,
  );
  heartbeat(workerId, null, 'starting');
  try {
    while (!signal.aborted) {
      // Keep non-ASR work moving, but do not lease a transcription job until
      // the inference child has confirmed its models are usable. Leasing it
      // would burn attempts and can eventually make the server delete its only
      // audio copy even though no inference was ever possible.
      currentJob = jobs.claimNext(workerId, undefined, isInferenceReady());
      if (!currentJob) { await new Promise((resolve) => setTimeout(resolve, 500)); continue; }
      const leaseTimer = setInterval(() => jobs.renewLease(currentJob.id, workerId), 30_000);
      try {
        const handler = handlerFor(currentJob.type);
        await handler.handle(currentJob, inference);
        jobs.complete(currentJob.id, workerId);
      } catch (error) {
        logger.error('Job failed', { jobId: currentJob.id, type: currentJob.type, error });
        const willRetry = jobs.fail(currentJob.id, workerId, error, error.retryable !== false);
        markChunkFailure(currentJob, error, willRetry);
      } finally { clearInterval(leaseTimer); currentJob = null; }
    }
  } finally { clearInterval(heartbeatTimer); getDatabase().prepare('DELETE FROM worker_heartbeats WHERE worker_id=?').run(workerId); }
}

module.exports = { run, handlerFor, markChunkFailure };
