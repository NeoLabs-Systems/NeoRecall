//! The chunk state machine.
//!
//! **The reliability invariant (`AGENTS.md`): a client may release audio
//! only after a terminal receipt proves transcript persistence and
//! server-side audio deletion.** Every transition below exists to make that
//! statically checkable: `Terminal` is reachable only through
//! `ChunkEvent::TerminalProven`, which the caller can only construct after
//! validating a receipt (see `nrd-proto::receipt::proves_safe_audio_release`
//! in the sibling crate), and `Released` is reachable only from `Terminal`.
//!
//! Unlike the reference ESP32 firmware (which has no durable store and frees
//! audio right after the server 2xx-accepts a chunk), this ledger holds
//! bytes until that proof exists. `Failed` has no attempt ceiling that
//! discards audio — only a bounded reupload budget parks a chunk in
//! `NeedsAttention`, which still retains the file.

use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChunkState {
    /// Still being written locally; not yet a complete, hashed file.
    Capturing,
    /// A complete, hashed file on disk, eligible for upload.
    Ready,
    /// A PUT is in flight (or was in flight when the process died — recovery
    /// re-sends unchanged rather than assuming failure).
    Uploading,
    /// The server accepted the chunk (202/200); waiting for a terminal
    /// receipt via polling.
    Uploaded,
    /// A terminal receipt has been validated: transcript persisted and
    /// server audio deleted. The only state from which local audio may be
    /// removed.
    Terminal,
    /// Local audio has been unlinked and the server has acknowledged
    /// `chunks/released`.
    Released,
    /// A transient failure (network, 5xx, timeout); retried with backoff.
    /// The file is always retained here.
    Failed,
    /// Parked: an idempotency conflict, an exhausted reupload budget, a
    /// missing file, or another condition that needs either an operator or a
    /// server-side fix. The file is retained whenever it still exists.
    NeedsAttention,
}

impl fmt::Display for ChunkState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            ChunkState::Capturing => "capturing",
            ChunkState::Ready => "ready",
            ChunkState::Uploading => "uploading",
            ChunkState::Uploaded => "uploaded",
            ChunkState::Terminal => "terminal",
            ChunkState::Released => "released",
            ChunkState::Failed => "failed",
            ChunkState::NeedsAttention => "needs_attention",
        };
        f.write_str(s)
    }
}

impl std::str::FromStr for ChunkState {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "capturing" => ChunkState::Capturing,
            "ready" => ChunkState::Ready,
            "uploading" => ChunkState::Uploading,
            "uploaded" => ChunkState::Uploaded,
            "terminal" => ChunkState::Terminal,
            "released" => ChunkState::Released,
            "failed" => ChunkState::Failed,
            "needs_attention" => ChunkState::NeedsAttention,
            other => return Err(format!("unknown chunk state {other:?}")),
        })
    }
}

/// Every event that can move a chunk between states. Constructing the
/// server-outcome variants (`UploadAccepted`, `TerminalProven`, ...) is the
/// caller's evidence that the corresponding server response was actually
/// received and validated — `apply` itself trusts the event, not the caller's
/// intent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkEvent {
    LocalWriteCommitted,
    ClaimedForUpload,
    UploadAccepted,
    UploadTransientFailure,
    /// 401: the bearer token is no longer valid. Distinct from a generic
    /// transient failure because the pump must pause globally, not just
    /// back off this one chunk.
    UploadAuthExpired,
    /// 404 on the chunk PUT: the session/source was not found server-side
    /// (e.g. a declare that raced a restart). The session must be
    /// re-declared before retrying.
    UploadNotFound,
    /// 409 IDEMPOTENCY_CONFLICT: local metadata disagrees with what the
    /// server already holds for this (source_id, sequence) or idempotency
    /// key. Re-sending cannot help.
    IdempotencyConflict,
    /// A validated terminal receipt proves safe release (see module docs).
    TerminalProven,
    /// The server returned `reupload_required`; `attempts_used` is the
    /// count *before* this event, `budget` is the configured ceiling.
    ReuploadRequired {
        attempts_used: u8,
        budget: u8,
    },
    /// The local file is missing where the ledger row expects one.
    LocalFileMissing,
    /// The unlink + `POST /chunks/released` sequence completed.
    ReleaseCompleted,
    /// An operator or the pump decided to retry a parked chunk (e.g. after
    /// re-hashing the file and confirming it matches the ledger's sha256).
    ManualRetry,
    /// The pump's own backoff timer for a `Failed` chunk elapsed.
    RetryBackoffElapsed,
}

