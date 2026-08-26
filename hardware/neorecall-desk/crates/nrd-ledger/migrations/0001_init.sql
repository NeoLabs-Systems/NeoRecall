CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id                  TEXT PRIMARY KEY,
  account_id          TEXT NOT NULL,
  device_id           TEXT NOT NULL,
  started_at_epoch_ms INTEGER,
  started_at_mono_ms  INTEGER NOT NULL,
  boot_id             TEXT NOT NULL,
  timezone            TEXT NOT NULL,
  clock_offset_ms     INTEGER NOT NULL DEFAULT 0,
  consent_attested_at TEXT NOT NULL,
  ended_at            TEXT,
  status              TEXT,
  declared            INTEGER NOT NULL DEFAULT 0,
  close_synced        INTEGER NOT NULL DEFAULT 0,
  declare_fail_count  INTEGER NOT NULL DEFAULT 0,
  last_declare_error  TEXT,
  created_at          TEXT NOT NULL
);
CREATE INDEX idx_sessions_open ON sessions(ended_at) WHERE ended_at IS NULL;
CREATE INDEX idx_sessions_undeclared ON sessions(declared, account_id);

CREATE TABLE sources (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL CHECK (kind IN ('system','microphone')),
  channel_layout TEXT NOT NULL DEFAULT 'mono',
  sample_rate    INTEGER NOT NULL DEFAULT 16000,
  sample_format  TEXT NOT NULL DEFAULT 'pcm_s16le',
  metadata_json  TEXT NOT NULL DEFAULT '{}',
  next_sequence  INTEGER NOT NULL DEFAULT 0,
  next_offset_ms INTEGER NOT NULL DEFAULT 0,
  final_sequence INTEGER NOT NULL DEFAULT -1,
  closed         INTEGER NOT NULL DEFAULT 0,
  close_synced   INTEGER NOT NULL DEFAULT 0,
  declared       INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL,
  UNIQUE(session_id, kind)
);
CREATE INDEX idx_sources_session ON sources(session_id);

CREATE TABLE chunks (
  local_id            TEXT PRIMARY KEY,
  session_id          TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_id           TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  sequence            INTEGER NOT NULL,
  server_chunk_id     TEXT,
  monotonic_offset_ms INTEGER NOT NULL,
  duration_ms         INTEGER NOT NULL,
  overlap_ms          INTEGER NOT NULL,
  channel_layout      TEXT NOT NULL,
  container           TEXT NOT NULL DEFAULT 'wav',
  codec               TEXT NOT NULL DEFAULT 'pcm_s16le',
  content_encoding    TEXT NOT NULL DEFAULT 'identity',
  sha256              TEXT NOT NULL,
  byte_size           INTEGER NOT NULL,
  is_final            INTEGER NOT NULL DEFAULT 0,
  file_path           TEXT,
  state               TEXT NOT NULL,
  fail_count          INTEGER NOT NULL DEFAULT 0,
  reupload_attempts   INTEGER NOT NULL DEFAULT 0,
  next_attempt_at     TEXT,
  receipt_json        TEXT,
  last_error          TEXT,
  created_at          TEXT NOT NULL,
  uploaded_at         TEXT,
  terminal_at         TEXT,
  released_at         TEXT,
  UNIQUE(source_id, sequence)
);
CREATE INDEX idx_chunks_pump  ON chunks(state, next_attempt_at, created_at);
CREATE INDEX idx_chunks_poll  ON chunks(state, server_chunk_id);
CREATE INDEX idx_chunks_sess  ON chunks(session_id, source_id, sequence);
CREATE INDEX idx_chunks_bytes ON chunks(state) WHERE file_path IS NOT NULL;

CREATE TABLE gaps (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_id       TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  start_offset_ms INTEGER NOT NULL,
  end_offset_ms   INTEGER NOT NULL,
  start_sequence  INTEGER,
  end_sequence    INTEGER,
  reason          TEXT NOT NULL CHECK (reason IN ('sleep','permission_lost','storage_full','capture_error','user_paused','device_shutdown')),
  synced          INTEGER NOT NULL DEFAULT 0,
  created_at      TEXT NOT NULL,
  CHECK (end_offset_ms > start_offset_ms),
  CHECK ((start_sequence IS NULL) = (end_sequence IS NULL))
);
CREATE INDEX idx_gaps_unsynced ON gaps(synced, session_id);
