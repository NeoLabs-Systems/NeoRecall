'use strict';

const { getDatabase } = require('../../db/database');
const processingSettings = require('../../services/settings/processing_settings_service');
const boundary = require('../../services/conversations/boundary_service');
const vectors = require('../../transcription/speaker_embeddings');

function blocksForSegments(database, segments) {
  return segments.map((segment) => {
    const embedded = database.prepare(`SELECT se.embedding FROM search_embeddings se JOIN search_documents d ON d.id=se.document_id
      WHERE d.kind='segment' AND d.source_id=? AND d.user_id=?`).get(String(segment.id), segment.user_id);
    return {
      id: segment.id, segmentIds: [segment.id], startedAt: segment.started_at, endedAt: segment.ended_at,
      speakerId: segment.speaker_cluster_id, embedding: embedded ? vectors.fromBuffer(embedded.embedding) : null,
    };
  });
}

function insertConversation(database, userId, group, state) {
  database.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_score,boundary_version)
    VALUES (?,?,?,?,?,'time-speaker-embedding',NULL,'1')`).run(group.id, userId, group.startedAt, group.endedAt, state);
  const update = database.prepare('UPDATE transcript_segments SET conversation_id=? WHERE id=? AND user_id=?');
  for (const segmentId of group.segmentIds) update.run(group.id, segmentId, userId);
  const speakers = database.prepare(`SELECT DISTINCT t.speaker_cluster_id cluster_id,st.voiceprint_id
    FROM transcript_segments t LEFT JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
    WHERE t.conversation_id=? AND t.user_id=? AND t.speaker_cluster_id IS NOT NULL ORDER BY t.started_at`).all(group.id, userId);
  const insertSpeaker = database.prepare('INSERT OR IGNORE INTO conversation_speakers (conversation_id,cluster_id,voiceprint_id,local_label) VALUES (?,?,?,?)');
  speakers.forEach((speaker, index) => insertSpeaker.run(group.id, speaker.cluster_id, speaker.voiceprint_id || null, `Speaker ${index + 1}`));
}

async function handle(job) {
  const db = getDatabase();
  const config = processingSettings.get();
  const sessions = db.prepare(`SELECT DISTINCT c.session_id FROM audio_chunks c JOIN transcript_segments t ON t.chunk_id=c.id
    WHERE t.user_id=? AND t.conversation_id IS NULL`).all(job.user_id);
  let created = 0;
  db.transaction(() => {
    for (const { session_id: sessionId } of sessions) {
      const open = db.prepare(`SELECT c.* FROM conversations c WHERE c.user_id=? AND c.state='open'
        AND EXISTS (SELECT 1 FROM transcript_segments t JOIN audio_chunks ac ON ac.id=t.chunk_id WHERE t.conversation_id=c.id AND ac.session_id=?)
        ORDER BY c.ended_at DESC LIMIT 1`).get(job.user_id, sessionId);
      let existing = [];
      if (open) {
        existing = db.prepare('SELECT * FROM transcript_segments WHERE conversation_id=? AND user_id=? ORDER BY started_at').all(open.id, job.user_id);
        db.prepare('DELETE FROM conversations WHERE id=? AND user_id=?').run(open.id, job.user_id);
      }
      const unassigned = db.prepare(`SELECT t.* FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
        WHERE t.user_id=? AND t.conversation_id IS NULL AND c.session_id=? ORDER BY t.started_at`).all(job.user_id, sessionId);
      const segments = [...existing, ...unassigned].sort((a, b) => Date.parse(a.started_at) - Date.parse(b.started_at));
      if (!segments.length) continue;
      const groups = boundary.detectBoundaries(blocksForSegments(db, segments), {
        hardGapMs: config.conversationHardGapMs, minimumDurationMs: config.conversationMinimumMs,
        valleyQuantile: config.conversationValleyQuantile,
      });
      groups.forEach((group, index) => {
        const quiet = Date.now() - Date.parse(group.endedAt) >= config.conversationQuietCloseMs;
        insertConversation(db, job.user_id, group, index < groups.length - 1 || quiet ? 'closed' : 'open');
        created += 1;
      });
    }
    db.prepare(`UPDATE conversations SET state='closed',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE user_id=? AND state='open' AND ended_at<=?`).run(job.user_id, new Date(Date.now() - config.conversationQuietCloseMs).toISOString());
  })();
  return { created };
}

module.exports = { handle, blocksForSegments };
