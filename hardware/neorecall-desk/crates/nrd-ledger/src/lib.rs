//! The durable ledger for NeoRecall Desk.
//!
//! **The reliability invariant (`AGENTS.md`): a client may release audio
//! only after a terminal receipt proves transcript persistence and
//! server-side audio deletion.** Unlike the reference ESP32 Smart Panel
//! firmware (which has no durable store and frees a chunk's bytes as soon as
//! the server 2xx-accepts the upload — see
//! `hardware/neorecall-smartpanel/main/ingest/nr_ingest.c`), this ledger
//! holds every chunk's audio on disk until `chunk_state::ChunkState::Terminal`
//! is reached through a validated receipt, and only then unlinks it. A crash
//! at any point before that proof exists must retain the audio; see
//! `recovery` for how every such boundary is reconciled at boot.

mod blobs;
mod chunk_state;
mod error;
mod models;
mod recovery;
mod schema;
mod store;
mod wav_repair;

pub use blobs::{sha256_hex, verify_sha256};
pub use chunk_state::{ChunkEvent, ChunkState};
pub use error::LedgerError;
pub use models::{ChunkRow, GapRow, NewGap, SourceKind, SourceRow};
pub use recovery::RecoverySummary;
pub use store::Store;
pub use wav_repair::{
    build_header as build_wav_header, recover_truncated as recover_truncated_wav,
    HEADER_LEN as WAV_HEADER_LEN,
};

use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct Ledger {
    conn: Mutex<Connection>,
    pub audio_dir: PathBuf,
}

