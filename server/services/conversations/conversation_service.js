'use strict';

const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { pageLimit } = require('../../utils/pagination');

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
  return { items };
}

function get(userId, id) {
  const conversation = getDatabase().prepare('SELECT * FROM conversations WHERE id=? AND user_id=?').get(id, userId);
  if (!conversation) throw new HttpError(404, 'NOT_FOUND', 'Conversation not found.');
  return { ...conversation, segments: getDatabase().prepare('SELECT * FROM transcript_segments WHERE conversation_id=? AND user_id=? ORDER BY started_at').all(id, userId), speakers: getDatabase().prepare('SELECT * FROM conversation_speakers WHERE conversation_id=?').all(id) };
}

module.exports = { list, get };
