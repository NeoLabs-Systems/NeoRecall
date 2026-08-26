//! Cross-field validation. Startup fails loudly on anything here — a bad
//! profile or operator override must stop the appliance from starting, not
//! be silently clamped into something that merely happens to run.

use crate::error::ConfigError;
use crate::Config;

pub fn validate(config: &Config) -> Result<(), ConfigError> {
    let mut problems = Vec::new();

    if config.chunk.min_ms_floor > config.chunk.max_ms_ceiling {
        problems.push(format!(
            "chunk.min_ms_floor ({}) must not exceed chunk.max_ms_ceiling ({})",
            config.chunk.min_ms_floor, config.chunk.max_ms_ceiling
        ));
    }
    if !(0.0..=1.0).contains(&config.chunk.overlap_max_ratio) {
        problems.push(format!(
            "chunk.overlap_max_ratio ({}) must be within [0, 1]",
            config.chunk.overlap_max_ratio
        ));
    }
    if config.chunk.max_upload_bytes_ceiling == 0 {
        problems.push("chunk.max_upload_bytes_ceiling must be greater than zero".to_string());
    }

    if config.storage.reserve_bytes == 0 {
        problems.push("storage.reserve_bytes must be greater than zero".to_string());
    }
    if !(0.0..1.0).contains(&config.storage.soft_ratio)
        || !(0.0..1.0).contains(&config.storage.hard_ratio)
    {
        problems.push(
            "storage.soft_ratio and storage.hard_ratio must each be within [0, 1)".to_string(),
        );
    } else if config.storage.soft_ratio >= config.storage.hard_ratio {
        problems.push(format!(
            "storage.soft_ratio ({}) must be lower than storage.hard_ratio ({})",
            config.storage.soft_ratio, config.storage.hard_ratio
        ));
    }

    if !config.audio.is_integer_decimation_ratio() {
        problems.push(format!(
            "audio.capture_rate ({}) is not an integer multiple of audio.upload_rate ({}); the fixed polyphase decimator requires an exact ratio",
            config.audio.capture_rate, config.audio.upload_rate
        ));
    }
    if config.audio.aec.max_cpu_percent == 0 || config.audio.aec.max_cpu_percent > 100 {
        problems.push(format!(
            "audio.aec.max_cpu_percent ({}) must be within (0, 100]",
            config.audio.aec.max_cpu_percent
        ));
    }

    // Hard product invariant, not merely a default: Desk must never expose a
    // USB microphone to the host.
    if config.hardware.usb_gadget.uac2.p_chmask != 0 {
        problems.push(format!(
            "hardware.usb_gadget.uac2.p_chmask must be 0 (output-only gadget); got {}",
            config.hardware.usb_gadget.uac2.p_chmask
        ));
    }
    if config.hardware.usb_gadget.uac2.c_chmask == 0 {
        problems.push(
            "hardware.usb_gadget.uac2.c_chmask must declare at least one playback channel"
                .to_string(),
        );
    }
    if config.hardware.wm8960.max_playback_percent == 0
        || config.hardware.wm8960.max_playback_percent > 100
    {
        problems.push(format!(
            "hardware.wm8960.max_playback_percent ({}) must be within (0, 100]",
            config.hardware.wm8960.max_playback_percent
        ));
    }
    if config.hardware.wm8960.startup_playback_percent > config.hardware.wm8960.max_playback_percent
    {
        problems.push(
            "hardware.wm8960.startup_playback_percent must not exceed max_playback_percent"
                .to_string(),
        );
    }
    if !config.hardware.wm8960.button_gpio_disabled {
        problems.push("hardware.wm8960.button_gpio_disabled must be true: GPIO17 is reserved for the display touch interrupt".to_string());
    }

    // Server enum invariant: server/routes/devices.js only accepts this
    // literal set, and Desk must register as "appliance".
    if config.device.kind != "appliance" {
        problems.push(format!(
            "device.kind must be \"appliance\"; got \"{}\"",
            config.device.kind
        ));
    }
    if !config.device.scopes.iter().any(|s| s == "ingest:write") {
        problems.push("device.scopes must include \"ingest:write\"".to_string());
    }

    if config.network.backoff_base_ms > config.network.backoff_max_ms {
        problems.push("network.backoff_base_ms must not exceed network.backoff_max_ms".to_string());
    }
    if config.network.upload_concurrency == 0 {
        problems.push("network.upload_concurrency must be at least 1".to_string());
    }
    if !(0.0..=1.0).contains(&config.network.backoff_jitter_ratio) {
        problems.push(format!(
            "network.backoff_jitter_ratio ({}) must be within [0, 1]",
            config.network.backoff_jitter_ratio
        ));
    }
    if config.network.base_url.is_empty() {
        // Empty is legitimate before enrollment; nrd-enroll is responsible
        // for populating it. Not a validation failure on its own.
    } else if !config.network.base_url.starts_with("https://") && !config.network.allow_insecure_tls
    {
        problems.push("network.base_url must use https:// unless network.allow_insecure_tls is explicitly enabled".to_string());
    }

    if problems.is_empty() {
        Ok(())
    } else {
        Err(ConfigError::Validation(problems.join("; ")))
    }
}
