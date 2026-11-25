CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  );

CREATE TABLE users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL COLLATE NOCASE UNIQUE,
      email TEXT COLLATE NOCASE UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user','admin')),
      disabled_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_login_at TEXT
    , ai_limit_4h INTEGER, ai_limit_weekly INTEGER, transcription_limit_4h INTEGER, transcription_limit_weekly INTEGER);

CREATE TABLE user_sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      ip_address TEXT,
      user_agent TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE INDEX idx_user_sessions_user ON user_sessions(user_id, revoked_at, expires_at);

CREATE TABLE user_two_factor (
      user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      secret_encrypted TEXT NOT NULL,
      pending INTEGER NOT NULL DEFAULT 1 CHECK (pending IN (0,1)),
      failed_attempts INTEGER NOT NULL DEFAULT 0,
      locked_until TEXT,
      enabled_at TEXT,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE user_recovery_codes (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL,
      used_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, code_hash)
    );

CREATE TABLE api_keys (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      key_prefix TEXT NOT NULL,
      key_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL,
      expires_at TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE INDEX idx_api_keys_user ON api_keys(user_id, revoked_at);

CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE user_settings (
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      key TEXT NOT NULL,
      value_json TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      PRIMARY KEY (user_id, key)
    );

CREATE TABLE audit_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      actor_type TEXT NOT NULL CHECK (actor_type IN ('user','admin','api_key','system')),
      actor_id TEXT,
      affected_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      action TEXT NOT NULL,
      resource_type TEXT,
      resource_id TEXT,
      ip_address TEXT,
      metadata_json TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_audit_created ON audit_log(created_at DESC);

CREATE INDEX idx_audit_user ON audit_log(affected_user_id, created_at DESC);

CREATE TABLE recording_sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      client_uuid TEXT NOT NULL,
      device_started_at TEXT NOT NULL,
      device_ended_at TEXT,
      corrected_started_at TEXT NOT NULL,
      corrected_ended_at TEXT,
      timezone TEXT NOT NULL,
      initial_clock_offset_ms REAL,
      consent_attested_at TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('active','ended','interrupted','stale')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, client_uuid)
    );

CREATE INDEX idx_recording_sessions_user_time ON recording_sessions(user_id, corrected_started_at DESC);

CREATE TABLE recording_sources (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      client_uuid TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('microphone','system','combined','import','wearable')),
      channel_layout TEXT NOT NULL,
      sample_rate INTEGER NOT NULL CHECK (sample_rate > 0),
      sample_format TEXT NOT NULL,
      final_sequence INTEGER,
      contiguous_terminal_sequence INTEGER NOT NULL DEFAULT -1,
      closed_at TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(session_id, client_uuid)
    );

