'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE ai_requests_rebuilt (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      purpose TEXT NOT NULL CHECK (purpose IN ('consolidation','ask','conversation_preview','memory_merge','context_analysis','memory_context_rewrite')),
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

    CREATE TABLE recording_context_items (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      session_id TEXT REFERENCES recording_sessions(id) ON DELETE CASCADE,
      memory_id INTEGER REFERENCES memories(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('highlight','note','image','document','file')),
      captured_offset_ms INTEGER CHECK (captured_offset_ms IS NULL OR captured_offset_ms >= 0),
      captured_at TEXT,
      note_text TEXT,
      original_name TEXT,
      content_type TEXT,
      byte_size INTEGER CHECK (byte_size IS NULL OR byte_size > 0),
      sha256 TEXT CHECK (sha256 IS NULL OR length(sha256) = 64),
      original_path TEXT,
      original_deleted_at TEXT,
      extracted_text TEXT,
      analysis_text TEXT,
      analysis_state TEXT NOT NULL DEFAULT 'ready'
        CHECK (analysis_state IN ('pending','analyzing','ready','skipped','failed')),
      analysis_error_code TEXT,
      analysis_error_message TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      CHECK (session_id IS NOT NULL OR memory_id IS NOT NULL),
      CHECK ((kind='highlight' AND note_text IS NULL AND original_name IS NULL)
        OR (kind='note' AND note_text IS NOT NULL AND original_name IS NULL)
        OR (kind IN ('image','document','file') AND original_name IS NOT NULL))
    );
    CREATE INDEX idx_context_session_time ON recording_context_items(user_id,session_id,captured_at);
    CREATE INDEX idx_context_memory ON recording_context_items(user_id,memory_id,created_at);
    CREATE INDEX idx_context_analysis ON recording_context_items(analysis_state,created_at);

    CREATE TABLE memory_context_sources (
      memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      context_item_id TEXT NOT NULL REFERENCES recording_context_items(id) ON DELETE CASCADE,
      used_by_ai INTEGER NOT NULL DEFAULT 0 CHECK (used_by_ai IN (0,1)),
      PRIMARY KEY(memory_id,context_item_id)
    );
  `);
}

module.exports = { up, rebuildsReferencedTable: true };
