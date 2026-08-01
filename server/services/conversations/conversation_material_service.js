'use strict';

const { getDatabase } = require('../../db/database');

// The transcript material of one conversation, in the shape every AI prompt
// consumes. Consolidation reads it for finished conversations and the live
// preview reads it for conversations that are still recording, so the
// completeness rule, the segment projection and the ordering live here once.

const SESSION_ID_SELECT = `(SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
  WHERE ts.conversation_id=c.id ORDER BY ts.started_at LIMIT 1)`;

// Quarantine excludes a conversation from consolidation, never from being read.
// Callers that describe a conversation rather than consolidate it opt back in.
function quarantineClause(includeQuarantined) {
  return includeQuarantined ? '' : 'AND c.quarantined_at IS NULL';
}

function listByState(userId, states, database = getDatabase(), { includeQuarantined = false } = {}) {
  const placeholders = states.map(() => '?').join(',');
  return database.prepare(`SELECT c.*, ${SESSION_ID_SELECT} session_id
    FROM conversations c WHERE c.user_id=? AND c.state IN (${placeholders})
    ${quarantineClause(includeQuarantined)} ORDER BY c.started_at`).all(userId, ...states);
}

function findInState(userId, conversationId, states, database = getDatabase(), { includeQuarantined = false } = {}) {
  const placeholders = states.map(() => '?').join(',');
  return database.prepare(`SELECT c.*, ${SESSION_ID_SELECT} session_id
    FROM conversations c WHERE c.id=? AND c.user_id=? AND c.state IN (${placeholders})
    ${quarantineClause(includeQuarantined)}`).get(conversationId, userId, ...states) || null;
}

/// Transcript size without loading the transcript.
///
/// Preview eligibility is re-evaluated for every open conversation on every
/// scheduler tick, and only the size matters there — reading the text itself
/// would make an idle check cost as much as an actual preview.
function transcriptCharacters(userId, conversationId, database = getDatabase()) {
  return database.prepare('SELECT COALESCE(SUM(length(text)),0) characters FROM transcript_segments WHERE conversation_id=? AND user_id=?')
    .get(conversationId, userId).characters;
}

/// True when nothing earlier in the recording can still change this
/// conversation's transcript.
///
/// A chunk is only meaningful once every earlier chunk of its own source has
/// reached a terminal state: an outstanding chunk would insert segments *before*
/// existing ones and silently change what the conversation contained. An empty
/// conversation is never complete — there is nothing to describe.
function isComplete(userId, conversationId, database = getDatabase()) {
  const chunkIds = database.prepare('SELECT DISTINCT chunk_id FROM transcript_segments WHERE conversation_id=? AND user_id=?')
    .all(conversationId, userId);
  if (!chunkIds.length) return false;
  return chunkIds.every(({ chunk_id: chunkId }) => {
    const chunk = database.prepare('SELECT source_id,sequence FROM audio_chunks WHERE id=? AND user_id=?').get(chunkId, userId);
    if (!chunk) return false;
    return !database.prepare(`SELECT 1 FROM audio_chunks WHERE source_id=? AND sequence<=?
      AND state NOT IN ('transcribed','silent') LIMIT 1`).get(chunk.source_id, chunk.sequence);
  });
}

const SEGMENT_PROJECTION = `SELECT public_id id,started_at,ended_at,text,language,speaker_cluster_id speakerClusterId
  FROM transcript_segments WHERE conversation_id=? AND user_id=?`;
const SEGMENT_ORDER = 'ORDER BY started_at,ended_at,public_id';

function segmentsOf(userId, conversationId, database = getDatabase()) {
  return database.prepare(`${SEGMENT_PROJECTION} ${SEGMENT_ORDER}`).all(conversationId, userId);
}

/// Segments recorded after a given instant, for a caller that has already
/// described everything up to it.
function segmentsAfter(userId, conversationId, endedAfter, database = getDatabase()) {
  return database.prepare(`${SEGMENT_PROJECTION} AND ended_at>? ${SEGMENT_ORDER}`).all(conversationId, userId, endedAfter);
}

function characterCount(segments) {
  return segments.reduce((sum, segment) => sum + segment.text.length, 0);
}

/// How much audio a conversation spans, which is what decides whether it is
/// worth an outbound LLM request. Character counts cannot answer that: they
/// scale with how fast someone talks, not with how long they talked.
function durationMs(conversation) {
  const started = Date.parse(conversation.started_at ?? conversation.startedAt);
  const ended = Date.parse(conversation.ended_at ?? conversation.endedAt);
  return Number.isFinite(started) && Number.isFinite(ended) ? Math.max(0, ended - started) : 0;
}

function material(userId, conversation, database = getDatabase()) {
  const segments = segmentsOf(userId, conversation.id, database);
  return {
    id: conversation.id,
    sessionId: conversation.session_id,
    startedAt: conversation.started_at,
    endedAt: conversation.ended_at,
    segments,
    characters: characterCount(segments),
  };
}

module.exports = {
  listByState, findInState, isComplete, segmentsOf, segmentsAfter, characterCount, durationMs,
  transcriptCharacters, material,
};
