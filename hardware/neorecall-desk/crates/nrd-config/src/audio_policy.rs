use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Resampler {
    pub taps: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AecConfig {
    pub enabled: bool,
    pub module: String,
    pub library: String,
    pub analog_gain_controller: bool,
    pub noise_suppression: bool,
    pub high_pass_filter: bool,
    pub echo_canceller: bool,
    /// Measured CPU guard from the R2 `nrd-bench` gate. AEC is unloaded, not
    /// throttled, if this is ever exceeded — playback and recording must not
    /// degrade to accommodate it.
    pub max_cpu_percent: u8,
    /// Outputs on which AEC is never loaded (no acoustic loopback into the
    /// room mics when playing over Bluetooth).
    pub disable_on_output: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioConfig {
    pub capture_rate: u32,
    pub upload_rate: u32,
    pub upload_format: String,
    pub upload_layout: String,
    /// PipeWire graph quantum (frames per period). Large by default: Desk has
    /// no interactive latency requirement, and a bigger quantum is the
    /// cheapest available CPU headroom for AEC (Risk R2).
    pub quantum: u32,
    pub ring_capacity_ms: u32,
    pub ui_refresh_hz: u32,
    pub resampler: Resampler,
    pub aec: AecConfig,
}

impl AudioConfig {
    /// Whether the resample ratio from `capture_rate` to `upload_rate` is the
    /// exact integer ratio the fixed polyphase decimator in `nrd-audio`
    /// requires. `nrd-config` validates this rather than letting a bad
    /// profile silently produce pitch-shifted audio.
    pub fn is_integer_decimation_ratio(&self) -> bool {
        self.capture_rate > 0
            && self.upload_rate > 0
            && self.capture_rate.is_multiple_of(self.upload_rate)
    }

    pub fn decimation_ratio(&self) -> u32 {
        self.capture_rate / self.upload_rate
    }
}
