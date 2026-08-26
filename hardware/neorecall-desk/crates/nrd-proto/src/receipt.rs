//! Receipt parsing and the one predicate that gates local audio deletion.
//!
//! **`AGENTS.md`: a client may release audio only after a terminal receipt
//! proves transcript persistence and server-side audio deletion.** This is
//! that gate. Non-terminal receipts *omit* `persistedAt` /
//! `serverAudioDeletedAt` / `transcriptSha256` entirely (they are absent
//! fields, not JSON `null`) — `Option<String>` via `serde`'s default
//! `#[serde(default)]` treats both identically, which is exactly the
//! behavior required here.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Receipt {
    #[serde(rename = "chunkId")]
    pub chunk_id: String,
    #[serde(rename = "sourceId")]
    pub source_id: String,
    pub sequence: i64,
    pub state: String,
    #[serde(rename = "receiptVersion")]
    pub receipt_version: i64,
    #[serde(rename = "errorCode", default)]
    pub error_code: Option<String>,
    #[serde(rename = "transcriptSegmentCount", default)]
    pub transcript_segment_count: Option<i64>,
    #[serde(rename = "transcriptSha256", default)]
    pub transcript_sha256: Option<String>,
    #[serde(rename = "persistedAt", default)]
    pub persisted_at: Option<String>,
    #[serde(rename = "serverAudioDeletedAt", default)]
    pub server_audio_deleted_at: Option<String>,
    #[serde(default)]
    pub duplicate: Option<bool>,
}

const TERMINAL_STATES: &[&str] = &["transcribed", "silent"];

impl Receipt {
    pub fn is_terminal_state(&self) -> bool {
        TERMINAL_STATES.contains(&self.state.as_str())
    }

    pub fn is_reupload_required(&self) -> bool {
        self.state == "reupload_required"
    }

    /// The single gate on local audio deletion. All four conditions must
    /// hold; a receipt missing any of them — even one claiming a terminal
    /// `state` — does not prove safe release.
    pub fn proves_safe_audio_release(&self) -> bool {
        self.is_terminal_state()
            && self.persisted_at.is_some()
            && self.server_audio_deleted_at.is_some()
            && self.transcript_sha256.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal_json() -> &'static str {
        r#"{
            "chunkId": "c1", "sourceId": "s1", "sequence": 0, "state": "transcribed",
            "receiptVersion": 1, "transcriptSegmentCount": 3,
            "transcriptSha256": "abc123", "persistedAt": "2026-08-25T00:00:00.000Z",
            "serverAudioDeletedAt": "2026-08-25T00:00:01.000Z"
        }"#
    }

    #[test]
    fn a_fully_proven_terminal_receipt_permits_release() {
        let receipt: Receipt = serde_json::from_str(terminal_json()).unwrap();
        assert!(receipt.proves_safe_audio_release());
    }

    #[test]
    fn a_non_terminal_receipt_omits_the_proof_fields_entirely_and_does_not_permit_release() {
        let json = r#"{"chunkId":"c1","sourceId":"s1","sequence":0,"state":"uploaded","receiptVersion":0}"#;
        let receipt: Receipt = serde_json::from_str(json).unwrap();
        assert!(receipt.persisted_at.is_none());
        assert!(!receipt.proves_safe_audio_release());
    }

    #[test]
    fn a_terminal_state_with_a_missing_proof_field_still_does_not_permit_release() {
        // A server bug or a truncated response: state says transcribed but
        // one proof field is missing. Must still refuse release.
        let json = r#"{
            "chunkId": "c1", "sourceId": "s1", "sequence": 0, "state": "transcribed",
            "receiptVersion": 1, "persistedAt": "2026-08-25T00:00:00.000Z",
            "serverAudioDeletedAt": "2026-08-25T00:00:01.000Z"
        }"#; // transcriptSha256 missing
        let receipt: Receipt = serde_json::from_str(json).unwrap();
        assert!(receipt.is_terminal_state());
        assert!(!receipt.proves_safe_audio_release());
    }

    #[test]
    fn silent_is_a_terminal_state_just_like_transcribed() {
        let json = r#"{
            "chunkId": "c1", "sourceId": "s1", "sequence": 0, "state": "silent",
            "receiptVersion": 1, "transcriptSegmentCount": 0,
            "transcriptSha256": "abc123", "persistedAt": "2026-08-25T00:00:00.000Z",
            "serverAudioDeletedAt": "2026-08-25T00:00:01.000Z"
        }"#;
        let receipt: Receipt = serde_json::from_str(json).unwrap();
        assert!(receipt.proves_safe_audio_release());
    }

    #[test]
    fn reupload_required_is_recognized_and_never_proves_release() {
        let json = r#"{"chunkId":"c1","sourceId":"s1","sequence":0,"state":"reupload_required","receiptVersion":2,"errorCode":"HASH_MISMATCH"}"#;
        let receipt: Receipt = serde_json::from_str(json).unwrap();
        assert!(receipt.is_reupload_required());
        assert!(!receipt.proves_safe_audio_release());
    }

    #[test]
    fn a_json_null_for_a_proof_field_is_treated_the_same_as_an_absent_field() {
        let json = r#"{
            "chunkId": "c1", "sourceId": "s1", "sequence": 0, "state": "transcribed",
            "receiptVersion": 1, "transcriptSha256": null,
            "persistedAt": "2026-08-25T00:00:00.000Z",
            "serverAudioDeletedAt": "2026-08-25T00:00:01.000Z"
        }"#;
        let receipt: Receipt = serde_json::from_str(json).unwrap();
        assert!(!receipt.proves_safe_audio_release());
    }
}
