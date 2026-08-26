'use strict';

const { getDatabase } = require('../../db/database');
const searchIndex = require('../../embeddings/search_index_service');
const { MINI_MEMORY_MAX_COUNT } = require('../../ai/schemas/consolidation_schema');
const processingSettings = require('../settings/processing_settings_service');

function sourceSessionIds(database, memoryId) {
  return database.prepare(`SELECT DISTINCT ac.session_id
    FROM memory_sources ms
    JOIN transcript_segments ts ON ts.id=ms.segment_id
    JOIN audio_chunks ac ON ac.id=ts.chunk_id
    WHERE ms.memory_id=? AND ms.segment_id IS NOT NULL`).all(memoryId).map((row) => row.session_id);
}

// Existing cards the consolidation model may decide the new material continues.
//
// Candidate selection only keeps the prompt bounded; it never decides a merge.
// Same-stream cards remain eligible across provisional boundaries, while cards
// from another recording stream are eligible only across the same configured
// hard gap used by conversation detection. The model receives timestamps,
// stream overlap and semantics and makes the actual same-occasion decision.
function findCandidates(userId, conversations, database = getDatabase(), options = processingSettings.get()) {
  if (!conversations.length || options.maxMemoryContinuationCandidates <= 0) return [];
  const inputSessionIds = [...new Set(conversations.map((conversation) => conversation.sessionId).filter(Boolean))];
  const firstStartedAt = conversations.reduce((earliest, conversation) => (
    !earliest || Date.parse(conversation.startedAt) < Date.parse(earliest) ? conversation.startedAt : earliest
  ), null);
  const recentCutoff = new Date(Date.parse(firstStartedAt) - options.conversationHardGapMs).toISOString();
  const sameStreamClause = inputSessionIds.length ? ` OR EXISTS (
    SELECT 1 FROM memory_sources ms
    JOIN transcript_segments ts ON ts.id=ms.segment_id
    JOIN audio_chunks ac ON ac.id=ts.chunk_id
    WHERE ms.memory_id=m.id AND ms.segment_id IS NOT NULL
      AND ac.session_id IN (${inputSessionIds.map(() => '?').join(',')})
  )` : '';
  // A card the reader put away is not offered as somewhere to file new
  // material: hiding fresh recordings inside an archived card is worse than a
  // second card they can see and put away themselves.
  const rows = database.prepare(`SELECT m.* FROM memories m
    WHERE m.user_id=? AND m.archived=0 AND m.ended_at<=? AND (m.ended_at>=?${sameStreamClause})
    ORDER BY m.ended_at DESC,m.id DESC LIMIT ?`).all(
    userId,
    firstStartedAt,
    recentCutoff,
    ...inputSessionIds,
    options.maxMemoryContinuationCandidates,
  );
  return rows.map((row) => ({
    publicId: row.public_id,
    type: row.type,
    titleEn: row.title_en,
    summaryEn: row.summary_en,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    topics: database.prepare('SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic')
      .all(row.id).map((item) => item.topic),
    highlights: database.prepare(`SELECT kind,text_en textEn FROM mini_memories
      WHERE memory_id=? AND user_id=? ORDER BY importance DESC,id DESC LIMIT ?`)
      .all(row.id, userId, MINI_MEMORY_MAX_COUNT),
    sessionIds: sourceSessionIds(database, row.id),
  }));
}

// Keep only claims that can be acted on.
//
// A claim is the model's answer to "is this the same occasion", and the answer
// is worth acting on only when it names a card that was actually offered. An
// id that was never a candidate, or a card two output memories both claim,
// says nothing about the material itself — so the claim is dropped and the
// material becomes its own card, which is exactly what would have happened
// without the feature. Failing the run instead would put real recordings on
// the path to being set aside over a slip in one field.
function resolveClaims(memories, candidates) {
  const allowed = new Set(candidates.map((candidate) => candidate.publicId));
  const claimed = new Set();
  const dropped = { unknown: 0, duplicate: 0 };
  for (const memory of memories) {
    const kept = [];
    for (const id of memory.continuesMemoryIds || []) {
      if (!allowed.has(id)) { dropped.unknown += 1; continue; }
      if (claimed.has(id)) { dropped.duplicate += 1; continue; }
      claimed.add(id);
      kept.push(id);
    }
    memory.continuesMemoryIds = kept;
  }
  return dropped;
}

