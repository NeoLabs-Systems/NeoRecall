//! Boot-time reconciliation of every crash boundary this ledger can hit.
//! Runs before any capture, upload, or UI code starts. Two absolutes govern
//! everything here: a corrupt ledger or failed migration never triggers
//! recreation (refuse to start capture, keep audio intact, surface a fault
//! instead), and a row whose file is missing always becomes
//! `needs_attention` with a real error, never a silent success.

use std::fs;

use crate::blobs;
use crate::chunk_state::ChunkState;
use crate::error::LedgerError;
use crate::wav_repair;
use crate::Ledger;

#[derive(Debug, Clone, Default)]
pub struct RecoverySummary {
    pub orphan_files_removed: u32,
    pub capturing_rows_repaired: u32,
    pub capturing_rows_marked_missing: u32,
    pub uploaded_rows_reset_to_ready: u32,
    pub released_files_swept: u32,
    /// Sessions still open at boot; the caller (`nrd-core`) must close each
    /// as `interrupted` with the correct per-source `finalSequence` and
    /// declare a `device_shutdown` gap per source (boundary #9). The ledger
    /// only detects these — closing them needs the current per-source
    /// sequence cursor and gap-building logic that belongs to `nrd-core`.
    pub sessions_open_at_boot: Vec<String>,
    /// Chunks stuck `Terminal` with their file still present (boundary #7):
    /// `release_chunk` + the unlink + `POST /chunks/released` never
    /// completed. The caller re-runs the full release sequence for each.
    pub chunks_needing_release_retry: Vec<String>,
}

fn wav_duration_ms(data: &[u8], sample_rate: i64) -> i64 {
    let payload_len = data.len().saturating_sub(wav_repair::HEADER_LEN) as i64;
    let frames = payload_len / 2; // mono S16LE
    if sample_rate == 0 {
        0
    } else {
        (frames * 1000) / sample_rate
    }
}

fn expected_wav_path(ledger: &Ledger, local_id: &str) -> std::path::PathBuf {
    ledger.audio_dir.join(format!("{local_id}.wav"))
}

fn expected_partial_path(ledger: &Ledger, local_id: &str) -> std::path::PathBuf {
    ledger.audio_dir.join(format!("{local_id}.partial"))
}

/// Boundary #2: an audio file with no matching ledger row at all. Only ever
/// happens if the process died between allocating a temp file and inserting
/// the `Capturing` row that would have referenced it.
fn sweep_orphan_files(ledger: &Ledger) -> Result<u32, LedgerError> {
    let mut removed = 0;
    let entries = match fs::read_dir(&ledger.audio_dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => {
            return Err(LedgerError::Io {
                path: ledger.audio_dir.display().to_string(),
                source: e,
            })
        }
    };
    for entry in entries {
        let entry = entry.map_err(|e| LedgerError::Io {
            path: ledger.audio_dir.display().to_string(),
            source: e,
        })?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let local_id = match name
            .strip_suffix(".wav")
            .or_else(|| name.strip_suffix(".partial"))
        {
            Some(id) => id,
            None => continue,
        };
        let exists =
            ledger.with_store(|store| store.get_chunk(local_id).map(|row| row.is_some()))?;
        if !exists {
            blobs::unlink_if_present(&path)?;
            removed += 1;
        }
    }
    Ok(removed)
}

