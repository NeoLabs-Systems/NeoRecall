'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const ai = require('../../ai/ai_engine');
const searchIndex = require('../../embeddings/search_index_service');

async function handle(job) {
  const db = getDatabase();
  const memory = db.prepare('SELECT * FROM memories WHERE id=? AND user_id=?').get(Number(job.resource_id), job.user_id);
  if (!memory) return { removed: true };
  const segments = db.prepare(`SELECT DISTINCT ts.public_id,ts.started_at,ts.ended_at,ts.text
    FROM memory_sources ms JOIN transcript_segments ts ON ts.id=ms.segment_id
    WHERE ms.memory_id=? AND ms.segment_id IS NOT NULL ORDER BY ts.started_at`).all(memory.id);
  const contextItems = db.prepare(`SELECT DISTINCT ci.* FROM recording_context_items ci
    LEFT JOIN memory_context_sources mcs ON mcs.context_item_id=ci.id
    WHERE ci.user_id=? AND (ci.memory_id=? OR mcs.memory_id=?)
      AND ci.analysis_state='ready' AND (ci.note_text IS NOT NULL OR ci.analysis_text IS NOT NULL)
    ORDER BY ci.captured_at,ci.created_at`).all(job.user_id, memory.id, memory.id);
  const response = await ai.rewriteMemoryWithContext(job.user_id, { memory, segments, contextItems });
  const value = response.value;
  const used = new Set(value.sourceContextItemIds);
  db.transaction(() => {
    const previousMinis = db.prepare('SELECT id FROM mini_memories WHERE memory_id=?').all(memory.id);
    searchIndex.removeBySources(db, job.user_id, previousMinis.map((row) => ({ kind: 'mini_memory', sourceId: row.id })));
    db.prepare(`UPDATE memories SET type=?,title_en=?,summary_en=?,emoji=?,importance=?,prose_edited_at=NULL,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`)
      .run(value.type, value.titleEn, value.summaryEn, value.emoji, value.importance, memory.id, job.user_id);
    db.prepare('DELETE FROM memory_topics WHERE memory_id=?').run(memory.id);
    const topicInsert = db.prepare('INSERT OR IGNORE INTO memory_topics (memory_id,topic) VALUES (?,?)');
    for (const topic of value.topics) topicInsert.run(memory.id, topic.trim());
    db.prepare('DELETE FROM memory_entities WHERE memory_id=?').run(memory.id);
    db.prepare('DELETE FROM mini_memories WHERE memory_id=?').run(memory.id);
    const insertMini = db.prepare(`INSERT INTO mini_memories
      (public_id,user_id,memory_id,kind,text_en,importance,confidence,due_at,status) VALUES (?,?,?,?,?,?,?,?,?)`);
    const segmentId = db.prepare('SELECT id FROM transcript_segments WHERE public_id=? AND user_id=?');
    const insertMiniSource = db.prepare('INSERT INTO mini_memory_sources (mini_memory_id,segment_id) VALUES (?,?)');
    for (const mini of value.miniMemories) {
      const result = insertMini.run(crypto.randomUUID(), job.user_id, memory.id, mini.kind, mini.textEn,
        mini.importance, mini.confidence, mini.dueAt, mini.status);
      const miniId = Number(result.lastInsertRowid);
      for (const publicId of mini.sourceSegmentIds) {
        insertMiniSource.run(miniId, segmentId.get(publicId, job.user_id).id);
      }
      searchIndex.upsertDocument({ userId: job.user_id, kind: 'mini_memory', sourceId: Number(result.lastInsertRowid),
        body: mini.textEn, occurredAt: memory.started_at, importance: mini.importance }, db);
    }
    const link = db.prepare(`INSERT INTO memory_context_sources (memory_id,context_item_id,used_by_ai)
      VALUES (?,?,?) ON CONFLICT(memory_id,context_item_id) DO UPDATE SET used_by_ai=excluded.used_by_ai`);
    for (const item of contextItems) link.run(memory.id, item.id, Number(used.has(item.id)));
    searchIndex.upsertDocument({ userId: job.user_id, kind: 'memory', sourceId: memory.id,
      title: value.titleEn, body: value.summaryEn, occurredAt: memory.started_at,
      importance: memory.importance_override ?? value.importance }, db);
  })();
  return { memoryId: memory.public_id, contextItems: contextItems.length };
}

module.exports = { handle };
