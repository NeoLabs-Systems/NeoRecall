'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { pageLimit } = require('../../utils/pagination');
const { queryBoolean, Conditions } = require('../../utils/query');
const searchIndex = require('../../embeddings/search_index_service');
const ai = require('../../ai/ai_engine');
const aiProviders = require('../../ai/provider_registry');
const jobs = require('../jobs/job_service');
const {
  defaultEmojiForType, MEMORY_TYPES, TITLE_MAX_LENGTH, SUMMARY_MAX_LENGTH,
} = require('../../ai/schemas/consolidation_schema');

const ALLOWED_TYPES = new Set(MEMORY_TYPES);
const BULK_ACTIONS = new Set(['delete', 'pin', 'unpin', 'archive', 'unarchive']);
const MERGE_MIN = 2;
const MERGE_REWRITE_PRIORITY = 60;

function presentMemory(row) {
  if (!row) return row;
  const topics = row.topics_csv
    ? String(row.topics_csv).split('||').filter(Boolean)
    : Array.isArray(row.topics) ? row.topics : undefined;
  const presented = {
    ...row,
    emoji: row.emoji || defaultEmojiForType(row.type),
    pinned: Boolean(row.pinned),
    archived: Boolean(row.archived),
  };
  delete presented.topics_csv;
  if (topics !== undefined) presented.topics = topics;
  if (row.mini_count !== undefined) presented.mini_count = Number(row.mini_count);
  return presented;
}

function presentMini(row) {
  if (!row) return row;
  return {
    ...row,
    pinned: row.pinned === undefined ? undefined : Boolean(row.pinned),
  };
}

function memoryDetail(userId, id) {
  const memory = getDatabase().prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!memory) throw new HttpError(404, 'NOT_FOUND', 'Memory not found.');
  const db = getDatabase();
  return presentMemory({
    ...memory,
    topics: db.prepare('SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic').all(memory.id).map((row) => row.topic),
    miniMemories: db.prepare('SELECT * FROM mini_memories WHERE memory_id=? AND user_id=? ORDER BY id').all(memory.id, userId),
    entities: db.prepare(`SELECT e.*,me.role FROM memory_entities me JOIN entities e ON e.id=me.entity_id
      WHERE me.memory_id=? AND e.user_id=? ORDER BY e.canonical_name_en`).all(memory.id, userId),
    // Segment-backed sources only — conversation-only rows have null text and
    // are not useful in the "relevant transcript" detail pane.
    sources: db.prepare(`SELECT ts.public_id segment_id,ts.started_at,ts.ended_at,ts.text,ts.conversation_id
      FROM memory_sources ms
      JOIN transcript_segments ts ON ts.id=ms.segment_id
      WHERE ms.memory_id=? AND ms.segment_id IS NOT NULL
      ORDER BY ts.started_at ASC`).all(memory.id),
  });
}

function list(userId, query = {}) {
  const where = new Conditions('m.user_id=?');
  where.parameters.push(userId);
  where.when(query.type, 'm.type=?', query.type);
  where.when(query.from, 'm.ended_at>=?', query.from);
  where.when(query.to, 'm.started_at<=?', query.to);
  // Default to active memories so the consumer list is not cluttered with
  // archived items. Pass archived=all for a full inventory (e.g. client-side
  // filter chips that include an Archived view).
  if (query.archived === undefined || query.archived === '' || query.archived === 'false' || query.archived === '0') {
    where.always('m.archived=0');
  } else if (query.archived !== 'all') {
    where.always('m.archived=?', queryBoolean(query.archived) ? 1 : 0);
  }
  if (query.pinned !== undefined) where.always('m.pinned=?', queryBoolean(query.pinned) ? 1 : 0);
  where.when(query.topic, 'EXISTS (SELECT 1 FROM memory_topics mt WHERE mt.memory_id=m.id AND mt.topic=? COLLATE NOCASE)', query.topic);
  where.when(query.entity, 'EXISTS (SELECT 1 FROM memory_entities me WHERE me.memory_id=m.id AND me.entity_id=?)', query.entity);
  if (query.q) {
    const needle = `%${String(query.q).trim()}%`;
    where.always('(m.title_en LIKE ? COLLATE NOCASE OR m.summary_en LIKE ? COLLATE NOCASE)', needle, needle);
  }
  const items = getDatabase().prepare(`SELECT m.*,
      (SELECT COUNT(*) FROM mini_memories mm WHERE mm.memory_id=m.id) AS mini_count,
      (SELECT GROUP_CONCAT(mt.topic, '||') FROM memory_topics mt WHERE mt.memory_id=m.id) AS topics_csv
    FROM memories m WHERE ${where.sql}
    ORDER BY m.pinned DESC, m.started_at DESC, m.id DESC LIMIT ?`).all(...where.parameters, pageLimit(query.limit));
  return { items: items.map(presentMemory) };
}