pub fn apply(state: ChunkState, event: ChunkEvent) -> Result<ChunkState, String> {
    use ChunkEvent as E;
    use ChunkState as S;
    match (state, event) {
        (S::Capturing, E::LocalWriteCommitted) => Ok(S::Ready),
        (S::Capturing, E::LocalFileMissing) => Ok(S::NeedsAttention),

        (S::Ready, E::ClaimedForUpload) => Ok(S::Uploading),
        (S::Ready, E::LocalFileMissing) => Ok(S::NeedsAttention),

        // Recovery re-claims an in-flight upload unchanged rather than
        // assuming it failed.
        (S::Uploading, E::ClaimedForUpload) => Ok(S::Uploading),
        (S::Uploading, E::UploadAccepted) => Ok(S::Uploaded),
        (S::Uploading, E::UploadTransientFailure) => Ok(S::Failed),
        (S::Uploading, E::UploadAuthExpired) => Ok(S::Ready),
        (S::Uploading, E::UploadNotFound) => Ok(S::Ready),
        (S::Uploading, E::IdempotencyConflict) => Ok(S::NeedsAttention),
        (S::Uploading, E::LocalFileMissing) => Ok(S::NeedsAttention),

        (S::Failed, E::RetryBackoffElapsed) => Ok(S::Ready),
        (S::Failed, E::ManualRetry) => Ok(S::Ready),
        (S::Failed, E::LocalFileMissing) => Ok(S::NeedsAttention),

        (S::Uploaded, E::TerminalProven) => Ok(S::Terminal),
        (
            S::Uploaded,
            E::ReuploadRequired {
                attempts_used,
                budget,
            },
        ) => {
            if attempts_used < budget {
                Ok(S::Ready)
            } else {
                Ok(S::NeedsAttention)
            }
        }
        // The chunk was accepted but the server has no record of it when
        // polled (e.g. server_chunk_id never persisted before a crash on
        // our side) -- re-upload rather than poll forever.
        (S::Uploaded, E::UploadNotFound) => Ok(S::Ready),
        (S::Uploaded, E::LocalFileMissing) => Ok(S::NeedsAttention),

        (S::Terminal, E::ReleaseCompleted) => Ok(S::Released),
        // Re-running release() after a crash between unlink and the
        // `chunks/released` POST is idempotent, not a state change.
        (S::Terminal, E::TerminalProven) => Ok(S::Terminal),

        (S::NeedsAttention, E::ManualRetry) => Ok(S::Ready),

        (from, event) => Err(format!("{from} does not accept {event:?}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_normal_chunk_progresses_end_to_end() {
        let mut state = ChunkState::Capturing;
        state = apply(state, ChunkEvent::LocalWriteCommitted).unwrap();
        assert_eq!(state, ChunkState::Ready);
        state = apply(state, ChunkEvent::ClaimedForUpload).unwrap();
        assert_eq!(state, ChunkState::Uploading);
        state = apply(state, ChunkEvent::UploadAccepted).unwrap();
        assert_eq!(state, ChunkState::Uploaded);
        state = apply(state, ChunkEvent::TerminalProven).unwrap();
        assert_eq!(state, ChunkState::Terminal);
        state = apply(state, ChunkEvent::ReleaseCompleted).unwrap();
        assert_eq!(state, ChunkState::Released);
    }

    #[test]
    fn terminal_is_reachable_only_via_terminal_proven() {
        for state in [
            ChunkState::Capturing,
            ChunkState::Ready,
            ChunkState::Uploading,
            ChunkState::Failed,
            ChunkState::NeedsAttention,
            ChunkState::Released,
        ] {
            assert!(
                apply(state, ChunkEvent::TerminalProven).is_err(),
                "{state} must not accept TerminalProven directly"
            );
        }
    }

    #[test]
    fn released_is_reachable_only_from_terminal() {
        for state in [
            ChunkState::Capturing,
            ChunkState::Ready,
            ChunkState::Uploading,
            ChunkState::Uploaded,
            ChunkState::Failed,
            ChunkState::NeedsAttention,
        ] {
            assert!(
                apply(state, ChunkEvent::ReleaseCompleted).is_err(),
                "{state} must not accept ReleaseCompleted"
            );
        }
    }

    #[test]
    fn a_transient_failure_never_jumps_straight_to_needs_attention() {
        // Failed always retries with backoff; only an explicit
        // LocalFileMissing/IdempotencyConflict escalates to NeedsAttention.
        let state = apply(ChunkState::Uploading, ChunkEvent::UploadTransientFailure).unwrap();
        assert_eq!(state, ChunkState::Failed);
    }

    #[test]
    fn reupload_required_retries_while_under_budget_and_parks_once_exhausted() {
        let retried = apply(
            ChunkState::Uploaded,
            ChunkEvent::ReuploadRequired {
                attempts_used: 1,
                budget: 3,
            },
        )
        .unwrap();
        assert_eq!(retried, ChunkState::Ready);
        let exhausted = apply(
            ChunkState::Uploaded,
            ChunkEvent::ReuploadRequired {
                attempts_used: 3,
                budget: 3,
            },
        )
        .unwrap();
        assert_eq!(exhausted, ChunkState::NeedsAttention);
    }

    #[test]
    fn idempotency_conflict_parks_rather_than_retrying() {
        let state = apply(ChunkState::Uploading, ChunkEvent::IdempotencyConflict).unwrap();
        assert_eq!(state, ChunkState::NeedsAttention);
    }

    #[test]
    fn auth_expiry_goes_back_to_ready_not_failed() {
        let state = apply(ChunkState::Uploading, ChunkEvent::UploadAuthExpired).unwrap();
        assert_eq!(state, ChunkState::Ready);
    }

    #[test]
    fn recovery_reclaims_an_in_flight_upload_without_changing_state() {
        let state = apply(ChunkState::Uploading, ChunkEvent::ClaimedForUpload).unwrap();
        assert_eq!(state, ChunkState::Uploading);
    }

    #[test]
    fn re_running_release_on_an_already_terminal_chunk_is_idempotent() {
        let state = apply(ChunkState::Terminal, ChunkEvent::TerminalProven).unwrap();
        assert_eq!(state, ChunkState::Terminal);
    }

    #[test]
    fn a_missing_local_file_always_escalates_to_needs_attention_never_silently_succeeds() {
        for state in [
            ChunkState::Capturing,
            ChunkState::Ready,
            ChunkState::Uploading,
            ChunkState::Failed,
            ChunkState::Uploaded,
        ] {
            assert_eq!(
                apply(state, ChunkEvent::LocalFileMissing).unwrap(),
                ChunkState::NeedsAttention
            );
        }
    }

    #[test]
    fn needs_attention_only_leaves_via_manual_retry() {
        assert_eq!(
            apply(ChunkState::NeedsAttention, ChunkEvent::ManualRetry).unwrap(),
            ChunkState::Ready
        );
        assert!(apply(ChunkState::NeedsAttention, ChunkEvent::TerminalProven).is_err());
        assert!(apply(ChunkState::NeedsAttention, ChunkEvent::UploadAccepted).is_err());
    }

    #[test]
    fn display_and_from_str_round_trip_for_every_state() {
        for state in [
            ChunkState::Capturing,
            ChunkState::Ready,
            ChunkState::Uploading,
            ChunkState::Uploaded,
            ChunkState::Terminal,
            ChunkState::Released,
            ChunkState::Failed,
            ChunkState::NeedsAttention,
        ] {
            let text = state.to_string();
            let parsed: ChunkState = text.parse().unwrap();
            assert_eq!(parsed, state);
        }
    }

    #[test]
    fn an_unknown_state_string_is_rejected_not_defaulted() {
        assert!("bogus".parse::<ChunkState>().is_err());
    }
}
