use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    pub base_url: String,
    /// Must never be flipped to `true` by a code path in a release build —
    /// only by an explicit, on-screen operator choice during setup, and the
    /// UI must show a persistent warning while it is active. See
    /// `nrd-proto::tls`.
    pub allow_insecure_tls: bool,
    pub connect_timeout_ms: u32,
    pub request_timeout_ms: u32,
    pub upload_timeout_floor_ms: u32,
    pub idle_interval_ms: u32,
    pub drain_interval_ms: u32,
    pub upload_concurrency: u8,
    pub poll_batch: u32,
    pub gap_batch: u32,
    pub backoff_base_ms: u32,
    pub backoff_max_ms: u32,
    pub backoff_jitter_ratio: f64,
    pub reupload_budget: u8,
    pub heartbeat_interval_ms: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceConfig {
    /// The server's `devices.kind` enum value. Must stay `"appliance"` —
    /// see `server/routes/devices.js`.
    pub kind: String,
    pub platform: String,
    pub name_default: String,
    pub scopes: Vec<String>,
    pub optional_scopes: Vec<String>,
}
