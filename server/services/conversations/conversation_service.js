'use strict';

const fs = require('node:fs');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { pageLimit } = require('../../utils/pagination');
const searchIndex = require('../../embeddings/search_index_service');
const { PENDING_ID } = require('./timeline_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('conversations');
const BULK_MAX = 100;

function serialize(conversation) {
  if (!conversation) return conversation;
  const result = { ...conversation };
  try {
    result.topics = JSON.parse(result.topics_json || '[]');
  } catch {
    result.topics = [];
  }
  delete result.topics_json;
  // A conversation that is still recording carries a provisional insight, so a
  // client can show what it is about before it ends. memory_worthy is unknown
  // until an insight exists at all.
  result.memory_worthy = result.memory_worthy === null || result.memory_worthy === undefined
    ? null
    : Boolean(result.memory_worthy);
  return result;
}

function list(userId, query = {}) {
  const limit = pageLimit(query.limit);
  const conditions = ['user_id=?'];
  const parameters = [userId];
  if (query.state) { conditions.push('state=?'); parameters.push(query.state); }
  if (query.from) { conditions.push('ended_at>=?'); parameters.push(query.from); }
  if (query.to) { conditions.push('started_at<=?'); parameters.push(query.to); }
  if (query.speaker) {
    conditions.push('EXISTS (SELECT 1 FROM conversation_speakers cs WHERE cs.conversation_id=conversations.id AND (cs.voiceprint_id=? OR cs.cluster_id=?))');
    parameters.push(query.speaker, query.speaker);
  }
  const items = getDatabase().prepare(`SELECT conversations.*,
    (SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
      WHERE ts.conversation_id=conversations.id ORDER BY ts.started_at LIMIT 1) session_id
    FROM conversations WHERE ${conditions.join(' AND ')} ORDER BY started_at DESC LIMIT ?`).all(...parameters, limit);
  return { items: items.map(serialize) };
}

function get(userId, id) {
  const conversation = getDatabase().prepare('SELECT * FROM conversations WHERE id=? AND user_id=?').get(id, userId);
  if (!conversation) throw new HttpError(404, 'NOT_FOUND', 'Conversation not found.');
  return {
    ...serialize(conversation),
    segments: getDatabase().prepare('SELECT * FROM transcript_segments WHERE conversation_id=? AND user_id=? ORDER BY started_at').all(id, userId),
    speakers: getDatabase().prepare('SELECT * FROM conversation_speakers WHERE conversation_id=?').all(id),
  };
}

function placeholders(count) {
  return new Array(count).fill('?').join(',');
}

function unlinkContextOriginals(paths) {
  for (const originalPath of paths) {
    try { fs.unlinkSync(originalPath); } catch (error) {
      if (error.code !== 'ENOENT') {
        logger.error('A moment was deleted but an attached context file needs sweep cleanup', { error, path: originalPath });
      }
    }
  }
}

// Memories whose remaining evidence is entirely inside the conversations and
// segments being removed. A memory that also describes other conversations is
// left in place: deleting it would throw away material nobody asked to erase.
function exclusiveMemories(database, userId, conversationIds, segmentIds) {
  const conversationClause = conversationIds.length
    ? `s.conversation_id IN (${placeholders(conversationIds.length)})`
    : '0';
  const otherConversationClause = conversationIds.length
    ? `s.conversation_id IS NOT NULL AND s.conversation_id NOT IN (${placeholders(conversationIds.length)})`
    : 's.conversation_id IS NOT NULL';
  const segmentClause = segmentIds.length
    ? `s.segment_id IN (${placeholders(segmentIds.length)})`
    : '0';
  const otherSegmentClause = segmentIds.length
    ? `s.segment_id IS NOT NULL AND s.segment_id NOT IN (${placeholders(segmentIds.length)})`
    : 's.segment_id IS NOT NULL';
  return database.prepare(`SELECT m.id FROM memories m
    WHERE m.user_id=? AND EXISTS (
      SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND (${conversationClause} OR ${segmentClause})
    ) AND NOT EXISTS (
      SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND (
        (${otherConversationClause}) OR (${otherSegmentClause})
      )
    )`).all(userId, ...conversationIds, ...segmentIds, ...conversationIds, ...segmentIds);
}

function collectSegments(database, userId, conversationIds, includePending) {
  const rows = [];
  if (conversationIds.length) {
    rows.push(...database.prepare(`SELECT id FROM transcript_segments
      WHERE user_id=? AND conversation_id IN (${placeholders(conversationIds.length)})`)
      .all(userId, ...conversationIds));
  }
  if (includePending) {
    rows.push(...database.prepare(`SELECT id FROM transcript_segments
      WHERE user_id=? AND conversation_id IS NULL`).all(userId));
  }
  return [...new Set(rows.map((row) => row.id))];
}

function bulkRemove(userId, ids) {
  if (!Array.isArray(ids) || ids.length === 0) {
    throw new HttpError(400, 'INVALID_IDS', 'Provide at least one moment id.');
  }
  if (ids.length > BULK_MAX) {
    throw new HttpError(400, 'TOO_MANY_IDS', `At most ${BULK_MAX} moments per bulk action.`);
  }
  const uniqueIds = [...new Set(ids.map(String))];
  const includePending = uniqueIds.includes(PENDING_ID);
  const conversationIds = uniqueIds.filter((id) => id !== PENDING_ID);
  const db = getDatabase();
  if (conversationIds.length) {
    const owned = db.prepare(`SELECT id FROM conversations WHERE user_id=? AND id IN (${placeholders(conversationIds.length)})`)
      .all(userId, ...conversationIds);
    if (owned.length !== conversationIds.length) {
      throw new HttpError(404, 'NOT_FOUND', 'One or more conversations were not found.');
    }
  } else if (!includePending) {
    throw new HttpError(400, 'INVALID_IDS', 'Provide at least one moment id.');
  }

  let contextOriginals = [];
  db.transaction(() => {
    const segmentIds = collectSegments(db, userId, conversationIds, includePending);
    const memories = exclusiveMemories(db, userId, conversationIds, segmentIds);
    const memoryIds = memories.map((row) => row.id);
    const miniIds = memoryIds.length
      ? db.prepare(`SELECT id FROM mini_memories WHERE user_id=? AND memory_id IN (${placeholders(memoryIds.length)})`)
        .all(userId, ...memoryIds).map((row) => row.id)
      : [];
    if (memoryIds.length) {
      contextOriginals = db.prepare(`SELECT original_path FROM recording_context_items
        WHERE user_id=? AND memory_id IN (${placeholders(memoryIds.length)}) AND original_path IS NOT NULL`)
        .all(userId, ...memoryIds).map((row) => row.original_path);
    }
    searchIndex.removeBySources(db, userId, [
      ...segmentIds.map((sourceId) => ({ kind: 'segment', sourceId })),
      ...memoryIds.map((sourceId) => ({ kind: 'memory', sourceId })),
      ...miniIds.map((sourceId) => ({ kind: 'mini_memory', sourceId })),
    ]);
    if (memoryIds.length) {
      db.prepare(`DELETE FROM memories WHERE user_id=? AND id IN (${placeholders(memoryIds.length)})`)
        .run(userId, ...memoryIds);
    }
    if (segmentIds.length) {
      db.prepare(`DELETE FROM transcript_segments WHERE user_id=? AND id IN (${placeholders(segmentIds.length)})`)
        .run(userId, ...segmentIds);
    }
    if (conversationIds.length) {
      db.prepare(`UPDATE jobs SET status='cancelled',lease_owner=NULL,lease_expires_at=NULL,
        updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
        WHERE user_id=? AND status IN ('queued','leased') AND resource_type='conversation'
          AND resource_id IN (${placeholders(conversationIds.length)})`)
        .run(userId, ...conversationIds);
      db.prepare(`DELETE FROM conversations WHERE user_id=? AND id IN (${placeholders(conversationIds.length)})`)
        .run(userId, ...conversationIds);
    }
  })();
  unlinkContextOriginals(contextOriginals);
  return { action: 'delete', count: uniqueIds.length, ids: uniqueIds };
}

function remove(userId, id) {
  bulkRemove(userId, [id]);
  return { success: true };
}

module.exports = { list, get, serialize, remove, bulkRemove };
