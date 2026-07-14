'use strict';

const { getDatabase } = require('../../db/database');

const terminalStates = new Set(['transcribed', 'silent']);

function receipt(row) {
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
  return base;
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

module.exports = { terminalStates, receipt, findForUser, completeTerminal };
