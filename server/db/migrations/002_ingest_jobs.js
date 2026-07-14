'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE devices (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      client_uuid TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('browser','desktop','import','wearable')),
      capabilities_json TEXT NOT NULL DEFAULT '{}',
      clock_offset_ms REAL,
      clock_rtt_ms REAL,
      last_heartbeat_at TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, client_uuid)
    );
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
    );
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
  `);
}

module.exports = { up };