function update(userId, id, changes) {
  const memory = getDatabase().prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!memory) throw new HttpError(404, 'NOT_FOUND', 'Memory not found.');
  if (changes.type !== undefined && !ALLOWED_TYPES.has(changes.type)) {
    throw new HttpError(400, 'INVALID_MEMORY_TYPE', 'Memory type is invalid.');
  }
  if (changes.importanceOverride !== undefined && changes.importanceOverride !== null
    && (changes.importanceOverride < 1 || changes.importanceOverride > 10)) {
    throw new HttpError(400, 'INVALID_IMPORTANCE', 'Importance must be from 1 to 10.');
  }
  if (changes.titleEn !== undefined) {
    const title = String(changes.titleEn).trim();
    if (!title || title.length > 160) throw new HttpError(400, 'INVALID_TITLE', 'Title must be 1–160 characters.');
  }
  if (changes.emoji !== undefined) {
    const emoji = String(changes.emoji).trim();
    if (!emoji || emoji.length > 16) throw new HttpError(400, 'INVALID_EMOJI', 'Emoji must be 1–16 characters.');
  }
  // Wording the reader chose is marked as theirs, so a later run that extends
  // the same occasion adds to the card without renaming it back.
  const editsProse = changes.type !== undefined || changes.titleEn !== undefined || changes.emoji !== undefined;
  getDatabase().prepare(`UPDATE memories SET
    type=COALESCE(?,type),
    title_en=COALESCE(?,title_en),
    emoji=COALESCE(?,emoji),
    importance_override=?,
    pinned=COALESCE(?,pinned),
    archived=COALESCE(?,archived),
    prose_edited_at=CASE WHEN ? THEN strftime('%Y-%m-%dT%H:%M:%fZ','now') ELSE prose_edited_at END,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=? AND user_id=?`)
    .run(
      changes.type ?? null,
      changes.titleEn === undefined ? null : String(changes.titleEn).trim(),
      changes.emoji === undefined ? null : String(changes.emoji).trim(),
      changes.importanceOverride === undefined ? memory.importance_override : changes.importanceOverride,
      changes.pinned === undefined ? null : Number(changes.pinned),
      changes.archived === undefined ? null : Number(changes.archived),
      Number(editsProse),
      memory.id,
      userId,
    );
  if (changes.titleEn !== undefined) {
    const updated = getDatabase().prepare('SELECT * FROM memories WHERE id=?').get(memory.id);
    searchIndex.upsertDocument({
      userId,
      kind: 'memory',
      sourceId: memory.id,
      title: updated.title_en,
      body: updated.summary_en,
      occurredAt: updated.started_at,
      importance: updated.importance_override ?? updated.importance,
    });
  }
  return memoryDetail(userId, id);
}

function remove(userId, id) {
  const memory = getDatabase().prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!memory) throw new HttpError(404, 'NOT_FOUND', 'Memory not found.');
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

