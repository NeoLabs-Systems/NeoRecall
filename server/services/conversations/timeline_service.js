'use strict';

const { getDatabase } = require('../../db/database');
const { encodeCursor, decodeCursor, pageLimit } = require('../../utils/pagination');
const { HttpError } = require('../../middleware/error_handler');
const { SPEAKER_NAME_COLUMNS, SPEAKER_NAME_JOINS } = require('../../db/speaker_resolution_sql');

// The timeline reads as moments, not as a flat list of utterances. A moment is
// one conversation with everything that was said in it, so a page holds a
// handful of readable entries instead of an arbitrary cut through the middle of
// a conversation.

// A page of the timeline carries enough of each moment to recognise it, not
// everything that was said in it. The client refreshes this every minute, and
// a busy day's worth of full transcripts is megabytes each time — most of it
// for moments nobody has opened. Opening one fetches the rest.
const PREVIEW_SEGMENTS = 3;

// The cap on a single moment's transcript. It exists so one runaway recording
// cannot turn a response into an unbounded one; what it leaves out is reported
// rather than silently dropped.
const MAX_SEGMENTS_PER_MOMENT = 1500;

// Speech not yet grouped into a conversation is a moment too, and needs a name
// its transcript can be asked for by.
const PENDING_ID = 'pending';

function parseTopics(raw) {
  try {
    const topics = JSON.parse(raw || '[]');
    return Array.isArray(topics) ? topics : [];
  } catch {
    return [];
  }
}

function readSegments(userId, conversationId, limit) {
  const pending = conversationId === PENDING_ID;
  const where = pending ? 't.conversation_id IS NULL' : 't.conversation_id=?';
  const parameters = pending ? [userId] : [userId, conversationId];
  const rows = getDatabase().prepare(`SELECT t.*,${SPEAKER_NAME_COLUMNS}
    FROM transcript_segments t
    ${SPEAKER_NAME_JOINS}
    WHERE t.user_id=? AND ${where}
    ORDER BY t.started_at,t.id LIMIT ?`).all(...parameters, limit);
  const total = getDatabase().prepare(`SELECT COUNT(*) c FROM transcript_segments
    WHERE user_id=? AND ${pending ? 'conversation_id IS NULL' : 'conversation_id=?'}`).get(...parameters).c;
  return { segments: rows, segmentCount: total };
}

function segmentsFor(userId, conversationId) {
  return readSegments(userId, conversationId, PREVIEW_SEGMENTS);
}

/// Everything said in one moment, for a reader who opened it.
function segments(userId, conversationId) {
  const { segments: rows, segmentCount } = readSegments(userId, conversationId, MAX_SEGMENTS_PER_MOMENT);
  if (conversationId !== PENDING_ID) {
    const owned = getDatabase().prepare('SELECT 1 FROM conversations WHERE id=? AND user_id=?')
      .get(conversationId, userId);
    if (!owned) throw new HttpError(404, 'NOT_FOUND', 'Conversation not found.');
  }
  return { segments: rows, segmentCount, truncated: segmentCount > rows.length };
}

/// Speech that has been transcribed but not yet grouped into a conversation.
///
/// This is what was recorded moments ago. It belongs at the top of the first
/// page: leaving it out would mean the newest thing someone said is the one
/// thing the timeline cannot show.
function pendingMoment(userId) {
  const { segments: rows, segmentCount } = readSegments(userId, PENDING_ID, PREVIEW_SEGMENTS);
  if (!rows.length) return null;
  return {
    id: PENDING_ID,
    kind: 'pending',
    startedAt: rows[0].started_at,
    endedAt: rows.at(-1).ended_at,
    state: 'pending',
    insightState: null,
    titleEn: null,
    summaryEn: null,
    topics: [],
    memoryWorthy: null,
    refinedAt: null,
    quarantined: false,
    segmentCount,
    segments: rows,
  };
}

function list(userId, query = {}) {
  const limit = pageLimit(query.limit, 50, 8);
  const cursor = decodeCursor(query.before);
  const rows = getDatabase().prepare(`SELECT * FROM conversations
    WHERE user_id=? AND (? IS NULL OR (started_at < ? OR (started_at = ? AND id < ?)))
    ORDER BY started_at DESC,id DESC LIMIT ?`)
    .all(userId, cursor?.startedAt || null, cursor?.startedAt || null, cursor?.startedAt || null,
      cursor?.id || '', limit + 1);
  const page = rows.slice(0, limit);
  const moments = page.map((conversation) => {
    const { segments, segmentCount } = segmentsFor(userId, conversation.id);
    return {
      id: conversation.id,
      kind: 'conversation',
      startedAt: conversation.started_at,
      endedAt: conversation.ended_at,
      state: conversation.state,
      insightState: conversation.insight_state,
      titleEn: conversation.title_en,
      summaryEn: conversation.summary_en,
      topics: parseTopics(conversation.topics_json),
      memoryWorthy: conversation.memory_worthy === null || conversation.memory_worthy === undefined
        ? null
        : Boolean(conversation.memory_worthy),
      refinedAt: conversation.refined_at,
      quarantined: Boolean(conversation.quarantined_at),
      segmentCount,
      segments,
    };
  });
  // Only the first page carries ungrouped speech: it is the newest material
  // there is, so it never belongs further back in the history.
  const pending = cursor ? null : pendingMoment(userId);
  const last = page.at(-1);
  return {
    moments: pending ? [pending, ...moments] : moments,
    nextCursor: rows.length > limit && last ? encodeCursor({ startedAt: last.started_at, id: last.id }) : null,
  };
}

module.exports = { list, segments, PENDING_ID, PREVIEW_SEGMENTS, MAX_SEGMENTS_PER_MOMENT };
