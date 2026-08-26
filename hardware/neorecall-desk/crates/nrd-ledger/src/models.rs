use crate::chunk_state::ChunkState;

#[derive(Debug, Clone)]
pub struct SessionRow {
    pub id: String,
    pub account_id: String,
    pub device_id: String,
    pub started_at_epoch_ms: Option<i64>,
    pub started_at_mono_ms: i64,
    pub boot_id: String,
    pub timezone: String,
    pub clock_offset_ms: i64,
    pub consent_attested_at: String,
    pub ended_at: Option<String>,
    pub status: Option<String>,
    pub declared: bool,
    pub close_synced: bool,
    pub declare_fail_count: i64,
    pub last_declare_error: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    System,
    Microphone,
}

impl SourceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SourceKind::System => "system",
            SourceKind::Microphone => "microphone",
        }
    }
}

impl std::str::FromStr for SourceKind {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "system" => Ok(SourceKind::System),
            "microphone" => Ok(SourceKind::Microphone),
            other => Err(format!("unknown source kind {other:?}")),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SourceRow {
    pub id: String,
    pub session_id: String,
    pub kind: SourceKind,
    pub channel_layout: String,
    pub sample_rate: i64,
    pub sample_format: String,
    pub metadata_json: String,
    pub next_sequence: i64,
    pub next_offset_ms: i64,
    pub final_sequence: i64,
    pub closed: bool,
    pub close_synced: bool,
    pub declared: bool,
    pub created_at: String,
}

#[derive(Debug, Clone)]
pub struct ChunkRow {
    pub local_id: String,
    pub session_id: String,
    pub source_id: String,
    pub sequence: i64,
    pub server_chunk_id: Option<String>,
    pub monotonic_offset_ms: i64,
    pub duration_ms: i64,
    pub overlap_ms: i64,
    pub channel_layout: String,
    pub container: String,
    pub codec: String,
    pub content_encoding: String,
    pub sha256: String,
    pub byte_size: i64,
    pub is_final: bool,
    pub file_path: Option<String>,
    pub state: ChunkState,
    pub fail_count: i64,
    pub reupload_attempts: i64,
    pub next_attempt_at: Option<String>,
    pub receipt_json: Option<String>,
    pub last_error: Option<String>,
    pub created_at: String,
    pub uploaded_at: Option<String>,
    pub terminal_at: Option<String>,
    pub released_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NewGap {
    pub id: String,
    pub session_id: String,
    pub source_id: String,
    pub start_offset_ms: i64,
    pub end_offset_ms: i64,
    pub start_sequence: Option<i64>,
    pub end_sequence: Option<i64>,
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct GapRow {
    pub id: String,
    pub session_id: String,
    pub source_id: String,
    pub start_offset_ms: i64,
    pub end_offset_ms: i64,
    pub start_sequence: Option<i64>,
    pub end_sequence: Option<i64>,
    pub reason: String,
    pub synced: bool,
    pub created_at: String,
}