impl Ledger {
    /// Opens (creating if needed) the ledger database at `db_path` and the
    /// audio directory at `audio_dir`, running migrations and setting the
    /// durability pragmas. Does **not** run crash recovery — call
    /// `run_recovery` explicitly once, before anything else touches the
    /// ledger, so the caller controls exactly when that happens.
    pub fn open(db_path: &Path, audio_dir: &Path) -> Result<Ledger, LedgerError> {
        std::fs::create_dir_all(audio_dir).map_err(|e| LedgerError::Io {
            path: audio_dir.display().to_string(),
            source: e,
        })?;
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| LedgerError::Io {
                path: parent.display().to_string(),
                source: e,
            })?;
        }
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "FULL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        schema::run_migrations(&conn)?;
        Ok(Ledger {
            conn: Mutex::new(conn),
            audio_dir: audio_dir.to_path_buf(),
        })
    }

    /// In-memory ledger for tests: same schema and pragmas, no filesystem
    /// database file (the audio directory is still real, since chunk audio
    /// always needs a genuine path to atomically rename into).
    pub fn open_in_memory(audio_dir: &Path) -> Result<Ledger, LedgerError> {
        std::fs::create_dir_all(audio_dir).map_err(|e| LedgerError::Io {
            path: audio_dir.display().to_string(),
            source: e,
        })?;
        let conn = Connection::open_in_memory()?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        schema::run_migrations(&conn)?;
        Ok(Ledger {
            conn: Mutex::new(conn),
            audio_dir: audio_dir.to_path_buf(),
        })
    }

    pub fn with_store<T>(
        &self,
        f: impl FnOnce(&Store) -> Result<T, LedgerError>,
    ) -> Result<T, LedgerError> {
        let guard = self.conn.lock().expect("ledger mutex poisoned");
        let store = Store::new(&guard);
        f(&store)
    }

    /// Writes a chunk's audio and ledger row together: insert the
    /// `Capturing` row, atomically write the file, then transition to
    /// `Ready`. If the process dies partway through, `run_recovery` finds
    /// whatever state this left behind and repairs it (see `recovery`).
    #[allow(clippy::too_many_arguments)]
    pub fn write_chunk(
        &self,
        local_id: &str,
        session_id: &str,
        source_id: &str,
        sequence: i64,
        monotonic_offset_ms: i64,
        overlap_ms: i64,
        channel_layout: &str,
        sample_rate: i64,
        data: &[u8],
        is_final: bool,
    ) -> Result<ChunkRow, LedgerError> {
        self.with_store(|store| {
            store.insert_chunk_capturing(
                local_id,
                session_id,
                source_id,
                sequence,
                monotonic_offset_ms,
                overlap_ms,
                channel_layout,
                "wav",
                "pcm_s16le",
            )
        })?;

        let (path, sha256, byte_size) = blobs::write_atomic(&self.audio_dir, local_id, data)?;
        let duration_ms = {
            let payload_len = data.len().saturating_sub(wav_repair::HEADER_LEN) as i64;
            let frames = payload_len / 2;
            if sample_rate == 0 {
                0
            } else {
                (frames * 1000) / sample_rate
            }
        };

        self.with_store(|store| {
            store.complete_chunk_write(
                local_id,
                &path.to_string_lossy(),
                &sha256,
                byte_size as i64,
                duration_ms,
                is_final,
            )
        })?;
        self.with_store(|store| store.get_chunk(local_id))?
            .ok_or_else(|| LedgerError::NotFound(format!("chunk {local_id}")))
    }

    pub fn run_recovery(&self) -> Result<RecoverySummary, LedgerError> {
        recovery::run(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::SourceKind;

    fn open_test_ledger() -> (Ledger, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let ledger = Ledger::open_in_memory(&dir.path().join("audio")).unwrap();
        (ledger, dir)
    }

    fn seed_session_and_source(ledger: &Ledger) -> (String, String) {
        let session_id = "session-1".to_string();
        let source_id = "source-1".to_string();
        ledger
            .with_store(|store| {
                store.insert_session(
                    &session_id,
                    "account-1",
                    "device-1",
                    1000,
                    "boot-1",
                    "UTC",
                    "2026-08-25T00:00:00.000Z",
                )?;
                store.insert_source(&source_id, &session_id, SourceKind::System, 16_000)
            })
            .unwrap();
        (session_id, source_id)
    }

    #[test]
    fn write_chunk_then_release_only_after_a_terminal_receipt() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let header = build_wav_header(16_000, 4);
        let mut wav = header.to_vec();
        wav.extend_from_slice(&[1, 2, 3, 4]);

        let chunk = ledger
            .write_chunk(
                "chunk-1",
                &session_id,
                &source_id,
                0,
                0,
                0,
                "mono",
                16_000,
                &wav,
                false,
            )
            .unwrap();
        assert_eq!(chunk.state, ChunkState::Ready);
        assert_eq!(chunk.sha256, sha256_hex(&wav));

        // Cannot release before the chunk is even uploaded.
        assert!(ledger.with_store(|s| s.release_chunk("chunk-1")).is_err());

        ledger
            .with_store(|s| s.claim_for_upload("chunk-1"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_uploaded("chunk-1", "server-chunk-1"))
            .unwrap();

        // Still cannot release on an uploaded-but-not-terminal chunk.
        assert!(ledger.with_store(|s| s.release_chunk("chunk-1")).is_err());

        ledger
            .with_store(|s| s.mark_terminal("chunk-1", "{\"state\":\"transcribed\"}"))
            .unwrap();
        let freed_path = ledger.with_store(|s| s.release_chunk("chunk-1")).unwrap();
        assert!(freed_path.is_some());

        let row = ledger
            .with_store(|s| s.get_chunk("chunk-1"))
            .unwrap()
            .unwrap();
        assert_eq!(row.state, ChunkState::Released);
        assert!(row.file_path.is_none());
    }

    #[test]
    fn sequence_allocation_never_reuses_or_skips_across_calls() {
        let (ledger, _dir) = open_test_ledger();
        let (_session_id, source_id) = seed_session_and_source(&ledger);
        let (seq0, offset0) = ledger
            .with_store(|s| s.allocate_sequence(&source_id, 30_000))
            .unwrap();
        let (seq1, offset1) = ledger
            .with_store(|s| s.allocate_sequence(&source_id, 30_000))
            .unwrap();
        assert_eq!((seq0, offset0), (0, 0));
        assert_eq!((seq1, offset1), (1, 30_000));
    }

    #[test]
    fn recovery_repairs_a_truncated_partial_left_by_a_crash() {
        let (ledger, dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        ledger
            .with_store(|s| {
                s.insert_chunk_capturing(
                    "chunk-crash",
                    &session_id,
                    &source_id,
                    0,
                    0,
                    0,
                    "mono",
                    "wav",
                    "pcm_s16le",
                )
            })
            .unwrap();

        // Simulate a crash mid-write: a .partial file with a torn last frame
        // and no corresponding "Ready" row update.
        let header = build_wav_header(16_000, 1_000_000); // lying header, as if never finalized
        let mut raw = header.to_vec();
        raw.extend_from_slice(&[1, 2, 3, 4, 9]); // 2 whole frames + 1 stray byte
        std::fs::write(dir.path().join("audio").join("chunk-crash.partial"), &raw).unwrap();

        let summary = ledger.run_recovery().unwrap();
        assert_eq!(summary.capturing_rows_repaired, 1);
        assert_eq!(summary.capturing_rows_marked_missing, 0);

        let row = ledger
            .with_store(|s| s.get_chunk("chunk-crash"))
            .unwrap()
            .unwrap();
        assert_eq!(row.state, ChunkState::Ready);
        // byte_size is the whole file on disk (44-byte header + 4-byte
        // truncated payload) -- this is the size the server sees when the
        // file is uploaded, not just the raw PCM payload length.
        assert_eq!(row.byte_size, 48);
        assert!(!dir
            .path()
            .join("audio")
            .join("chunk-crash.partial")
            .exists());
        assert!(dir.path().join("audio").join("chunk-crash.wav").exists());
    }

    #[test]
    fn recovery_marks_a_capturing_row_with_no_file_at_all_as_needing_attention() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        ledger
            .with_store(|s| {
                s.insert_chunk_capturing(
                    "chunk-nothing",
                    &session_id,
                    &source_id,
                    0,
                    0,
                    0,
                    "mono",
                    "wav",
                    "pcm_s16le",
                )
            })
            .unwrap();

        let summary = ledger.run_recovery().unwrap();
        assert_eq!(summary.capturing_rows_marked_missing, 1);
        let row = ledger
            .with_store(|s| s.get_chunk("chunk-nothing"))
            .unwrap()
            .unwrap();
        assert_eq!(row.state, ChunkState::NeedsAttention);
    }

    #[test]
    fn recovery_removes_orphan_files_with_no_ledger_row() {
        let (ledger, dir) = open_test_ledger();
        std::fs::write(
            dir.path().join("audio").join("orphan.wav"),
            b"nothing references this",
        )
        .unwrap();
        let summary = ledger.run_recovery().unwrap();
        assert_eq!(summary.orphan_files_removed, 1);
        assert!(!dir.path().join("audio").join("orphan.wav").exists());
    }

    #[test]
    fn recovery_finishes_release_for_a_terminal_chunk_whose_file_survived() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let wav = build_wav_header(16_000, 0).to_vec();
        ledger
            .write_chunk(
                "chunk-t",
                &session_id,
                &source_id,
                0,
                0,
                0,
                "mono",
                16_000,
                &wav,
                true,
            )
            .unwrap();
        ledger
            .with_store(|s| s.claim_for_upload("chunk-t"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_uploaded("chunk-t", "server-1"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_terminal("chunk-t", "{}"))
            .unwrap();
        // Simulate a crash between reaching Terminal and calling release_chunk.

        let summary = ledger.run_recovery().unwrap();
        assert_eq!(
            summary.chunks_needing_release_retry,
            vec!["chunk-t".to_string()]
        );
    }

    #[test]
    fn recovery_sweeps_a_leftover_file_for_an_already_released_chunk() {
        let (ledger, dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let wav = build_wav_header(16_000, 0).to_vec();
        ledger
            .write_chunk(
                "chunk-r",
                &session_id,
                &source_id,
                0,
                0,
                0,
                "mono",
                16_000,
                &wav,
                true,
            )
            .unwrap();
        ledger
            .with_store(|s| s.claim_for_upload("chunk-r"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_uploaded("chunk-r", "server-1"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_terminal("chunk-r", "{}"))
            .unwrap();
        ledger.with_store(|s| s.release_chunk("chunk-r")).unwrap();
        // release_chunk already unlinked it in the normal path; recreate the
        // file to simulate a crash that left the row Released but the
        // physical unlink not durable yet.
        std::fs::write(dir.path().join("audio").join("chunk-r.wav"), b"leftover").unwrap();

        let summary = ledger.run_recovery().unwrap();
        assert_eq!(summary.released_files_swept, 1);
        assert!(!dir.path().join("audio").join("chunk-r.wav").exists());
    }

    #[test]
    fn recovery_detects_a_session_left_open_at_boot() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, _source_id) = seed_session_and_source(&ledger);
        let summary = ledger.run_recovery().unwrap();
        assert_eq!(summary.sessions_open_at_boot, vec![session_id]);
    }

    #[test]
    fn a_gap_with_only_one_side_of_the_sequence_pair_is_rejected_by_the_schema() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let bad_gap = NewGap {
            id: "gap-1".to_string(),
            session_id,
            source_id,
            start_offset_ms: 0,
            end_offset_ms: 1000,
            start_sequence: Some(0),
            end_sequence: None, // both-or-neither violated
            reason: "capture_error".to_string(),
        };
        let result = ledger.with_store(|s| s.insert_gap(&bad_gap));
        assert!(result.is_err());
    }

    #[test]
    fn gaps_round_trip_and_can_be_marked_synced() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let gap = NewGap {
            id: "gap-2".to_string(),
            session_id,
            source_id,
            start_offset_ms: 0,
            end_offset_ms: 1000,
            start_sequence: None,
            end_sequence: None,
            reason: "device_shutdown".to_string(),
        };
        ledger.with_store(|s| s.insert_gap(&gap)).unwrap();
        let unsynced = ledger.with_store(|s| s.list_unsynced_gaps()).unwrap();
        assert_eq!(unsynced.len(), 1);
        ledger
            .with_store(|s| s.mark_gaps_synced(&["gap-2".to_string()]))
            .unwrap();
        let unsynced = ledger.with_store(|s| s.list_unsynced_gaps()).unwrap();
        assert!(unsynced.is_empty());
    }

    #[test]
    fn reupload_required_retries_until_the_budget_is_exhausted_then_parks() {
        let (ledger, _dir) = open_test_ledger();
        let (session_id, source_id) = seed_session_and_source(&ledger);
        let wav = build_wav_header(16_000, 0).to_vec();
        ledger
            .write_chunk(
                "chunk-reup",
                &session_id,
                &source_id,
                0,
                0,
                0,
                "mono",
                16_000,
                &wav,
                true,
            )
            .unwrap();
        ledger
            .with_store(|s| s.claim_for_upload("chunk-reup"))
            .unwrap();
        ledger
            .with_store(|s| s.mark_uploaded("chunk-reup", "server-1"))
            .unwrap();

        for _ in 0..3 {
            let state = ledger
                .with_store(|s| s.mark_reupload_required("chunk-reup", 3))
                .unwrap();
            assert_eq!(state, ChunkState::Ready);
            ledger
                .with_store(|s| s.claim_for_upload("chunk-reup"))
                .unwrap();
            ledger
                .with_store(|s| s.mark_uploaded("chunk-reup", "server-1"))
                .unwrap();
        }
        let final_state = ledger
            .with_store(|s| s.mark_reupload_required("chunk-reup", 3))
            .unwrap();
        assert_eq!(final_state, ChunkState::NeedsAttention);
        let row = ledger
            .with_store(|s| s.get_chunk("chunk-reup"))
            .unwrap()
            .unwrap();
        // The file must still exist -- NeedsAttention retains audio.
        assert!(row.file_path.is_some());
    }
}