function bulk(userId, { ids, action }) {
  if (!Array.isArray(ids) || ids.length === 0) {
    throw new HttpError(400, 'INVALID_IDS', 'Provide at least one memory id.');
  }
  if (ids.length > 100) throw new HttpError(400, 'TOO_MANY_IDS', 'At most 100 memories per bulk action.');
  if (!BULK_ACTIONS.has(action)) {
    throw new HttpError(400, 'INVALID_ACTION', 'Unsupported bulk action.');
  }
  const uniqueIds = [...new Set(ids.map(String))];
  const db = getDatabase();
  const rows = db.prepare(`SELECT * FROM memories WHERE user_id=? AND public_id IN (${uniqueIds.map(() => '?').join(',')})`)
    .all(userId, ...uniqueIds);
  if (rows.length !== uniqueIds.length) {
    throw new HttpError(404, 'NOT_FOUND', 'One or more memories were not found.');
  }
  if (action === 'delete') {
    db.transaction(() => {
      for (const memory of rows) {
        const miniIds = db.prepare('SELECT id FROM mini_memories WHERE memory_id=? AND user_id=?').all(memory.id, userId);
        searchIndex.removeBySources(db, userId, [
          { kind: 'memory', sourceId: memory.id },
          ...miniIds.map((row) => ({ kind: 'mini_memory', sourceId: row.id })),
        ]);
        db.prepare('DELETE FROM memories WHERE id=? AND user_id=?').run(memory.id, userId);
      }
    })();
    return { action, count: rows.length, ids: uniqueIds };
  }
  const pinned = action === 'pin' ? 1 : action === 'unpin' ? 0 : null;
  const archived = action === 'archive' ? 1 : action === 'unarchive' ? 0 : null;
  db.prepare(`UPDATE memories SET
    pinned=COALESCE(?,pinned),
    archived=COALESCE(?,archived),
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE user_id=? AND public_id IN (${uniqueIds.map(() => '?').join(',')})`)
    .run(pinned, archived, userId, ...uniqueIds);
  return { action, count: rows.length, ids: uniqueIds };
}

function listMini(userId, query = {}) {
  const where = new Conditions('mm.user_id=?');
  where.parameters.push(userId);
  where.when(query.kind, 'mm.kind=?', query.kind);
  where.when(query.status, 'mm.status=?', query.status);
  where.when(query.memoryId, 'm.public_id=?', query.memoryId);
  where.when(query.entity, 'EXISTS (SELECT 1 FROM mini_memory_entities mme WHERE mme.mini_memory_id=mm.id AND mme.entity_id=?)', query.entity);
  if (query.q) where.always('mm.text_en LIKE ? COLLATE NOCASE', `%${String(query.q).trim()}%`);
  // Timeline order: when it happened, then when it is due, then when it was created.
  const items = getDatabase().prepare(`SELECT mm.*,
      m.public_id AS memory_public_id,
      m.title_en AS memory_title_en,
      m.emoji AS memory_emoji,
      m.type AS memory_type,
      COALESCE(mm.occurred_at, mm.due_at, mm.created_at) AS timeline_at
    FROM mini_memories mm
    JOIN memories m ON m.id=mm.memory_id
    WHERE ${where.sql}
    ORDER BY timeline_at DESC, mm.id DESC
    LIMIT ?`).all(...where.parameters, pageLimit(query.limit));
  return {
    items: items.map((row) => {
      const {
        memory_public_id: memoryPublicId,
        memory_title_en: memoryTitleEn,
        memory_emoji: memoryEmoji,
        memory_type: memoryType,
        ...rest
      } = row;
      return presentMini({
        ...rest,
        memory: {
          public_id: memoryPublicId,
          title_en: memoryTitleEn,
          emoji: memoryEmoji || defaultEmojiForType(memoryType),
          type: memoryType,
        },
      });
    }),
  };
}

function miniByPublicId(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM mini_memories WHERE public_id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Mini-memory not found.');
  return row;
}

function miniDetail(userId, id) {
  const row = miniByPublicId(userId, id);
  const db = getDatabase();
  const memory = db.prepare('SELECT public_id,title_en,emoji,type,summary_en,started_at FROM memories WHERE id=? AND user_id=?')
    .get(row.memory_id, userId);
  const sources = db.prepare(`SELECT ts.public_id segment_id,ts.started_at,ts.ended_at,ts.text,ts.conversation_id
    FROM mini_memory_sources mms
    JOIN transcript_segments ts ON ts.id=mms.segment_id
    WHERE mms.mini_memory_id=?
    ORDER BY ts.started_at ASC`).all(row.id);
  const entities = db.prepare(`SELECT e.*,mme.role FROM mini_memory_entities mme
    JOIN entities e ON e.id=mme.entity_id
    WHERE mme.mini_memory_id=? AND e.user_id=?
    ORDER BY e.canonical_name_en`).all(row.id, userId);
  return presentMini({
    ...row,
    memory: memory ? {
      ...memory,
      emoji: memory.emoji || defaultEmojiForType(memory.type),
    } : null,
    sources,
    entities,
  });
}

