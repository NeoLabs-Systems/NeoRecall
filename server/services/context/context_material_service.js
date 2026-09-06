'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

function readyItems(userId, sessionIds, database = getDatabase()) {
  if (!sessionIds.length) return [];
  return database.prepare(`SELECT * FROM recording_context_items
    WHERE user_id=? AND session_id IN (${sessionIds.map(() => '?').join(',')})
      AND analysis_state IN ('ready','skipped','failed')
    ORDER BY captured_at,created_at`).all(userId, ...sessionIds);
}

function distance(item, conversation) {
  const point = Date.parse(item.captured_at);
  const start = Date.parse(conversation.started_at ?? conversation.startedAt);
  const end = Date.parse(conversation.ended_at ?? conversation.endedAt);
  if (point >= start && point <= end) return 0;
  return point < start ? start - point : point - end;
}

function nearestSegmentId(item, conversation) {
  const segments = conversation.segments || [];
  if (!segments.length) return null;
  return [...segments].sort((left, right) => {
    const delta = distance(item, left) - distance(item, right);
    return delta || Date.parse(left.started_at ?? left.startedAt) - Date.parse(right.started_at ?? right.startedAt);
  })[0].id;
}

function attach(userId, conversations, database = getDatabase()) {
  const bySession = new Map();
  for (const conversation of conversations) {
    conversation.contextItems = [];
    if (!conversation.sessionId) continue;
    if (!bySession.has(conversation.sessionId)) bySession.set(conversation.sessionId, []);
    bySession.get(conversation.sessionId).push(conversation);
  }
  const maximum = getConfig().contextNoteMaxCharacters;
  for (const item of readyItems(userId, [...bySession.keys()], database)) {
    const candidates = bySession.get(item.session_id) || [];
    if (!candidates.length) continue;
    const target = [...candidates].sort((left, right) => {
      const delta = distance(item, left) - distance(item, right);
      return delta || Date.parse(left.startedAt) - Date.parse(right.startedAt);
    })[0];
    target.contextItems.push({
      id: item.id, kind: item.kind, capturedAt: item.captured_at,
      offsetMs: item.captured_offset_ms, sourceName: item.original_name,
      content: String(item.note_text || item.analysis_text || '').slice(0, maximum),
      analysisState: item.analysis_state,
      sourceSegmentId: nearestSegmentId(item, target),
    });
  }
  return conversations;
}

function sessionComplete(userId, sessionId, database = getDatabase()) {
  return !database.prepare(`SELECT 1 FROM recording_context_items
    WHERE user_id=? AND session_id=? AND analysis_state IN ('pending','analyzing') LIMIT 1`).get(userId, sessionId);
}

module.exports = { attach, sessionComplete, distance, nearestSegmentId };
