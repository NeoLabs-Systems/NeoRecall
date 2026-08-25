'use strict';

const { getDatabase } = require('../../db/database');

const terminalStates = new Set(['transcribed', 'silent']);

function processingEstimateContext(database = getDatabase()) {
  const metric = database.prepare(`SELECT AVG(value) average FROM (
    SELECT value FROM processing_metrics
    WHERE metric='transcription_pipeline_rtf' AND value > 0
    ORDER BY created_at DESC LIMIT 100
  )`).get();
  const rtf = metric?.average == null ? null : Number(metric.average);
  const rows = database.prepare(`SELECT j.resource_id,j.status,j.started_at,c.duration_ms
    FROM jobs j JOIN audio_chunks c ON c.id=j.resource_id
    WHERE j.type='transcribe_chunk' AND j.status IN ('queued','leased')
    ORDER BY CASE WHEN j.status='leased' THEN 0 ELSE 1 END,
      j.priority DESC,j.created_at ASC`).all();
  const estimates = new Map();
  let cumulativeMs = 0;
  const now = Date.now();
  rows.forEach((job, index) => {
    if (rtf != null && Number.isFinite(rtf)) {
      const expectedMs = Math.max(0, Number(job.duration_ms) * rtf);
      const elapsedMs = job.status === 'leased' && job.started_at
        ? Math.max(0, now - Date.parse(job.started_at)) : 0;
      cumulativeMs += Math.max(0, expectedMs - elapsedMs);
    }
    estimates.set(job.resource_id, {
      queuePosition: job.status === 'leased' ? 0 : index,
      estimatedRemainingMs: rtf != null && Number.isFinite(rtf) ? Math.ceil(cumulativeMs) : undefined,
      estimateBasis: rtf != null && Number.isFinite(rtf) ? 'observed_transcription_rtf' : undefined,
    });
  });
  return estimates;
}

function receipt(row, estimateContext = null) {
  if (!row) return null;
  const base = {
    chunkId: row.id,
    sourceId: row.source_id,
    sequence: row.sequence,
    state: row.state,
    receiptVersion: row.receipt_version,
    errorCode: row.error_code || undefined,
  };
  if (terminalStates.has(row.state)) {
    return {
      ...base,
      transcriptSegmentCount: row.transcript_segment_count,
      transcriptSha256: row.transcript_sha256,
      persistedAt: row.persisted_at,
      serverAudioDeletedAt: row.server_deleted_at,
    };
  }
  const estimate = (estimateContext || processingEstimateContext()).get(row.id);
  return estimate ? { ...base, ...estimate } : base;
}

function findForUser(userId, chunkId) {
  return receipt(getDatabase().prepare('SELECT * FROM audio_chunks WHERE id=? AND user_id=?').get(chunkId, userId));
}

function completeTerminal(database, chunkId, state, serverDeletedAt = new Date().toISOString()) {
  if (!terminalStates.has(state)) throw new Error(`Invalid terminal receipt state: ${state}`);
  const row = database.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
  if (!row || row.state !== 'persisted_cleanup_pending' || !row.persisted_at || row.temporary_path) {
    throw new Error('A terminal receipt requires persisted transcript state and an absent temporary path.');
  }
  database.prepare(`UPDATE audio_chunks SET state=?,server_deleted_at=?,receipt_version=receipt_version+1,
    updated_at=? WHERE id=?`).run(state, serverDeletedAt, serverDeletedAt, chunkId);
  return receipt(database.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId));
}

module.exports = { terminalStates, receipt, findForUser, completeTerminal, processingEstimateContext };