// Move one card's relations onto another without ever attaching the same
// thing twice.
//
// `INSERT OR IGNORE` cannot be relied on here: memory_sources carries a NULL
// in whichever of its two reference columns does not apply, and SQLite treats
// NULLs as distinct in a UNIQUE index, so the same piece of evidence would be
// attached again and the card would show that line twice. `IS` compares NULLs
// as equal, which is what "already attached" means.
function copyRelations(database, table, columns, targetId, absorbedId) {
  const names = columns.join(',');
  const selected = columns.map((column) => column === 'memory_id' ? '?' : `source.${column}`).join(',');
  const matches = columns.filter((column) => column !== 'memory_id')
    .map((column) => `existing.${column} IS source.${column}`).join(' AND ');
  database.prepare(`INSERT INTO ${table} (${names})
    SELECT ${selected} FROM ${table} source
    WHERE source.memory_id=?
      AND NOT EXISTS (SELECT 1 FROM ${table} existing WHERE existing.memory_id=? AND ${matches})`)
    .run(targetId, absorbedId, targetId);
}

// Fold already-persisted fragments into their oldest card inside the caller's
// transaction. Raw transcript rows are never changed or discarded.
function absorbClaimed(database, userId, publicIds) {
  const ids = [...new Set(publicIds || [])];
  if (!ids.length) return null;
  const rows = database.prepare(`SELECT * FROM memories WHERE user_id=?
    AND public_id IN (${ids.map(() => '?').join(',')})`).all(userId, ...ids);
  if (rows.length !== ids.length) {
    throw Object.assign(new Error('A continuation candidate changed before consolidation was persisted.'), {
      code: 'CONSOLIDATION_INPUT_CHANGED', retryable: false,
    });
  }
  rows.sort((left, right) => {
    const time = Date.parse(left.started_at) - Date.parse(right.started_at);
    return time || left.id - right.id;
  });
  const target = rows[0];
  const absorbed = rows.slice(1);
  for (const memory of absorbed) {
    database.prepare(`UPDATE mini_memories SET memory_id=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE memory_id=? AND user_id=?`)
      .run(target.id, memory.id, userId);
    copyRelations(database, 'memory_topics', ['memory_id', 'topic'], target.id, memory.id);
    copyRelations(database, 'memory_entities', ['memory_id', 'entity_id', 'role'], target.id, memory.id);
    copyRelations(database, 'memory_sources', ['memory_id', 'conversation_id', 'segment_id'], target.id, memory.id);
    const contextLinks = database.prepare('SELECT context_item_id,used_by_ai FROM memory_context_sources WHERE memory_id=?').all(memory.id);
    const insertContext = database.prepare(`INSERT INTO memory_context_sources (memory_id,context_item_id,used_by_ai)
      VALUES (?,?,?) ON CONFLICT(memory_id,context_item_id) DO UPDATE SET used_by_ai=MAX(used_by_ai,excluded.used_by_ai)`);
    for (const item of contextLinks) insertContext.run(target.id, item.context_item_id, item.used_by_ai);
    database.prepare(`UPDATE recording_context_items SET memory_id=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE memory_id=? AND user_id=?`)
      .run(target.id, memory.id, userId);
  }
  if (absorbed.length) {
    searchIndex.removeBySources(database, userId, absorbed.map((memory) => ({ kind: 'memory', sourceId: memory.id })));
    const remove = database.prepare('DELETE FROM memories WHERE id=? AND user_id=?');
    for (const memory of absorbed) remove.run(memory.id, userId);
  }
  return {
    target,
    absorbed,
    startedAt: rows.reduce((earliest, memory) => (
      Date.parse(memory.started_at) < Date.parse(earliest) ? memory.started_at : earliest
    ), target.started_at),
    endedAt: rows.reduce((latest, memory) => (
      Date.parse(memory.ended_at) > Date.parse(latest) ? memory.ended_at : latest
    ), target.ended_at),
    pinned: rows.some((memory) => Number(memory.pinned) === 1) ? 1 : 0,
    // A card archived between selection and persistence stays archived.
    archived: Number(target.archived) === 1 ? 1 : 0,
  };
}

module.exports = { findCandidates, resolveClaims, absorbClaimed };
