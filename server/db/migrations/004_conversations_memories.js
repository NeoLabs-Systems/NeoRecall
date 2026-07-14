'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE ai_requests (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      purpose TEXT NOT NULL CHECK (purpose IN ('consolidation','ask')),
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
    CREATE INDEX idx_ai_requests_user_purpose ON ai_requests(user_id, purpose, reserved_at DESC);
    CREATE TABLE consolidation_runs (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      candidate_started_at TEXT,
      candidate_ended_at TEXT,
      material_characters INTEGER NOT NULL DEFAULT 0,
      material_conversations INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL CHECK (state IN ('reserved','running','succeeded','failed','skipped_no_material','skipped_incomplete')),
      reserved_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      ai_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL,
      memory_count INTEGER NOT NULL DEFAULT 0,
      mini_memory_count INTEGER NOT NULL DEFAULT 0,
      error_code TEXT
    );
    CREATE INDEX idx_consolidation_gate ON consolidation_runs(user_id, reserved_at DESC);
    CREATE UNIQUE INDEX idx_consolidation_one_active ON consolidation_runs(user_id) WHERE state IN ('reserved','running');
    CREATE TABLE memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      public_id TEXT NOT NULL UNIQUE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      title_en TEXT NOT NULL,
      summary_en TEXT NOT NULL,
      importance REAL NOT NULL CHECK (importance >= 1 AND importance <= 10),
      importance_override REAL CHECK (importance_override IS NULL OR (importance_override >= 1 AND importance_override <= 10)),
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      consolidation_run_id TEXT NOT NULL REFERENCES consolidation_runs(id) ON DELETE CASCADE,
      pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
      archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0,1)),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_memories_user_time ON memories(user_id, started_at DESC);
    CREATE TABLE memory_sources (
      memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
      segment_id INTEGER REFERENCES transcript_segments(id) ON DELETE CASCADE,
      CHECK (conversation_id IS NOT NULL OR segment_id IS NOT NULL),
      UNIQUE(memory_id, conversation_id, segment_id)
    );
    CREATE TABLE memory_topics (
      memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      topic TEXT NOT NULL COLLATE NOCASE,
      PRIMARY KEY(memory_id, topic)
    );
    CREATE TABLE mini_memories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      public_id TEXT NOT NULL UNIQUE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('fact','event','location','person','relationship','task','promise')),
      text_en TEXT NOT NULL,
      importance REAL NOT NULL CHECK (importance >= 1 AND importance <= 10),
      importance_override REAL CHECK (importance_override IS NULL OR (importance_override >= 1 AND importance_override <= 10)),
      confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
      due_at TEXT,
      occurred_at TEXT,
      status TEXT CHECK (status IS NULL OR status IN ('open','completed','cancelled')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_mini_user_kind ON mini_memories(user_id, kind, created_at DESC);
    CREATE TABLE mini_memory_sources (
      mini_memory_id INTEGER NOT NULL REFERENCES mini_memories(id) ON DELETE CASCADE,
      segment_id INTEGER NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
      PRIMARY KEY(mini_memory_id, segment_id)
    );
    CREATE TABLE entities (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('person','organization','project','location','other')),
      canonical_name_en TEXT NOT NULL,
      display_name TEXT,
      normalized_identity_key TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, kind, normalized_identity_key)
    );
    CREATE TABLE entity_aliases (
      entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
      alias TEXT NOT NULL COLLATE NOCASE,
      language TEXT,
      PRIMARY KEY(entity_id, alias)
    );
    CREATE TABLE memory_entities (
      memory_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      PRIMARY KEY(memory_id, entity_id, role)
    );
    CREATE TABLE mini_memory_entities (
      mini_memory_id INTEGER NOT NULL REFERENCES mini_memories(id) ON DELETE CASCADE,
      entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      PRIMARY KEY(mini_memory_id, entity_id, role)
    );
    ALTER TABLE voiceprints ADD COLUMN entity_id TEXT REFERENCES entities(id) ON DELETE SET NULL;
    CREATE TABLE daily_summaries (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      local_date TEXT NOT NULL,
      timezone TEXT NOT NULL,
      summary_en TEXT NOT NULL,
      coverage_started_at TEXT,
      coverage_ended_at TEXT,
      revision INTEGER NOT NULL DEFAULT 1,
      state TEXT NOT NULL CHECK (state IN ('provisional','final')),
      source_count INTEGER NOT NULL DEFAULT 0,
      consolidation_run_id TEXT NOT NULL REFERENCES consolidation_runs(id) ON DELETE CASCADE,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, local_date, timezone)
    );
  `);
}

module.exports = { up };