CREATE TABLE recording_gaps (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES recording_sources(id) ON DELETE CASCADE,
      start_offset_ms INTEGER NOT NULL CHECK (start_offset_ms >= 0),
      end_offset_ms INTEGER NOT NULL CHECK (end_offset_ms > start_offset_ms),
      reason TEXT NOT NULL CHECK (reason IN ('sleep','permission_lost','storage_full','capture_error','user_paused','device_shutdown')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    , start_sequence INTEGER, end_sequence INTEGER);

CREATE TABLE audio_chunks (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES recording_sources(id) ON DELETE CASCADE,
      sequence INTEGER NOT NULL CHECK (sequence >= 0),
      idempotency_key TEXT NOT NULL,
      sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
      byte_size INTEGER NOT NULL CHECK (byte_size > 0),
      container TEXT NOT NULL,
      codec TEXT NOT NULL,
      channel_layout TEXT NOT NULL,
      device_started_at TEXT NOT NULL,
      monotonic_offset_ms INTEGER NOT NULL CHECK (monotonic_offset_ms >= 0),
      duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
      overlap_ms INTEGER NOT NULL DEFAULT 0 CHECK (overlap_ms >= 0),
      state TEXT NOT NULL CHECK (state IN ('uploaded','processing','persisted_cleanup_pending','transcribed','silent','retryable_failed','reupload_required')),
      temporary_path TEXT,
      transcript_sha256 TEXT,
      transcript_segment_count INTEGER,
      receipt_version INTEGER NOT NULL DEFAULT 0,
      uploaded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      persisted_at TEXT,
      server_deleted_at TEXT,
      client_released_at TEXT,
      error_code TEXT,
      error_message TEXT,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(source_id, sequence),
      UNIQUE(user_id, idempotency_key)
    );

CREATE INDEX idx_chunks_user_state ON audio_chunks(user_id, state, uploaded_at);

CREATE INDEX idx_chunks_source_sequence ON audio_chunks(source_id, sequence);

CREATE TABLE imports (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
      original_name TEXT NOT NULL,
      content_type TEXT NOT NULL,
      total_size INTEGER NOT NULL CHECK (total_size > 0),
      sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
      part_size INTEGER NOT NULL CHECK (part_size > 0),
      capture_time TEXT,
      timezone TEXT,
      state TEXT NOT NULL CHECK (state IN ('declared','uploading','assembled','processing','completed','failed','cancelled')),
      temporary_path TEXT,
      expires_at TEXT,
      error_code TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE import_parts (
      import_id TEXT NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
      part_number INTEGER NOT NULL CHECK (part_number >= 0),
      range_start INTEGER NOT NULL,
      range_end INTEGER NOT NULL,
      byte_size INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      temporary_path TEXT NOT NULL,
      uploaded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      PRIMARY KEY(import_id, part_number)
    );

CREATE TABLE jobs (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      resource_type TEXT,
      resource_id TEXT,
      type TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('queued','leased','completed','failed','cancelled')),
      priority INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL,
      next_attempt_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      lease_owner TEXT,
      lease_expires_at TEXT,
      payload_json TEXT NOT NULL DEFAULT '{}',
      last_error_code TEXT,
      last_error_message TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      started_at TEXT,
      completed_at TEXT,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_jobs_claim ON jobs(status, next_attempt_at, priority DESC, created_at);

CREATE UNIQUE INDEX idx_jobs_active_resource ON jobs(type, resource_id) WHERE status IN ('queued','leased');

CREATE TABLE worker_heartbeats (
      worker_id TEXT PRIMARY KEY,
      host TEXT NOT NULL,
      role TEXT NOT NULL,
      process_id INTEGER NOT NULL,
      model_state TEXT NOT NULL,
      model_details_json TEXT NOT NULL DEFAULT '{}',
      current_job_id TEXT,
      started_at TEXT NOT NULL,
      heartbeat_at TEXT NOT NULL
    );

CREATE TABLE event_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      event_type TEXT NOT NULL,
      resource_type TEXT,
      resource_id TEXT,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      expires_at TEXT NOT NULL
    );

CREATE INDEX idx_event_outbox_user ON event_outbox(user_id, id);

CREATE TABLE speaker_clusters (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      local_ordinal INTEGER NOT NULL CHECK (local_ordinal > 0),
      centroid_embedding BLOB,
      embedding_model TEXT,
      embedding_dimensions INTEGER,
      sample_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(session_id, local_ordinal)
    );

CREATE TABLE voiceprints (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      display_name TEXT,
      centroid_embedding BLOB NOT NULL,
      embedding_model TEXT NOT NULL,
      embedding_dimensions INTEGER NOT NULL,
      sample_count INTEGER NOT NULL DEFAULT 1,
      matching_enabled INTEGER NOT NULL DEFAULT 1 CHECK (matching_enabled IN (0,1)),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    , entity_id TEXT REFERENCES entities(id) ON DELETE SET NULL, display_name_source TEXT
      CHECK (display_name_source IS NULL OR display_name_source IN ('inferred','manual')), external_key TEXT);

CREATE INDEX idx_voiceprints_user ON voiceprints(user_id, matching_enabled);

CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('open','closed','consolidated','not_memory_worthy')),
      boundary_method TEXT NOT NULL,
      boundary_score REAL,
      boundary_version TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    , title_en TEXT, summary_en TEXT, topics_json TEXT NOT NULL DEFAULT '[]'
      CHECK (json_valid(topics_json) AND json_type(topics_json) = 'array'), refined_at TEXT, refinement_run_id TEXT
      REFERENCES consolidation_runs(id) ON DELETE SET NULL, origin_conversation_id TEXT, insight_state TEXT NOT NULL DEFAULT 'none'
      CHECK (insight_state IN ('none','provisional','final')), insight_characters INTEGER NOT NULL DEFAULT 0, insight_updated_at TEXT, insight_attempted_at TEXT, insight_covered_through TEXT, insight_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL, memory_worthy INTEGER, consolidation_failures INTEGER NOT NULL DEFAULT 0, quarantined_at TEXT, quarantine_reason TEXT);