function updateMini(userId, id, changes) {
  const row = miniByPublicId(userId, id);
  if (changes.status !== undefined && !['open', 'completed', 'cancelled'].includes(changes.status)) {
    throw new HttpError(400, 'INVALID_STATUS', 'Status is invalid.');
  }
  if (changes.importanceOverride !== undefined && changes.importanceOverride !== null
    && (changes.importanceOverride < 1 || changes.importanceOverride > 10)) {
    throw new HttpError(400, 'INVALID_IMPORTANCE', 'Importance must be from 1 to 10.');
  }
  getDatabase().prepare(`UPDATE mini_memories SET status=COALESCE(?,status),importance_override=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=? AND user_id=?`).run(
    changes.status ?? null,
    changes.importanceOverride === undefined ? row.importance_override : changes.importanceOverride,
    row.id,
    userId,
  );
  return miniDetail(userId, id);
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
  return {
    items: getDatabase().prepare(`SELECT * FROM daily_summaries WHERE user_id=? AND (? IS NULL OR local_date>=?) AND (? IS NULL OR local_date<=?)
    ORDER BY local_date DESC LIMIT ?`).all(userId, query.from || null, query.from || null, query.to || null, query.to || null, pageLimit(query.limit)),
  };
}

function loadMemoriesForMerge(userId, ids) {
  const uniqueIds = [...new Set(ids.map(String))];
  const mergeMax = getConfig().memoryMergeMaxItems;
  if (uniqueIds.length < MERGE_MIN) {
    throw new HttpError(400, 'INVALID_MERGE', `Select at least ${MERGE_MIN} memories to merge.`);
  }
  if (uniqueIds.length > mergeMax) {
    throw new HttpError(400, 'INVALID_MERGE', `Merge at most ${mergeMax} memories at once.`);
  }
  const db = getDatabase();
  const rows = db.prepare(`SELECT * FROM memories WHERE user_id=? AND public_id IN (${uniqueIds.map(() => '?').join(',')})`)
    .all(userId, ...uniqueIds);
  if (rows.length !== uniqueIds.length) {
    throw new HttpError(404, 'NOT_FOUND', 'One or more memories were not found.');
  }
  // Chronological survivor keeps the oldest occasion as the merge anchor.
  rows.sort((left, right) => {
    const start = Date.parse(left.started_at) - Date.parse(right.started_at);
    return start !== 0 ? start : left.id - right.id;
  });
  return rows.map((row) => ({
    ...row,
    topics: db.prepare('SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic').all(row.id).map((item) => item.topic),
    miniMemories: db.prepare('SELECT * FROM mini_memories WHERE memory_id=? AND user_id=? ORDER BY id').all(row.id, userId),
    entities: db.prepare('SELECT entity_id, role FROM memory_entities WHERE memory_id=?').all(row.id),
    sources: db.prepare('SELECT conversation_id, segment_id FROM memory_sources WHERE memory_id=?').all(row.id),
  }));
}

function pickDominantType(types) {
  const counts = new Map();
  for (const type of types) counts.set(type, (counts.get(type) || 0) + 1);
  let best = types[0] || 'other';
  let bestCount = 0;
  for (const [type, count] of counts) {
    if (count > bestCount) {
      best = type;
      bestCount = count;
    }
  }
  return ALLOWED_TYPES.has(best) ? best : 'other';
}

function deterministicMergeProse(memories) {
  const type = pickDominantType(memories.map((memory) => memory.type));
  const titles = [...new Set(memories.map((memory) => memory.title_en.trim()).filter(Boolean))];
  let titleEn = titles.join(' · ');
  if (titleEn.length > TITLE_MAX_LENGTH) titleEn = `${titleEn.slice(0, TITLE_MAX_LENGTH - 1).trimEnd()}…`;
  if (!titleEn) titleEn = 'Combined memory';

  const summaries = memories.map((memory) => memory.summary_en.trim()).filter(Boolean);
  let summaryEn = summaries.join('\n\n');
  if (summaryEn.length > SUMMARY_MAX_LENGTH) summaryEn = `${summaryEn.slice(0, SUMMARY_MAX_LENGTH - 1).trimEnd()}…`;
  if (!summaryEn) summaryEn = titleEn;

  const emoji = memories.map((memory) => memory.emoji).find((value) => value && String(value).trim())
    || defaultEmojiForType(type);

  return { type, titleEn, summaryEn, emoji };
}

