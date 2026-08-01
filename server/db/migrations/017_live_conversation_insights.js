'use strict';

// Long recordings must yield results while they are still running: a device may
// stay on all day, and the user wants to look into a conversation that has not
// finished yet. A conversation therefore carries an *insight* — title, summary
// and topics — that is written provisionally while it is open and rewritten as
// final when consolidation refines it. Memories still come only from the final
// pass, so an all-day recording produces one memory per real conversation and a
// three-hour lecture produces exactly one.
//
// The same run also makes consolidation survivable in permanent operation: a
// conversation the model repeatedly mis-partitions is quarantined instead of
// blocking every later consolidation, which would otherwise stop memory
// generation for good.

function up(db) {
  db.exec(`
    CREATE TABLE ai_requests_rebuilt (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      purpose TEXT NOT NULL CHECK (purpose IN ('consolidation','ask','conversation_preview')),
      provider TEXT NOT NULL,
      model TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('reserved','sent','succeeded','failed')),
      http_status INTEGER,
      provider_request_id TEXT,
      prompt_tokens INTEGER,
      completion_tokens INTEGER,
      cost_usd REAL,
      error_code TEXT,
      reserved_at TEXT NOT NULL,
      sent_at TEXT,
      completed_at TEXT
    );
    INSERT INTO ai_requests_rebuilt SELECT id,user_id,purpose,provider,model,state,http_status,provider_request_id,
      prompt_tokens,completion_tokens,cost_usd,error_code,reserved_at,sent_at,completed_at FROM ai_requests;
    DROP TABLE ai_requests;
    ALTER TABLE ai_requests_rebuilt RENAME TO ai_requests;
    CREATE INDEX idx_ai_requests_user_purpose ON ai_requests(user_id, purpose, reserved_at DESC);

    ALTER TABLE conversations ADD COLUMN insight_state TEXT NOT NULL DEFAULT 'none'
      CHECK (insight_state IN ('none','provisional','final'));
    ALTER TABLE conversations ADD COLUMN insight_characters INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN insight_updated_at TEXT;
    -- Stamped before the request, not after it: a conversation with no insight
    -- yet is otherwise due on every scheduler tick, so a model that keeps
    -- failing would spend one request a minute forever.
    ALTER TABLE conversations ADD COLUMN insight_attempted_at TEXT;
    -- End of the newest segment the last preview described. Past a size
    -- threshold a refresh sends the previous summary plus only the speech after
    -- this instant, so refreshing an endless conversation costs a constant
    -- amount instead of growing with its length.
    ALTER TABLE conversations ADD COLUMN insight_covered_through TEXT;
    ALTER TABLE conversations ADD COLUMN insight_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL;
    ALTER TABLE conversations ADD COLUMN memory_worthy INTEGER;
    ALTER TABLE conversations ADD COLUMN consolidation_failures INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE conversations ADD COLUMN quarantined_at TEXT;
    ALTER TABLE conversations ADD COLUMN quarantine_reason TEXT;

    UPDATE conversations SET insight_state='final', insight_updated_at=refined_at, insight_attempted_at=refined_at,
      insight_covered_through=ended_at,
      insight_characters=COALESCE((SELECT SUM(length(t.text)) FROM transcript_segments t WHERE t.conversation_id=conversations.id), 0),
      memory_worthy=CASE WHEN state='not_memory_worthy' THEN 0 ELSE 1 END
      WHERE refined_at IS NOT NULL;

    CREATE INDEX idx_conversations_insight ON conversations(user_id, state, insight_state);
  `);
}

// ai_requests is referenced by consolidation_runs and ask_quota_events with
// ON DELETE SET NULL, so the rebuild has to run with enforcement disabled;
// otherwise dropping the old table would null both links on the way out.
module.exports = { up, rebuildsReferencedTable: true };