CREATE INDEX idx_conversations_user_time ON conversations(user_id, started_at DESC);

CREATE TABLE transcript_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      public_id TEXT NOT NULL UNIQUE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      chunk_id TEXT NOT NULL REFERENCES audio_chunks(id) ON DELETE CASCADE,
      conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
      speaker_cluster_id TEXT REFERENCES speaker_clusters(id) ON DELETE SET NULL,
      source_component TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      chunk_start_ms INTEGER NOT NULL,
      chunk_end_ms INTEGER NOT NULL,
      text TEXT NOT NULL,
      language TEXT,
      asr_confidence REAL,
      speaker_confidence REAL,
      overlapping_speech INTEGER NOT NULL DEFAULT 0 CHECK (overlapping_speech IN (0,1)),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_segments_user_time ON transcript_segments(user_id, started_at DESC);

CREATE INDEX idx_segments_chunk ON transcript_segments(chunk_id, chunk_start_ms);

CREATE TABLE speaker_turns (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      chunk_id TEXT NOT NULL REFERENCES audio_chunks(id) ON DELETE CASCADE,
      cluster_id TEXT NOT NULL REFERENCES speaker_clusters(id) ON DELETE CASCADE,
      voiceprint_id TEXT REFERENCES voiceprints(id) ON DELETE SET NULL,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      embedding BLOB,
      embedding_model TEXT,
      embedding_dimensions INTEGER,
      confidence REAL,
      quality REAL,
      overlapping_speech INTEGER NOT NULL DEFAULT 0 CHECK (overlapping_speech IN (0,1)),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_speaker_turns_chunk ON speaker_turns(chunk_id, start_ms);

CREATE TABLE conversation_speakers (
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      cluster_id TEXT NOT NULL REFERENCES speaker_clusters(id) ON DELETE CASCADE,
      voiceprint_id TEXT REFERENCES voiceprints(id) ON DELETE SET NULL,
      local_label TEXT NOT NULL,
      PRIMARY KEY(conversation_id, cluster_id)
    );

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
    , error_message TEXT);

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
    , emoji TEXT, prose_edited_at TEXT, dedupe_checked_at TEXT);

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

CREATE TABLE search_documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('segment','memory','mini_memory','daily_summary')),
      source_id TEXT NOT NULL,
      title TEXT,
      body TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      importance REAL NOT NULL DEFAULT 0,
      text_hash TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, kind, source_id)
    );

CREATE INDEX idx_search_documents_user_kind ON search_documents(user_id, kind, occurred_at DESC);

CREATE VIRTUAL TABLE search_fts USING fts5(
      title, body,
      content='search_documents', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );

CREATE TRIGGER search_documents_ai AFTER INSERT ON search_documents BEGIN
      INSERT INTO search_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;

