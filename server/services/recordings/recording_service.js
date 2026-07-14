'use strict';

const fs = require('node:fs');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { pageLimit, encodeCursor, decodeCursor } = require('../../utils/pagination');
const searchIndex = require('../../embeddings/search_index_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('recordings');

function meanTurnEmbedding(rows) {
  if (!rows.length) return null;
  const first = new Float32Array(rows[0].embedding.buffer, rows[0].embedding.byteOffset, rows[0].embedding.byteLength / 4);
  const mean = new Float32Array(first.length);
  let included = 0;
  for (const row of rows) {
    const vector = new Float32Array(row.embedding.buffer, row.embedding.byteOffset, row.embedding.byteLength / 4);
    if (vector.length !== mean.length) continue;
    included += 1;
    for (let index = 0; index < mean.length; index += 1) mean[index] += vector[index];
  }
  if (!included) return null;
  for (let index = 0; index < mean.length; index += 1) mean[index] /= included;
  return Buffer.from(mean.buffer);
}

function dateInTimezone(iso, timezone) {
  const parts = new Intl.DateTimeFormat('en', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' })
    .formatToParts(new Date(iso)).reduce((result, part) => ({ ...result, [part.type]: part.value }), {});
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function removeDerivedData(database, userId, session) {
  const segments = database.prepare(`SELECT t.id,t.conversation_id FROM transcript_segments t
    JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?`).all(session.id, userId);
  const segmentIds = segments.map((row) => row.id);
  const conversationIds = [...new Set(segments.map((row) => row.conversation_id).filter(Boolean))];
  const memories = database.prepare(`SELECT DISTINCT m.id FROM memories m JOIN memory_sources ms ON ms.memory_id=m.id
    WHERE m.user_id=? AND (
      ms.segment_id IN (SELECT t.id FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?)
      OR ms.conversation_id IN (SELECT DISTINCT t.conversation_id FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
        WHERE c.session_id=? AND t.user_id=? AND t.conversation_id IS NOT NULL)
    )`).all(userId, session.id, userId, session.id, userId);
  const memoryIds = memories.map((row) => row.id);
  const miniIds = memoryIds.length
    ? database.prepare(`SELECT id FROM mini_memories WHERE user_id=? AND memory_id IN (${memoryIds.map(() => '?').join(',')})`).all(userId, ...memoryIds).map((row) => row.id)
    : [];
  const coverageEnd = session.corrected_ended_at || database.prepare(`SELECT MAX(t.ended_at) ended_at FROM transcript_segments t
    JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?`).get(session.id, userId).ended_at || session.corrected_started_at;
  const summaries = database.prepare('SELECT * FROM daily_summaries WHERE user_id=?').all(userId).filter((summary) => {
    const overlapsCoverage = summary.coverage_started_at && summary.coverage_ended_at &&
      summary.coverage_started_at <= coverageEnd && summary.coverage_ended_at >= session.corrected_started_at;
    const startDate = dateInTimezone(session.corrected_started_at, summary.timezone);
    const endDate = dateInTimezone(coverageEnd, summary.timezone);
    return overlapsCoverage || (summary.local_date >= startDate && summary.local_date <= endDate);
  });
  searchIndex.removeBySources(database, userId, [
    ...segmentIds.map((sourceId) => ({ kind: 'segment', sourceId })),
    ...memoryIds.map((sourceId) => ({ kind: 'memory', sourceId })),
    ...miniIds.map((sourceId) => ({ kind: 'mini_memory', sourceId })),
    ...summaries.map((row) => ({ kind: 'daily_summary', sourceId: row.id })),
  ]);
  if (memoryIds.length) database.prepare(`DELETE FROM memories WHERE user_id=? AND id IN (${memoryIds.map(() => '?').join(',')})`).run(userId, ...memoryIds);
  for (const summary of summaries) database.prepare('DELETE FROM daily_summaries WHERE id=? AND user_id=?').run(summary.id, userId);
  for (const conversationId of conversationIds) database.prepare('DELETE FROM conversations WHERE id=? AND user_id=?').run(conversationId, userId);
  database.prepare(`DELETE FROM entities WHERE user_id=? AND id NOT IN (SELECT entity_id FROM memory_entities)
    AND id NOT IN (SELECT entity_id FROM mini_memory_entities) AND id NOT IN (SELECT entity_id FROM voiceprints WHERE entity_id IS NOT NULL)`).run(userId);
}

function rebuildAffectedVoiceprints(database, userId, sessionId) {
  const affected = database.prepare(`SELECT DISTINCT st.voiceprint_id FROM speaker_turns st JOIN audio_chunks c ON c.id=st.chunk_id
    WHERE c.session_id=? AND st.user_id=? AND st.voiceprint_id IS NOT NULL`).all(sessionId, userId);
  for (const { voiceprint_id: voiceprintId } of affected) {
    const remaining = database.prepare(`SELECT st.embedding FROM speaker_turns st JOIN audio_chunks c ON c.id=st.chunk_id
      WHERE st.voiceprint_id=? AND st.user_id=? AND c.session_id<>? AND st.embedding IS NOT NULL`).all(voiceprintId, userId, sessionId);
    const centroid = meanTurnEmbedding(remaining);
    if (centroid) database.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`).run(centroid, remaining.length, voiceprintId, userId);
    else database.prepare('DELETE FROM voiceprints WHERE id=? AND user_id=?').run(voiceprintId, userId);
  }
}

function list(userId, query = {}) {
  const limit = pageLimit(query.limit);
  const cursor = decodeCursor(query.cursor);
  const rows = getDatabase().prepare(`SELECT r.*,
    (SELECT COUNT(*) FROM audio_chunks c WHERE c.session_id=r.id) chunk_count,
    (SELECT COUNT(*) FROM transcript_segments t WHERE t.chunk_id IN (SELECT id FROM audio_chunks WHERE session_id=r.id)) segment_count
    FROM recording_sessions r WHERE r.user_id=? AND (? IS NULL OR r.corrected_started_at < ?)
    ORDER BY r.corrected_started_at DESC,r.id DESC LIMIT ?`).all(userId, cursor?.startedAt || null, cursor?.startedAt || null, limit + 1);
  const more = rows.length > limit;
  const items = rows.slice(0, limit);
  return { items, nextCursor: more ? encodeCursor({ startedAt: items.at(-1).corrected_started_at }) : null };
}

function get(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM recording_sessions WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Recording not found.');
  return { ...row, sources: getDatabase().prepare('SELECT * FROM recording_sources WHERE session_id=? ORDER BY created_at').all(id), gaps: getDatabase().prepare('SELECT * FROM recording_gaps WHERE session_id=? ORDER BY start_offset_ms').all(id) };
}

function transcript(userId, id, query = {}) {
  get(userId, id);
  const limit = pageLimit(query.limit, 250, 100);
  const cursor = Number(query.cursor || 0);
  const segments = getDatabase().prepare(`SELECT t.*,v.display_name voiceprint_name,cs.local_label
    FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
    LEFT JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id AND st.start_ms<=t.chunk_start_ms AND st.end_ms>=t.chunk_end_ms
    LEFT JOIN voiceprints v ON v.id=st.voiceprint_id
    LEFT JOIN conversation_speakers cs ON cs.conversation_id=t.conversation_id AND cs.cluster_id=t.speaker_cluster_id
    WHERE c.session_id=? AND t.user_id=? AND t.id>? ORDER BY t.id LIMIT ?`).all(id, userId, cursor, limit + 1);
  const more = segments.length > limit;
  return { items: segments.slice(0, limit), nextCursor: more ? String(segments[limit - 1].id) : null };
}

function remove(userId, id) {
  const session = get(userId, id);
  const db = getDatabase();
  const temporaryFiles = db.prepare('SELECT temporary_path FROM audio_chunks WHERE session_id=? AND user_id=? AND temporary_path IS NOT NULL').all(id, userId);
  db.transaction(() => {
    removeDerivedData(db, userId, session);
    rebuildAffectedVoiceprints(db, userId, id);
    db.prepare(`UPDATE jobs SET status='cancelled',lease_owner=NULL,lease_expires_at=NULL,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE user_id=? AND status IN ('queued','leased') AND resource_id IN (SELECT id FROM audio_chunks WHERE session_id=?)`).run(userId, id);
    db.prepare('DELETE FROM recording_sessions WHERE id=? AND user_id=?').run(id, userId);
  })();
  for (const row of temporaryFiles) {
    try { fs.unlinkSync(row.temporary_path); } catch (error) {
      if (error.code !== 'ENOENT') logger.error('Recording was deleted but a temporary audio file needs sweep cleanup', { error, path: row.temporary_path });
    }
  }
}

module.exports = { list, get, transcript, remove };
