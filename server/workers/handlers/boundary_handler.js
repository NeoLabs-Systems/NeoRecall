'use strict';

const { getDatabase } = require('../../db/database');
const processingSettings = require('../../services/settings/processing_settings_service');
const boundary = require('../../services/conversations/boundary_service');
const membership = require('../../services/conversations/conversation_membership_service');
const vectors = require('../../transcription/speaker_embeddings');

function blocksForSegments(database, segments) {
  return segments.map((segment) => {
    const embedded = database.prepare(`SELECT se.embedding FROM search_embeddings se JOIN search_documents d ON d.id=se.document_id
      WHERE d.kind='segment' AND d.source_id=? AND d.user_id=?`).get(String(segment.id), segment.user_id);
    return {
      id: segment.id, segmentIds: [segment.id], startedAt: segment.started_at, endedAt: segment.ended_at,
      speakerId: segment.speaker_cluster_id, embedding: embedded ? vectors.fromBuffer(embedded.embedding) : null,
      characterCount: segment.text.length,
    };
  });
}

function insertConversation(database, userId, group, state) {
  database.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_score,boundary_version)
    VALUES (?,?,?,?,?,'time-context-embedding',?,'2')`).run(
    group.id, userId, group.startedAt, group.endedAt, state, group.boundaryScore ?? null,
  );
  membership.assignSegments(database, userId, group.id, group.segmentIds);
  membership.rebuildConversationSpeakers(database, userId, group.id);
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
        hardGapMs: config.conversationHardGapMs, softGapMs: config.conversationSoftGapMs,
        minimumDurationMs: config.conversationMinimumMs, valleyQuantile: config.conversationValleyQuantile,
        semanticSimilarityThreshold: config.conversationSemanticSimilarityThreshold,
        semanticValleyProminence: config.conversationSemanticValleyProminence,
        semanticContextSegments: config.conversationSemanticContextSegments,
        maximumDurationMs: config.conversationMaximumMs,
        maximumCharacters: config.conversationMaximumCharacters,
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
