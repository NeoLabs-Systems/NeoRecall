'use strict';

function up(db) {
  db.exec(`
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
    );
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
    );
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
  `);
}

module.exports = { up };
