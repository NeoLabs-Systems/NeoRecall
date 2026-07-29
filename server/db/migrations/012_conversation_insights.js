'use strict';

function up(db) {
  db.exec(`
    ALTER TABLE conversations ADD COLUMN title_en TEXT;
    ALTER TABLE conversations ADD COLUMN summary_en TEXT;
    ALTER TABLE conversations ADD COLUMN topics_json TEXT NOT NULL DEFAULT '[]'
      CHECK (json_valid(topics_json) AND json_type(topics_json) = 'array');
    ALTER TABLE conversations ADD COLUMN refined_at TEXT;
    ALTER TABLE conversations ADD COLUMN refinement_run_id TEXT
      REFERENCES consolidation_runs(id) ON DELETE SET NULL;
    ALTER TABLE conversations ADD COLUMN origin_conversation_id TEXT;
    UPDATE conversations SET
      title_en = (
        SELECT m.title_en FROM memory_sources ms
        JOIN memories m ON m.id=ms.memory_id
        WHERE ms.conversation_id=conversations.id
        ORDER BY m.importance DESC,m.started_at
        LIMIT 1
      ),
      summary_en = (
        SELECT m.summary_en FROM memory_sources ms
        JOIN memories m ON m.id=ms.memory_id
        WHERE ms.conversation_id=conversations.id
        ORDER BY m.importance DESC,m.started_at
        LIMIT 1
      ),
      topics_json = COALESCE((
        SELECT json_group_array(topic) FROM (
          SELECT DISTINCT mt.topic topic FROM memory_sources ms
          JOIN memory_topics mt ON mt.memory_id=ms.memory_id
          WHERE ms.conversation_id=conversations.id
          ORDER BY mt.topic
        )
      ), '[]')
    WHERE EXISTS (
      SELECT 1 FROM memory_sources ms WHERE ms.conversation_id=conversations.id
    );
    CREATE INDEX idx_conversations_refinement_run ON conversations(refinement_run_id);
    CREATE INDEX idx_conversations_origin ON conversations(user_id, origin_conversation_id);
  `);
}

module.exports = { up };