function rewriteInput(memories) {
  return memories.map((memory) => ({
    type: memory.type,
    title_en: memory.title_en,
    summary_en: memory.summary_en,
    emoji: memory.emoji,
    started_at: memory.started_at,
    ended_at: memory.ended_at,
    topics: memory.topics,
    miniMemories: memory.miniMemories.map((mini) => ({
      kind: mini.kind,
      text_en: mini.text_en,
      status: mini.status,
    })),
  }));
}

function applyStructuralMerge(userId, memories, prose) {
  const db = getDatabase();
  const target = memories[0];
  const absorbed = memories.slice(1);
  const allIds = memories.map((memory) => memory.id);

  const startedAt = memories.reduce((earliest, memory) => (
    !earliest || Date.parse(memory.started_at) < Date.parse(earliest) ? memory.started_at : earliest
  ), null);
  const endedAt = memories.reduce((latest, memory) => (
    !latest || Date.parse(memory.ended_at) > Date.parse(latest) ? memory.ended_at : latest
  ), null);
  const importance = Math.max(...memories.map((memory) => Number(memory.importance_override ?? memory.importance)));
  const pinned = memories.some((memory) => Number(memory.pinned) === 1) ? 1 : 0;
  // Stay archived only when every member was archived; otherwise surface the result.
  const archived = memories.every((memory) => Number(memory.archived) === 1) ? 1 : 0;

  const topics = [...new Set(memories.flatMap((memory) => memory.topics.map((topic) => topic.trim()).filter(Boolean)))];
  const entityKeys = new Map();
  for (const memory of memories) {
    for (const entity of memory.entities) {
      entityKeys.set(`${entity.entity_id}\0${entity.role}`, entity);
    }
  }
  const sourceKeys = new Map();
  for (const memory of memories) {
    for (const source of memory.sources) {
      sourceKeys.set(`${source.conversation_id || ''}\0${source.segment_id || ''}`, source);
    }
  }

  db.transaction(() => {
    db.prepare(`UPDATE memories SET
      type=?, title_en=?, summary_en=?, emoji=?, importance=?, importance_override=NULL,
      started_at=?, ended_at=?, pinned=?, archived=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE id=? AND user_id=?`)
      .run(
        prose.type,
        prose.titleEn,
        prose.summaryEn,
        prose.emoji,
        importance,
        startedAt,
        endedAt,
        pinned,
        archived,
        target.id,
        userId,
      );

    // Re-parent minis before deleting absorbed memories (CASCADE would wipe them).
    const reparent = db.prepare('UPDATE mini_memories SET memory_id=?, updated_at=strftime(\'%Y-%m-%dT%H:%M:%fZ\',\'now\') WHERE memory_id=? AND user_id=?');
    for (const memory of absorbed) reparent.run(target.id, memory.id, userId);

    db.prepare('DELETE FROM memory_topics WHERE memory_id=?').run(target.id);
    const topicInsert = db.prepare('INSERT OR IGNORE INTO memory_topics (memory_id, topic) VALUES (?, ?)');
    for (const topic of topics) topicInsert.run(target.id, topic);

    db.prepare('DELETE FROM memory_entities WHERE memory_id=?').run(target.id);
    const entityInsert = db.prepare('INSERT OR IGNORE INTO memory_entities (memory_id, entity_id, role) VALUES (?, ?, ?)');
    for (const entity of entityKeys.values()) entityInsert.run(target.id, entity.entity_id, entity.role);

    db.prepare('DELETE FROM memory_sources WHERE memory_id=?').run(target.id);
    const sourceInsert = db.prepare('INSERT OR IGNORE INTO memory_sources (memory_id, conversation_id, segment_id) VALUES (?, ?, ?)');
    for (const source of sourceKeys.values()) {
      sourceInsert.run(target.id, source.conversation_id || null, source.segment_id || null);
    }

    const absorbedSearch = absorbed.map((memory) => ({ kind: 'memory', sourceId: memory.id }));
    if (absorbedSearch.length) searchIndex.removeBySources(db, userId, absorbedSearch);

    for (const memory of absorbed) {
      db.prepare('DELETE FROM memories WHERE id=? AND user_id=?').run(memory.id, userId);
    }

    searchIndex.upsertDocument({
      userId,
      kind: 'memory',
      sourceId: target.id,
      title: prose.titleEn,
      body: prose.summaryEn,
      occurredAt: startedAt,
      importance,
    }, db);
  })();

  return {
    targetPublicId: target.public_id,
    absorbedPublicIds: absorbed.map((memory) => memory.public_id),
    memoryIds: allIds,
  };
}

