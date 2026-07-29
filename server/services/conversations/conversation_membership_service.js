'use strict';

function assignSegments(database, userId, conversationId, segmentIds, { publicIds = false } = {}) {
  const statement = publicIds
    ? database.prepare('UPDATE transcript_segments SET conversation_id=? WHERE public_id=? AND user_id=?')
    : database.prepare('UPDATE transcript_segments SET conversation_id=? WHERE id=? AND user_id=?');
  for (const segmentId of segmentIds) {
    const result = statement.run(conversationId, segmentId, userId);
    if (result.changes !== 1) {
      throw Object.assign(new Error('A transcript segment could not be assigned to its conversation.'), {
        code: 'CONVERSATION_MEMBERSHIP_INVALID',
      });
    }
  }
}

function rebuildConversationSpeakers(database, userId, conversationId) {
  database.prepare('DELETE FROM conversation_speakers WHERE conversation_id=?').run(conversationId);
  const speakers = database.prepare(`SELECT t.speaker_cluster_id cluster_id,
      (SELECT st.voiceprint_id FROM speaker_turns st
        WHERE st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id AND st.voiceprint_id IS NOT NULL
        ORDER BY st.start_ms LIMIT 1) voiceprint_id,
      MIN(t.started_at) first_seen_at
    FROM transcript_segments t
    WHERE t.conversation_id=? AND t.user_id=? AND t.speaker_cluster_id IS NOT NULL
    GROUP BY t.speaker_cluster_id
    ORDER BY first_seen_at`).all(conversationId, userId);
  const insert = database.prepare(`INSERT INTO conversation_speakers
    (conversation_id,cluster_id,voiceprint_id,local_label) VALUES (?,?,?,?)`);
  speakers.forEach((speaker, index) => {
    insert.run(conversationId, speaker.cluster_id, speaker.voiceprint_id || null, `Speaker ${index + 1}`);
  });
}

module.exports = { assignSegments, rebuildConversationSpeakers };