CREATE TRIGGER search_documents_ad AFTER DELETE ON search_documents BEGIN
      INSERT INTO search_fts(search_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    END;

CREATE TRIGGER search_documents_au AFTER UPDATE ON search_documents BEGIN
      INSERT INTO search_fts(search_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
      INSERT INTO search_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;

CREATE TABLE search_embeddings (
      document_id INTEGER PRIMARY KEY REFERENCES search_documents(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      model_revision TEXT NOT NULL,
      dimensions INTEGER NOT NULL CHECK (dimensions = 384),
      embedding BLOB NOT NULL,
      text_hash TEXT NOT NULL,
      embedded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE ask_quota_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      ai_request_id TEXT REFERENCES ai_requests(id) ON DELETE SET NULL,
      attempted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_ask_quota_user_time ON ask_quota_events(user_id, attempted_at DESC);

CREATE TABLE processing_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      job_id TEXT REFERENCES jobs(id) ON DELETE SET NULL,
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      metric TEXT NOT NULL,
      value REAL NOT NULL,
      unit TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_processing_metrics_time ON processing_metrics(metric, created_at DESC);

CREATE INDEX idx_recording_gaps_source_sequence ON recording_gaps(source_id, start_sequence, end_sequence);

CREATE TABLE "oauth_clients" (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      name TEXT NOT NULL,
      description TEXT,
      client_type TEXT NOT NULL CHECK (client_type IN ('public','confidential')),
      client_secret_hash TEXT,
      redirect_uris_json TEXT NOT NULL,
      scopes_json TEXT NOT NULL,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE TABLE "oauth_authorization_codes" (
      id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL REFERENCES "oauth_clients"(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL UNIQUE,
      redirect_uri TEXT NOT NULL,
      scopes_json TEXT NOT NULL,
      code_challenge TEXT NOT NULL,
      code_challenge_method TEXT NOT NULL DEFAULT 'S256' CHECK (code_challenge_method = 'S256'),
      expires_at TEXT NOT NULL,
      consumed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE "oauth_access_tokens" (
      id TEXT PRIMARY KEY,
      client_id TEXT NOT NULL REFERENCES "oauth_clients"(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE TABLE "oauth_refresh_tokens" (
      id TEXT PRIMARY KEY,
      access_token_id TEXT REFERENCES "oauth_access_tokens"(id) ON DELETE CASCADE,
      client_id TEXT NOT NULL REFERENCES "oauth_clients"(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      scopes_json TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      replaced_by_token_id TEXT REFERENCES "oauth_refresh_tokens"(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE INDEX idx_oauth_clients_active ON oauth_clients(description, client_type, revoked_at);

CREATE INDEX idx_oauth_codes_lookup ON oauth_authorization_codes(client_id, expires_at, consumed_at);

CREATE INDEX idx_oauth_access_lookup ON oauth_access_tokens(token_hash, expires_at, revoked_at);

CREATE INDEX idx_oauth_refresh_lookup ON oauth_refresh_tokens(token_hash, expires_at, revoked_at);

CREATE INDEX idx_conversations_refinement_run ON conversations(refinement_run_id);

CREATE INDEX idx_conversations_origin ON conversations(user_id, origin_conversation_id);

CREATE TABLE diagnostic_request_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      request_id TEXT,
      method TEXT NOT NULL,
      path TEXT NOT NULL,
      status_code INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL,
      error_code TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_diagnostic_events_user_time
      ON diagnostic_request_events(user_id, created_at DESC, id DESC);

CREATE TABLE sources (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      name TEXT NOT NULL,
      config_json TEXT NOT NULL DEFAULT '{}',
      enabled INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE TABLE "speaker_previews" (
      voiceprint_id TEXT PRIMARY KEY REFERENCES voiceprints(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      audio BLOB NOT NULL,
      content_type TEXT NOT NULL DEFAULT 'audio/wav',
      duration_ms INTEGER NOT NULL CHECK (duration_ms BETWEEN 1000 AND 10000),
      quality REAL NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_speaker_previews_user ON speaker_previews(user_id);

CREATE INDEX idx_conversations_insight ON conversations(user_id, state, insight_state);

CREATE TABLE user_webauthn_credentials (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      credential_id TEXT NOT NULL UNIQUE,
      public_key TEXT NOT NULL,
      counter INTEGER NOT NULL DEFAULT 0,
      rp_id TEXT NOT NULL,
      transports TEXT NOT NULL DEFAULT '[]',
      device_type TEXT,
      backed_up INTEGER NOT NULL DEFAULT 0,
      label TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      last_used_at TEXT
    );

CREATE INDEX idx_user_webauthn_credentials_user
      ON user_webauthn_credentials(user_id, rp_id, created_at DESC);

CREATE TABLE webauthn_challenges (
      id TEXT PRIMARY KEY,
      purpose TEXT NOT NULL CHECK (purpose IN ('registration', 'authentication')),
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
      challenge TEXT NOT NULL,
      rp_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_webauthn_challenges_expiry ON webauthn_challenges(expires_at);

CREATE TABLE "devices" (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      client_uuid TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('browser','desktop','mobile','import','wearable','appliance')),
      capabilities_json TEXT NOT NULL DEFAULT '{}',
      clock_offset_ms REAL,
      clock_rtt_ms REAL,
      last_heartbeat_at TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, client_uuid)
    );

CREATE TABLE backups (
      id TEXT PRIMARY KEY,
      destination TEXT NOT NULL,
      artifact_key TEXT,
      bytes INTEGER,
      checksum TEXT,
      trigger_kind TEXT NOT NULL CHECK (trigger_kind IN ('scheduled','manual')),
      state TEXT NOT NULL CHECK (state IN ('running','succeeded','failed')),
      error_code TEXT,
      error_message TEXT,
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      completed_at TEXT,
      pruned_at TEXT
    );

CREATE INDEX idx_backups_started ON backups(started_at DESC);

CREATE TABLE "ai_requests" (
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

CREATE INDEX idx_speaker_turns_cluster ON speaker_turns(user_id, cluster_id);

CREATE INDEX idx_speaker_turns_voiceprint ON speaker_turns(voiceprint_id);

CREATE INDEX idx_segments_conversation ON transcript_segments(conversation_id, speaker_cluster_id);

CREATE UNIQUE INDEX idx_voiceprints_external ON voiceprints(user_id, external_key)
      WHERE external_key IS NOT NULL;

CREATE INDEX idx_memories_dedupe_pending ON memories(user_id) WHERE dedupe_checked_at IS NULL;

CREATE TABLE cloud_archive_items (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('audio','data')),
      local_path TEXT,
      remote_path TEXT NOT NULL,
      bytes INTEGER,
      sha256 TEXT,
      state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','uploading','uploaded','failed','dropped')),
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      uploaded_at TEXT
    , remote_upload_id TEXT, captured_at TEXT);

CREATE INDEX idx_cloud_archive_pending ON cloud_archive_items(user_id, state, created_at)
      WHERE state IN ('queued','uploading');

CREATE TABLE conversation_speaker_resolutions (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      world_signature TEXT NOT NULL,
      evidence_turns INTEGER NOT NULL,
      unresolved_turns INTEGER NOT NULL,
      outcome TEXT NOT NULL,
      resolved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_speaker_resolutions_user ON conversation_speaker_resolutions(user_id, world_signature);

CREATE TABLE cloud_recording_assemblies (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES recording_sources(id) ON DELETE CASCADE,
      local_dir TEXT NOT NULL,
      remote_path TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'assembling' CHECK (state IN ('assembling','dropped')),
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE UNIQUE INDEX idx_cloud_assemblies_active
      ON cloud_recording_assemblies(user_id, session_id, source_id)
      WHERE state='assembling';

CREATE INDEX idx_cloud_assemblies_user ON cloud_recording_assemblies(user_id, state);

CREATE TABLE transcription_usage (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      chunk_id TEXT NOT NULL UNIQUE REFERENCES audio_chunks(id) ON DELETE CASCADE,
      duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

CREATE INDEX idx_transcription_usage_user_time ON transcription_usage(user_id, created_at);

CREATE TABLE usage_reservations (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      meter TEXT NOT NULL,
      amount INTEGER NOT NULL CHECK (amount > 0),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      expires_at TEXT NOT NULL
    );

CREATE INDEX idx_usage_reservations_user_meter ON usage_reservations(user_id, meter, expires_at);

CREATE TABLE "cloud_accounts" (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      type TEXT NOT NULL CHECK (type IN ('nextcloud','neocloud')),
      base_url TEXT NOT NULL,
      username TEXT NOT NULL,
      secret_encrypted TEXT NOT NULL,
      folder TEXT NOT NULL DEFAULT 'NeoRecall',
      audio_enabled INTEGER NOT NULL DEFAULT 0 CHECK (audio_enabled IN (0,1)),
      data_backup_enabled INTEGER NOT NULL DEFAULT 0 CHECK (data_backup_enabled IN (0,1)),
      status TEXT NOT NULL DEFAULT 'connected' CHECK (status IN ('connected','error')),
      last_error TEXT,
      last_audio_upload_at TEXT,
      last_data_backup_at TEXT,
      remote_device_id TEXT,
      quota_used INTEGER,
      quota_limit INTEGER,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