function queueMergedProseRewrite(userId, structural, memories) {
  if (!aiProviders.ready()) return null;
  const target = getDatabase().prepare(`SELECT type,title_en,summary_en,emoji,updated_at
    FROM memories WHERE public_id=? AND user_id=?`)
    .get(structural.targetPublicId, userId);
  if (!target) return null;
  return jobs.enqueue({
    userId,
    resourceType: 'memory',
    // Every merge gets its own durable rewrite. Reusing the target memory as
    // the job resource would collapse a second merge into the first active job.
    resourceId: crypto.randomUUID(),
    type: 'rewrite_merged_memory',
    priority: MERGE_REWRITE_PRIORITY,
    payload: {
      targetPublicId: structural.targetPublicId,
      expectedUpdatedAt: target.updated_at,
      expectedProse: {
        type: target.type,
        titleEn: target.title_en,
        summaryEn: target.summary_en,
        emoji: target.emoji,
      },
      memories: rewriteInput(memories),
    },
  });
}

// Apply the optional prose polish only if the merged card has not changed
// since it was queued. A rename or a later merge always wins over stale AI.
async function rewriteMergedProse(userId, payload) {
  const db = getDatabase();
  const current = db.prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?')
    .get(payload.targetPublicId, userId);
  const expected = payload.expectedProse;
  if (!current || !expected || current.updated_at !== payload.expectedUpdatedAt
    || current.type !== expected.type || current.title_en !== expected.titleEn
    || current.summary_en !== expected.summaryEn || current.emoji !== expected.emoji) {
    return { updated: false };
  }

  const response = await ai.rewriteMergedMemory(userId, payload.memories);
  const prose = {
    type: response.value.type,
    titleEn: response.value.titleEn.trim().slice(0, TITLE_MAX_LENGTH),
    summaryEn: response.value.summaryEn.trim().slice(0, SUMMARY_MAX_LENGTH),
    emoji: response.value.emoji.trim().slice(0, 16) || current.emoji || defaultEmojiForType(response.value.type),
  };
  const updated = db.transaction(() => {
    const changed = db.prepare(`UPDATE memories SET type=?,title_en=?,summary_en=?,emoji=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE public_id=? AND user_id=? AND updated_at=?
        AND type=? AND title_en=? AND summary_en=? AND emoji IS ?`)
      .run(prose.type, prose.titleEn, prose.summaryEn, prose.emoji,
        payload.targetPublicId, userId, payload.expectedUpdatedAt,
        expected.type, expected.titleEn, expected.summaryEn, expected.emoji).changes;
    if (!changed) return false;
    const memory = db.prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?')
      .get(payload.targetPublicId, userId);
    searchIndex.upsertDocument({
      userId,
      kind: 'memory',
      sourceId: memory.id,
      title: prose.titleEn,
      body: prose.summaryEn,
      occurredAt: memory.started_at,
      importance: Number(memory.importance_override ?? memory.importance),
    }, db);
    return true;
  })();
  return { updated, aiRequestId: response.requestId };
}

// Merge evidence and highlights immediately. Optional AI prose polishing is a
// durable worker job, so a slow model never holds the user's request open.
function merge(userId, { ids }) {
  if (!Array.isArray(ids)) throw new HttpError(400, 'INVALID_IDS', 'Provide memory ids to merge.');
  const memories = loadMemoriesForMerge(userId, ids);
  const structural = applyStructuralMerge(userId, memories, deterministicMergeProse(memories));
  const rewriteJobId = queueMergedProseRewrite(userId, structural, memories);
  const detail = memoryDetail(userId, structural.targetPublicId);
  return {
    memory: detail,
    absorbedIds: structural.absorbedPublicIds,
    rewritten: false,
    rewriteQueued: rewriteJobId !== null,
    rewriteJobId,
  };
}

module.exports = {
  memoryDetail, list, update, remove, bulk, merge, rewriteMergedProse,
  listMini, miniDetail, updateMini, removeMini, dailySummaries,
  presentMemory, defaultEmojiForType, deterministicMergeProse,
};
