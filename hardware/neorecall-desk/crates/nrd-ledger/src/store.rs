//! All SQL lives here, parameterized exclusively (mirroring the server's own
//! rule in `GUIDELINES.md`). `Store` wraps a single `rusqlite::Connection`;
//! `Ledger` (in `lib.rs`) adds the `Mutex` that makes it safe to share across
//! threads. Every state-changing method re-derives the new state through
//! `chunk_state::apply` rather than setting a column directly, so an illegal
//! transition is a compile-reachable `Err`, not a silent database write.

use rusqlite::{params, Connection, OptionalExtension};
use std::path::PathBuf;

use crate::chunk_state::{self, ChunkEvent, ChunkState};
use crate::error::LedgerError;
use crate::models::{ChunkRow, GapRow, NewGap, SessionRow, SourceKind, SourceRow};

pub struct Store<'a> {
    pub(crate) conn: &'a Connection,
}

impl<'a> Store<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Store { conn }
    }

    // ---- kv ----

    pub fn get_kv(&self, key: &str) -> Result<Option<String>, LedgerError> {
        Ok(self
            .conn
            .query_row("SELECT value FROM kv WHERE key = ?1", params![key], |row| {
                row.get(0)
            })
            .optional()?)
    }

    pub fn set_kv(&self, key: &str, value: &str) -> Result<(), LedgerError> {
        self.conn.execute(
            "INSERT INTO kv (key, value, updated_at) VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            params![key, value],
        )?;
        Ok(())
    }

    // ---- sessions ----

    #[allow(clippy::too_many_arguments)]
    pub fn insert_session(
        &self,
        id: &str,
        account_id: &str,
        device_id: &str,
        started_at_mono_ms: i64,
        boot_id: &str,
        timezone: &str,
        consent_attested_at: &str,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "INSERT INTO sessions (id, account_id, device_id, started_at_mono_ms, boot_id, timezone, consent_attested_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![id, account_id, device_id, started_at_mono_ms, boot_id, timezone, consent_attested_at],
        )?;
        Ok(())
    }

    pub fn set_session_epoch(
        &self,
        session_id: &str,
        started_at_epoch_ms: i64,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sessions SET started_at_epoch_ms = ?2 WHERE id = ?1",
            params![session_id, started_at_epoch_ms],
        )?;
        Ok(())
    }

    pub fn get_session(&self, session_id: &str) -> Result<Option<SessionRow>, LedgerError> {
        self.conn
            .query_row(
                "SELECT id, account_id, device_id, started_at_epoch_ms, started_at_mono_ms, boot_id, timezone,
                        clock_offset_ms, consent_attested_at, ended_at, status, declared, close_synced,
                        declare_fail_count, last_declare_error, created_at
                 FROM sessions WHERE id = ?1",
                params![session_id],
                Self::map_session_row,
            )
            .optional()
            .map_err(LedgerError::from)
    }

    fn map_session_row(row: &rusqlite::Row) -> rusqlite::Result<SessionRow> {
        Ok(SessionRow {
            id: row.get(0)?,
            account_id: row.get(1)?,
            device_id: row.get(2)?,
            started_at_epoch_ms: row.get(3)?,
            started_at_mono_ms: row.get(4)?,
            boot_id: row.get(5)?,
            timezone: row.get(6)?,
            clock_offset_ms: row.get(7)?,
            consent_attested_at: row.get(8)?,
            ended_at: row.get(9)?,
            status: row.get(10)?,
            declared: row.get::<_, i64>(11)? != 0,
            close_synced: row.get::<_, i64>(12)? != 0,
            declare_fail_count: row.get(13)?,
            last_declare_error: row.get(14)?,
            created_at: row.get(15)?,
        })
    }

    pub fn mark_session_declared(&self, session_id: &str) -> Result<(), LedgerError> {
        self.conn.execute("UPDATE sessions SET declared = 1, declare_fail_count = 0, last_declare_error = NULL WHERE id = ?1", params![session_id])?;
        Ok(())
    }

    pub fn mark_session_declare_failed(
        &self,
        session_id: &str,
        error: &str,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sessions SET declare_fail_count = declare_fail_count + 1, last_declare_error = ?2 WHERE id = ?1",
            params![session_id, error],
        )?;
        Ok(())
    }

    pub fn close_session(
        &self,
        session_id: &str,
        ended_at: &str,
        status: &str,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sessions SET ended_at = ?2, status = ?3 WHERE id = ?1",
            params![session_id, ended_at, status],
        )?;
        Ok(())
    }

    pub fn mark_session_close_synced(&self, session_id: &str) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sessions SET close_synced = 1 WHERE id = ?1",
            params![session_id],
        )?;
        Ok(())
    }

    /// Every session still open at boot (crash recovery boundary #9).
    /// Closing it as `interrupted` is the caller's job (it must also declare
    /// a `device_shutdown` gap per source); this only lists candidates.
    pub fn list_open_sessions(&self) -> Result<Vec<String>, LedgerError> {
        let mut stmt = self
            .conn
            .prepare("SELECT id FROM sessions WHERE ended_at IS NULL")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn list_undeclared_sessions(&self) -> Result<Vec<String>, LedgerError> {
        let mut stmt = self.conn.prepare(
            "SELECT id FROM sessions WHERE declared = 0 AND started_at_epoch_ms IS NOT NULL",
        )?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    // ---- sources ----

    pub fn insert_source(
        &self,
        id: &str,
        session_id: &str,
        kind: SourceKind,
        sample_rate: i64,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "INSERT INTO sources (id, session_id, kind, sample_rate, created_at) VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![id, session_id, kind.as_str(), sample_rate],
        )?;
        Ok(())
    }

    pub fn get_source(&self, source_id: &str) -> Result<Option<SourceRow>, LedgerError> {
        self.conn
            .query_row(
                "SELECT id, session_id, kind, channel_layout, sample_rate, sample_format, metadata_json,
                        next_sequence, next_offset_ms, final_sequence, closed, close_synced, declared, created_at
                 FROM sources WHERE id = ?1",
                params![source_id],
                Self::map_source_row,
            )
            .optional()
            .map_err(LedgerError::from)
    }

    fn map_source_row(row: &rusqlite::Row) -> rusqlite::Result<SourceRow> {
        let kind_text: String = row.get(2)?;
        Ok(SourceRow {
            id: row.get(0)?,
            session_id: row.get(1)?,
            kind: kind_text.parse().map_err(|e: String| {
                rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, e.into())
            })?,
            channel_layout: row.get(3)?,
            sample_rate: row.get(4)?,
            sample_format: row.get(5)?,
            metadata_json: row.get(6)?,
            next_sequence: row.get(7)?,
            next_offset_ms: row.get(8)?,
            final_sequence: row.get(9)?,
            closed: row.get::<_, i64>(10)? != 0,
            close_synced: row.get::<_, i64>(11)? != 0,
            declared: row.get::<_, i64>(12)? != 0,
            created_at: row.get(13)?,
        })
    }

    /// Atomically allocates the next `(sequence, offset)` pair for a source
    /// and advances its durable cursor by `duration_ms`. Living in the row
    /// (not chunker memory) is what makes a sequence impossible to reuse or
    /// skip across a crash: the allocation and the ledger write commit
    /// together.
    pub fn allocate_sequence(
        &self,
        source_id: &str,
        duration_ms: i64,
    ) -> Result<(i64, i64), LedgerError> {
        let (sequence, offset) = self.conn.query_row(
            "UPDATE sources SET next_sequence = next_sequence + 1, next_offset_ms = next_offset_ms + ?2
             WHERE id = ?1
             RETURNING next_sequence - 1, next_offset_ms - ?2",
            params![source_id, duration_ms],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        Ok((sequence, offset))
    }

    pub fn close_source(&self, source_id: &str, final_sequence: i64) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sources SET closed = 1, final_sequence = ?2 WHERE id = ?1",
            params![source_id, final_sequence],
        )?;
        Ok(())
    }

    pub fn mark_source_declared(&self, source_id: &str) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sources SET declared = 1 WHERE id = ?1",
            params![source_id],
        )?;
        Ok(())
    }

    pub fn mark_source_close_synced(&self, source_id: &str) -> Result<(), LedgerError> {
        self.conn.execute(
            "UPDATE sources SET close_synced = 1 WHERE id = ?1",
            params![source_id],
        )?;
        Ok(())
    }

    // ---- chunks ----

    /// Inserts a chunk row *before* its audio file is fully written
    /// (state = Capturing). If the process crashes before
    /// `complete_chunk_write` runs, `nrd-ledger::recovery` finds this row
    /// alongside an orphaned `.partial` file and repairs or discards it.
    #[allow(clippy::too_many_arguments)]
    pub fn insert_chunk_capturing(
        &self,
        local_id: &str,
        session_id: &str,
        source_id: &str,
        sequence: i64,
        monotonic_offset_ms: i64,
        overlap_ms: i64,
        channel_layout: &str,
        container: &str,
        codec: &str,
    ) -> Result<(), LedgerError> {
        self.conn.execute(
            "INSERT INTO chunks (local_id, session_id, source_id, sequence, monotonic_offset_ms, duration_ms, overlap_ms,
                                  channel_layout, container, codec, content_encoding, sha256, byte_size, is_final, state, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9, 'identity', '', 0, 0, ?10, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![local_id, session_id, source_id, sequence, monotonic_offset_ms, overlap_ms, channel_layout, container, codec, ChunkState::Capturing.to_string()],
        )?;
        Ok(())
    }

    /// Completes the write: records the real file path, hash, size and
    /// duration, and transitions Capturing -> Ready.
    #[allow(clippy::too_many_arguments)]
    pub fn complete_chunk_write(
        &self,
        local_id: &str,
        file_path: &str,
        sha256: &str,
        byte_size: i64,
        duration_ms: i64,
        is_final: bool,
    ) -> Result<ChunkState, LedgerError> {
        let current = self.require_chunk_state(local_id)?;
        let next = chunk_state::apply(current, ChunkEvent::LocalWriteCommitted)
            .map_err(LedgerError::IllegalTransition)?;
        self.conn.execute(
            "UPDATE chunks SET file_path = ?2, sha256 = ?3, byte_size = ?4, duration_ms = ?5, is_final = ?6, state = ?7 WHERE local_id = ?1",
            params![local_id, file_path, sha256, byte_size, duration_ms, is_final as i64, next.to_string()],
        )?;
        Ok(next)
    }

    pub fn claim_for_upload(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        self.transition(local_id, ChunkEvent::ClaimedForUpload)
    }

    pub fn mark_uploaded(
        &self,
        local_id: &str,
        server_chunk_id: &str,
    ) -> Result<ChunkState, LedgerError> {
        let next = self.transition(local_id, ChunkEvent::UploadAccepted)?;
        self.conn.execute(
            "UPDATE chunks SET server_chunk_id = ?2, uploaded_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE local_id = ?1",
            params![local_id, server_chunk_id],
        )?;
        Ok(next)
    }

    pub fn mark_transient_failure(
        &self,
        local_id: &str,
        error: &str,
        next_attempt_at: &str,
    ) -> Result<ChunkState, LedgerError> {
        let next = self.transition(local_id, ChunkEvent::UploadTransientFailure)?;
        self.conn.execute(
            "UPDATE chunks SET fail_count = fail_count + 1, last_error = ?2, next_attempt_at = ?3 WHERE local_id = ?1",
            params![local_id, error, next_attempt_at],
        )?;
        Ok(next)
    }

    pub fn mark_auth_expired(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        self.transition(local_id, ChunkEvent::UploadAuthExpired)
    }

    pub fn mark_not_found(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        self.transition(local_id, ChunkEvent::UploadNotFound)
    }

    pub fn mark_idempotency_conflict(
        &self,
        local_id: &str,
        error: &str,
    ) -> Result<ChunkState, LedgerError> {
        let next = self.transition(local_id, ChunkEvent::IdempotencyConflict)?;
        self.conn.execute(
            "UPDATE chunks SET last_error = ?2 WHERE local_id = ?1",
            params![local_id, error],
        )?;
        Ok(next)
    }

    pub fn mark_local_file_missing(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        let next = self.transition(local_id, ChunkEvent::LocalFileMissing)?;
        self.conn.execute(
            "UPDATE chunks SET last_error = 'Local audio file is missing.' WHERE local_id = ?1",
            params![local_id],
        )?;
        Ok(next)
    }

    pub fn mark_retry_backoff_elapsed(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        self.transition(local_id, ChunkEvent::RetryBackoffElapsed)
    }

    pub fn manual_retry(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        self.transition(local_id, ChunkEvent::ManualRetry)
    }

    /// The only path to `Terminal`. `receipt_json` is stored verbatim for
    /// diagnostics; the caller must have already validated it with
    /// `nrd-proto`'s `proves_safe_audio_release` before calling this.
    pub fn mark_terminal(
        &self,
        local_id: &str,
        receipt_json: &str,
    ) -> Result<ChunkState, LedgerError> {
        let next = self.transition(local_id, ChunkEvent::TerminalProven)?;
        self.conn.execute(
            "UPDATE chunks SET receipt_json = ?2, terminal_at = COALESCE(terminal_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE local_id = ?1",
            params![local_id, receipt_json],
        )?;
        Ok(next)
    }

    pub fn mark_reupload_required(
        &self,
        local_id: &str,
        budget: u8,
    ) -> Result<ChunkState, LedgerError> {
        let current = self.require_chunk_state(local_id)?;
        let attempts_used: i64 = self.conn.query_row(
            "SELECT reupload_attempts FROM chunks WHERE local_id = ?1",
            params![local_id],
            |r| r.get(0),
        )?;
        let next = chunk_state::apply(
            current,
            ChunkEvent::ReuploadRequired {
                attempts_used: attempts_used as u8,
                budget,
            },
        )
        .map_err(LedgerError::IllegalTransition)?;
        self.conn.execute(
            "UPDATE chunks SET reupload_attempts = reupload_attempts + 1, state = ?2 WHERE local_id = ?1",
            params![local_id, next.to_string()],
        )?;
        Ok(next)
    }

    /// The double-gated release: re-reads the row inside this call and
    /// refuses unless it is genuinely `Terminal`, then marks it `Released`.
    /// Returns the file path so the caller can unlink it (recovery boundary
    /// #8 makes a second unlink attempt safe if the process dies in between).
    pub fn release_chunk(&self, local_id: &str) -> Result<Option<PathBuf>, LedgerError> {
        let current = self.require_chunk_state(local_id)?;
        if current != ChunkState::Terminal {
            return Err(LedgerError::IllegalTransition(format!(
                "release_chunk called on a chunk in state {current}, not Terminal"
            )));
        }
        let next = chunk_state::apply(current, ChunkEvent::ReleaseCompleted)
            .map_err(LedgerError::IllegalTransition)?;
        let file_path: Option<String> = self.conn.query_row(
            "SELECT file_path FROM chunks WHERE local_id = ?1",
            params![local_id],
            |r| r.get(0),
        )?;
        self.conn.execute(
            "UPDATE chunks SET state = ?2, file_path = NULL, released_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE local_id = ?1",
            params![local_id, next.to_string()],
        )?;
        Ok(file_path.map(PathBuf::from))
    }

    pub fn get_chunk(&self, local_id: &str) -> Result<Option<ChunkRow>, LedgerError> {
        self.conn
            .query_row(
                "SELECT * FROM chunks WHERE local_id = ?1",
                params![local_id],
                Self::map_chunk_row,
            )
            .optional()
            .map_err(LedgerError::from)
    }

    pub fn list_chunks_by_state(&self, state: ChunkState) -> Result<Vec<ChunkRow>, LedgerError> {
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM chunks WHERE state = ?1 ORDER BY created_at ASC")?;
        let rows = stmt.query_map(params![state.to_string()], Self::map_chunk_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn list_chunks_for_source(&self, source_id: &str) -> Result<Vec<ChunkRow>, LedgerError> {
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM chunks WHERE source_id = ?1 ORDER BY sequence ASC")?;
        let rows = stmt.query_map(params![source_id], Self::map_chunk_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn require_chunk_state(&self, local_id: &str) -> Result<ChunkState, LedgerError> {
        let text: String = self
            .conn
            .query_row(
                "SELECT state FROM chunks WHERE local_id = ?1",
                params![local_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or_else(|| LedgerError::NotFound(format!("chunk {local_id}")))?;
        text.parse().map_err(LedgerError::IllegalTransition)
    }

    fn transition(&self, local_id: &str, event: ChunkEvent) -> Result<ChunkState, LedgerError> {
        let current = self.require_chunk_state(local_id)?;
        let next = chunk_state::apply(current, event).map_err(LedgerError::IllegalTransition)?;
        self.conn.execute(
            "UPDATE chunks SET state = ?2 WHERE local_id = ?1",
            params![local_id, next.to_string()],
        )?;
        Ok(next)
    }

    fn map_chunk_row(row: &rusqlite::Row) -> rusqlite::Result<ChunkRow> {
        let state_text: String = row.get("state")?;
        Ok(ChunkRow {
            local_id: row.get("local_id")?,
            session_id: row.get("session_id")?,
            source_id: row.get("source_id")?,
            sequence: row.get("sequence")?,
            server_chunk_id: row.get("server_chunk_id")?,
            monotonic_offset_ms: row.get("monotonic_offset_ms")?,
            duration_ms: row.get("duration_ms")?,
            overlap_ms: row.get("overlap_ms")?,
            channel_layout: row.get("channel_layout")?,
            container: row.get("container")?,
            codec: row.get("codec")?,
            content_encoding: row.get("content_encoding")?,
            sha256: row.get("sha256")?,
            byte_size: row.get("byte_size")?,
            is_final: row.get::<_, i64>("is_final")? != 0,
            file_path: row.get("file_path")?,
            state: state_text.parse().map_err(|e: String| {
                rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, e.into())
            })?,
            fail_count: row.get("fail_count")?,
            reupload_attempts: row.get("reupload_attempts")?,
            next_attempt_at: row.get("next_attempt_at")?,
            receipt_json: row.get("receipt_json")?,
            last_error: row.get("last_error")?,
            created_at: row.get("created_at")?,
            uploaded_at: row.get("uploaded_at")?,
            terminal_at: row.get("terminal_at")?,
            released_at: row.get("released_at")?,
        })
    }

    // ---- gaps ----

    pub fn insert_gap(&self, gap: &NewGap) -> Result<(), LedgerError> {
        self.conn.execute(
            "INSERT INTO gaps (id, session_id, source_id, start_offset_ms, end_offset_ms, start_sequence, end_sequence, reason, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![gap.id, gap.session_id, gap.source_id, gap.start_offset_ms, gap.end_offset_ms, gap.start_sequence, gap.end_sequence, gap.reason],
        )?;
        Ok(())
    }

    pub fn list_unsynced_gaps(&self) -> Result<Vec<GapRow>, LedgerError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, session_id, source_id, start_offset_ms, end_offset_ms, start_sequence, end_sequence, reason, synced, created_at
             FROM gaps WHERE synced = 0 ORDER BY created_at ASC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(GapRow {
                id: row.get(0)?,
                session_id: row.get(1)?,
                source_id: row.get(2)?,
                start_offset_ms: row.get(3)?,
                end_offset_ms: row.get(4)?,
                start_sequence: row.get(5)?,
                end_sequence: row.get(6)?,
                reason: row.get(7)?,
                synced: row.get::<_, i64>(8)? != 0,
                created_at: row.get(9)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn mark_gaps_synced(&self, ids: &[String]) -> Result<(), LedgerError> {
        for id in ids {
            self.conn
                .execute("UPDATE gaps SET synced = 1 WHERE id = ?1", params![id])?;
        }
        Ok(())
    }
}
