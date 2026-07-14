'use strict';

const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { pageLimit } = require('../../utils/pagination');
const searchIndex = require('../../embeddings/search_index_service');

function memoryDetail(userId, id) {
  const memory = getDatabase().prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!memory) throw new HttpError(404, 'NOT_FOUND', 'Memory not found.');
  const db = getDatabase();
  return {
    ...memory,
    topics: db.prepare('SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic').all(memory.id).map((row) => row.topic),
    miniMemories: db.prepare('SELECT * FROM mini_memories WHERE memory_id=? AND user_id=? ORDER BY id').all(memory.id, userId),
    entities: db.prepare(`SELECT e.*,me.role FROM memory_entities me JOIN entities e ON e.id=me.entity_id
      WHERE me.memory_id=? AND e.user_id=? ORDER BY e.canonical_name_en`).all(memory.id, userId),
    sources: db.prepare(`SELECT ms.conversation_id,ts.public_id segment_id,ts.started_at,ts.ended_at,ts.text
      FROM memory_sources ms LEFT JOIN transcript_segments ts ON ts.id=ms.segment_id
      WHERE ms.memory_id=?`).all(memory.id),
  };
}

function list(userId, query = {}) {
  const conditions = ['m.user_id=?'];
  const parameters = [userId];
  if (query.type) { conditions.push('m.type=?'); parameters.push(query.type); }
  if (query.from) { conditions.push('m.ended_at>=?'); parameters.push(query.from); }
  if (query.to) { conditions.push('m.started_at<=?'); parameters.push(query.to); }
  if (query.pinned !== undefined) { conditions.push('m.pinned=?'); parameters.push(query.pinned ? 1 : 0); }
  if (query.archived !== undefined) { conditions.push('m.archived=?'); parameters.push(query.archived ? 1 : 0); }
  if (query.topic) { conditions.push('EXISTS (SELECT 1 FROM memory_topics mt WHERE mt.memory_id=m.id AND mt.topic=? COLLATE NOCASE)'); parameters.push(query.topic); }
  if (query.entity) { conditions.push('EXISTS (SELECT 1 FROM memory_entities me WHERE me.memory_id=m.id AND me.entity_id=?)'); parameters.push(query.entity); }
  const items = getDatabase().prepare(`SELECT m.* FROM memories m WHERE ${conditions.join(' AND ')}
    ORDER BY m.started_at DESC,m.id DESC LIMIT ?`).all(...parameters, pageLimit(query.limit));
  return { items };
}

function update(userId, id, changes) {
  const memory = memoryDetail(userId, id);
  const allowedTypes = ['meeting', 'conversation', 'project_discussion', 'introduction', 'decision', 'experience', 'other'];
  if (changes.type !== undefined && !allowedTypes.includes(changes.type)) throw new HttpError(400, 'INVALID_MEMORY_TYPE', 'Memory type is invalid.');
  if (changes.importanceOverride !== undefined && changes.importanceOverride !== null && (changes.importanceOverride < 1 || changes.importanceOverride > 10)) throw new HttpError(400, 'INVALID_IMPORTANCE', 'Importance must be from 1 to 10.');
  getDatabase().prepare(`UPDATE memories SET type=COALESCE(?,type),importance_override=?,pinned=COALESCE(?,pinned),
    archived=COALESCE(?,archived),updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`)
    .run(changes.type ?? null, changes.importanceOverride === undefined ? memory.importance_override : changes.importanceOverride,
      changes.pinned === undefined ? null : Number(changes.pinned), changes.archived === undefined ? null : Number(changes.archived), memory.id, userId);
  return memoryDetail(userId, id);
}

function remove(userId, id) {
  const memory = memoryDetail(userId, id);
  const db = getDatabase();
  db.transaction(() => {
    const miniIds = db.prepare('SELECT id FROM mini_memories WHERE memory_id=? AND user_id=?').all(memory.id, userId);
    searchIndex.removeBySources(db, userId, [
      { kind: 'memory', sourceId: memory.id },
      ...miniIds.map((row) => ({ kind: 'mini_memory', sourceId: row.id })),
    ]);
    db.prepare('DELETE FROM memories WHERE id=? AND user_id=?').run(memory.id, userId);
  })();
}

function listMini(userId, query = {}) {
  const conditions = ['user_id=?'];
  const parameters = [userId];
  if (query.kind) { conditions.push('kind=?'); parameters.push(query.kind); }
  if (query.status) { conditions.push('status=?'); parameters.push(query.status); }
  if (query.entity) { conditions.push('EXISTS (SELECT 1 FROM mini_memory_entities mme WHERE mme.mini_memory_id=mini_memories.id AND mme.entity_id=?)'); parameters.push(query.entity); }
  return { items: getDatabase().prepare(`SELECT * FROM mini_memories WHERE ${conditions.join(' AND ')} ORDER BY created_at DESC LIMIT ?`).all(...parameters, pageLimit(query.limit)) };
}

function miniByPublicId(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM mini_memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Mini-memory not found.');
  return row;
}

function updateMini(userId, id, changes) {
  const row = miniByPublicId(userId, id);
  if (changes.status !== undefined && !['open', 'completed', 'cancelled'].includes(changes.status)) throw new HttpError(400, 'INVALID_STATUS', 'Status is invalid.');
  if (changes.importanceOverride !== undefined && changes.importanceOverride !== null && (changes.importanceOverride < 1 || changes.importanceOverride > 10)) throw new HttpError(400, 'INVALID_IMPORTANCE', 'Importance must be from 1 to 10.');
  getDatabase().prepare(`UPDATE mini_memories SET status=COALESCE(?,status),importance_override=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=? AND user_id=?`).run(changes.status ?? null, changes.importanceOverride === undefined ? row.importance_override : changes.importanceOverride, row.id, userId);
  return miniByPublicId(userId, id);
}

function removeMini(userId, id) {
  const row = miniByPublicId(userId, id);
  const db = getDatabase();
  db.transaction(() => {
    searchIndex.removeBySources(db, userId, [{ kind: 'mini_memory', sourceId: row.id }]);
    db.prepare('DELETE FROM mini_memories WHERE id=? AND user_id=?').run(row.id, userId);
  })();
}

function dailySummaries(userId, query = {}) {
  return { items: getDatabase().prepare(`SELECT * FROM daily_summaries WHERE user_id=? AND (? IS NULL OR local_date>=?) AND (? IS NULL OR local_date<=?)
    ORDER BY local_date DESC LIMIT ?`).all(userId, query.from || null, query.from || null, query.to || null, query.to || null, pageLimit(query.limit)) };
}

module.exports = { memoryDetail, list, update, remove, listMini, updateMini, removeMini, dailySummaries };