/// Boundaries #1, #3, #4: rows still in `Capturing` at boot.
fn repair_capturing_rows(ledger: &Ledger) -> Result<(u32, u32), LedgerError> {
    let rows = ledger.with_store(|store| store.list_chunks_by_state(ChunkState::Capturing))?;
    let mut repaired = 0;
    let mut marked_missing = 0;

    for row in rows {
        let source = ledger
            .with_store(|store| store.get_source(&row.source_id))?
            .ok_or_else(|| LedgerError::NotFound(format!("source {}", row.source_id)))?;
        let wav_path = expected_wav_path(ledger, &row.local_id);
        let partial_path = expected_partial_path(ledger, &row.local_id);

        if wav_path.exists() {
            // Boundary #4: the rename succeeded but the row was never
            // updated. The canonical file is trusted as-is (write_atomic
            // only renames after a full write + fsync); recompute the
            // bookkeeping columns from it.
            let data = blobs::read(&wav_path)?;
            let sha256 = blobs::sha256_hex(&data);
            let duration_ms = wav_duration_ms(&data, source.sample_rate);
            ledger.with_store(|store| {
                store.complete_chunk_write(
                    &row.local_id,
                    &wav_path.to_string_lossy(),
                    &sha256,
                    data.len() as i64,
                    duration_ms,
                    row.is_final,
                )
            })?;
            repaired += 1;
        } else if partial_path.exists() {
            // Boundary #3: truncate to a whole frame count and fix the RIFF
            // sizes rather than trusting a header that may be zeroed or
            // stale.
            let raw = blobs::read(&partial_path)?;
            if let Some(recovered) = wav_repair::recover_truncated(&raw, source.sample_rate as u32)
            {
                let (path, sha256, size) =
                    blobs::write_atomic(&ledger.audio_dir, &row.local_id, &recovered)?;
                let duration_ms = wav_duration_ms(&recovered, source.sample_rate);
                ledger.with_store(|store| {
                    store.complete_chunk_write(
                        &row.local_id,
                        &path.to_string_lossy(),
                        &sha256,
                        size as i64,
                        duration_ms,
                        row.is_final,
                    )
                })?;
                repaired += 1;
            } else {
                blobs::unlink_if_present(&partial_path)?;
                ledger.with_store(|store| store.mark_local_file_missing(&row.local_id))?;
                marked_missing += 1;
            }
        } else {
            // Boundary #1: nothing was ever durably written for this
            // sequence. There is no audio to retain; the caller declares a
            // gap covering it.
            ledger.with_store(|store| store.mark_local_file_missing(&row.local_id))?;
            marked_missing += 1;
        }
    }
    Ok((repaired, marked_missing))
}

/// Boundary #6: `Uploaded` with a NULL `server_chunk_id` — unpollable.
/// Pushed back to `Ready` so the pump re-uploads rather than polling forever.
fn repair_unpollable_uploaded_rows(ledger: &Ledger) -> Result<u32, LedgerError> {
    let rows = ledger.with_store(|store| store.list_chunks_by_state(ChunkState::Uploaded))?;
    let mut fixed = 0;
    for row in rows {
        if row.server_chunk_id.is_none() {
            ledger.with_store(|store| store.mark_not_found(&row.local_id))?;
            fixed += 1;
        }
    }
    Ok(fixed)
}

/// Boundary #8: `Released` rows whose file survived (unlink didn't run, or
/// ran but the process died before the containing directory's rename was
/// visible). The expected path is derived from `local_id` — not from the
/// (already-nulled) `file_path` column — so this is safe to re-run any
/// number of times.
fn sweep_released_files(ledger: &Ledger) -> Result<u32, LedgerError> {
    let rows = ledger.with_store(|store| store.list_chunks_by_state(ChunkState::Released))?;
    let mut removed = 0;
    for row in rows {
        let path = expected_wav_path(ledger, &row.local_id);
        if path.exists() {
            blobs::unlink_if_present(&path)?;
            removed += 1;
        }
    }
    Ok(removed)
}

pub fn run(ledger: &Ledger) -> Result<RecoverySummary, LedgerError> {
    let orphan_files_removed = sweep_orphan_files(ledger)?;
    let (capturing_rows_repaired, capturing_rows_marked_missing) = repair_capturing_rows(ledger)?;
    let uploaded_rows_reset_to_ready = repair_unpollable_uploaded_rows(ledger)?;
    let released_files_swept = sweep_released_files(ledger)?;
    let sessions_open_at_boot = ledger.with_store(|store| store.list_open_sessions())?;
    let chunks_needing_release_retry = ledger
        .with_store(|store| store.list_chunks_by_state(ChunkState::Terminal))?
        .into_iter()
        .map(|row| row.local_id)
        .collect();

    Ok(RecoverySummary {
        orphan_files_removed,
        capturing_rows_repaired,
        capturing_rows_marked_missing,
        uploaded_rows_reset_to_ready,
        released_files_swept,
        sessions_open_at_boot,
        chunks_needing_release_retry,
    })
}
