'use strict';

// User-initiated memory merges may rewrite title, summary and emoji through the
// language model. That needs its own ai_requests purpose so admin accounting
// does not confuse merges with consolidations or Ask.

function up(db) {
  db.exec(`
    CREATE TABLE ai_requests_rebuilt (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      purpose TEXT NOT NULL CHECK (purpose IN ('consolidation','ask','conversation_preview','memory_merge')),
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
  `);
}

module.exports = { up, rebuildsReferencedTable: true };
