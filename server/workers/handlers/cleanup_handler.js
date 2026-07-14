'use strict';

const { getDatabase } = require('../../db/database');
const tempAudio = require('../../services/ingest/temp_audio_service');
const transcribe = require('./transcribe_handler');

async function handle(job) {
  if (job.type === 'sweep_temp_audio') return { removed: tempAudio.sweep() };
  const database = getDatabase();
  const chunk = database.prepare("SELECT * FROM audio_chunks WHERE id=? AND state IN ('persisted_cleanup_pending','retryable_failed')").get(job.resource_id);
  if (!chunk) return { skipped: true };
  if (chunk.state === 'persisted_cleanup_pending') return transcribe.finishCleanup(chunk, chunk.transcript_segment_count || 0);
  tempAudio.unlinkStrict(chunk.temporary_path);
  database.prepare(`UPDATE audio_chunks SET state='reupload_required',temporary_path=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(chunk.id);
  return { state: 'reupload_required' };
}

module.exports = { handle };
