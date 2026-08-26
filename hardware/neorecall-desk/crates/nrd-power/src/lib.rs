//! Undervoltage/throttle detection and the mute debounce policy.
//!
//! The spec's hard rule: **never silently continue amplified playback while
//! the Pi reports unstable power.** Muting is immediate and unconditional
//! the moment any configured condition is observed; only *recovery*
//! (un-muting) is debounced, so a flapping power rail cannot chatter the
//! amplifier on and off.

use std::path::PathBuf;

use nrd_config::{PowerConfig, ThrottleState};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PowerError {
    #[error("could not read throttle source {path}: {source}")]
    Io {
        path: String,
        source: std::io::Error,
    },
    #[error("could not parse throttle value {raw:?}")]
    Parse { raw: String },
}

/// Reads and parses the Raspberry Pi firmware's throttle status. Accepts
/// both the raw sysfs format (a bare hex value, e.g. `0x50005`) and the
/// `vcgencmd get_throttled` output format (`throttled=0x50005`), trimming
/// whitespace, so a profile can point `throttle_source` at either without a
/// code change.
pub struct ThrottleReader {
    path: PathBuf,
}

impl ThrottleReader {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        ThrottleReader { path: path.into() }
    }

    pub fn read_raw(&self) -> Result<u32, PowerError> {
        let text = std::fs::read_to_string(&self.path).map_err(|source| PowerError::Io {
            path: self.path.display().to_string(),
            source,
        })?;
        parse_throttled(&text).ok_or(PowerError::Parse { raw: text })
    }
}

pub fn parse_throttled(text: &str) -> Option<u32> {
    let trimmed = text.trim();
    let hex_part = trimmed.strip_prefix("throttled=").unwrap_or(trimmed);
    let hex_digits = hex_part
        .strip_prefix("0x")
        .or_else(|| hex_part.strip_prefix("0X"))
        .unwrap_or(hex_part);
    u32::from_str_radix(hex_digits, 16).ok()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuteAction {
    Mute,
    StayMuted,
    Unmute,
    StayUnmuted,
}

/// Debounces recovery so a flapping power rail cannot rapidly toggle the
/// amplifier. `now_ms` is supplied by the caller (a monotonic clock) rather
/// than read internally, keeping this deterministic and unit-testable
/// without real time.
pub struct MuteDebouncer {
    config: PowerConfig,
    muted: bool,
    clear_since_ms: Option<u64>,
}

impl MuteDebouncer {
    pub fn new(config: PowerConfig) -> Self {
        MuteDebouncer {
            config,
            muted: false,
            clear_since_ms: None,
        }
    }

    pub fn is_muted(&self) -> bool {
        self.muted
    }

    pub fn observe(&mut self, state: ThrottleState, now_ms: u64) -> MuteAction {
        if self.config.should_mute(state) {
            self.clear_since_ms = None;
            if self.muted {
                return MuteAction::StayMuted;
            }
            self.muted = true;
            return MuteAction::Mute;
        }

        if !self.muted {
            return MuteAction::StayUnmuted;
        }
        match self.clear_since_ms {
            None => {
                self.clear_since_ms = Some(now_ms);
                MuteAction::StayMuted
            }
            Some(since)
                if now_ms.saturating_sub(since) >= self.config.recovery_debounce_ms as u64 =>
            {
                self.muted = false;
                self.clear_since_ms = None;
                MuteAction::Unmute
            }
            Some(_) => MuteAction::StayMuted,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn config() -> PowerConfig {
        PowerConfig {
            poll_interval_ms: 1000,
            throttle_source: "unused-in-tests".to_string(),
            undervoltage_bit: 0,
            freq_capped_bit: 1,
            throttled_bit: 2,
            soft_temp_bit: 3,
            mute_on: vec!["undervoltage_now".to_string(), "throttled_now".to_string()],
            recovery_debounce_ms: 15_000,
        }
    }

    #[test]
    fn parses_the_bare_sysfs_format() {
        assert_eq!(parse_throttled("0x50005\n"), Some(0x50005));
    }

    #[test]
    fn parses_the_vcgencmd_prefixed_format() {
        assert_eq!(parse_throttled("throttled=0x50005\n"), Some(0x50005));
    }

    #[test]
    fn rejects_unparseable_content() {
        assert_eq!(parse_throttled("not a hex value"), None);
    }

    #[test]
    fn reads_and_parses_a_real_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("get_throttled");
        std::fs::write(&path, "0x1\n").unwrap();
        assert_eq!(ThrottleReader::new(&path).read_raw().unwrap(), 1);
    }

    #[test]
    fn a_missing_file_is_an_io_error_not_a_silent_zero() {
        let result = ThrottleReader::new(Path::new("/definitely/missing/get_throttled")).read_raw();
        assert!(matches!(result, Err(PowerError::Io { .. })));
    }

    #[test]
    fn mutes_immediately_on_the_first_bad_reading_no_debounce() {
        let mut debouncer = MuteDebouncer::new(config());
        let bad = ThrottleState {
            undervoltage_now: true,
            ..Default::default()
        };
        assert_eq!(debouncer.observe(bad, 0), MuteAction::Mute);
        assert!(debouncer.is_muted());
    }

    #[test]
    fn does_not_unmute_until_the_recovery_debounce_elapses() {
        // The debounce clock starts at the first clear reading (1_000), not
        // at the original bad reading (0) -- 15s of continuous clearness is
        // required, so the earliest possible unmute is at 1_000 + 15_000.
        let mut debouncer = MuteDebouncer::new(config());
        let bad = ThrottleState {
            undervoltage_now: true,
            ..Default::default()
        };
        let clear = ThrottleState::default();

        debouncer.observe(bad, 0);
        assert_eq!(debouncer.observe(clear, 1_000), MuteAction::StayMuted);
        assert_eq!(debouncer.observe(clear, 10_000), MuteAction::StayMuted);
        assert_eq!(debouncer.observe(clear, 16_000), MuteAction::Unmute);
        assert!(!debouncer.is_muted());
    }

    #[test]
    fn a_flapping_condition_resets_the_debounce_timer_and_never_unmutes_early() {
        let mut debouncer = MuteDebouncer::new(config());
        let bad = ThrottleState {
            undervoltage_now: true,
            ..Default::default()
        };
        let clear = ThrottleState::default();

        debouncer.observe(bad, 0);
        debouncer.observe(clear, 10_000); // clear_since = 10_000
        debouncer.observe(bad, 12_000); // flaps bad again, clears the timer
                                        // 24_000 is the first clear reading since the 12_000 flap, so the
                                        // debounce clock restarts here, not back at 10_000.
        assert_eq!(debouncer.observe(clear, 24_000), MuteAction::StayMuted);
        assert_eq!(debouncer.observe(clear, 38_000), MuteAction::StayMuted); // only 14s since 24_000
        assert_eq!(debouncer.observe(clear, 39_000), MuteAction::Unmute); // now 15s since 24_000
    }

    #[test]
    fn staying_clear_the_whole_time_never_mutes() {
        let mut debouncer = MuteDebouncer::new(config());
        for t in (0..60_000).step_by(1_000) {
            assert_eq!(
                debouncer.observe(ThrottleState::default(), t),
                MuteAction::StayUnmuted
            );
        }
    }

    #[test]
    fn a_condition_not_in_mute_on_never_triggers_a_mute() {
        let mut debouncer = MuteDebouncer::new(config());
        let freq_capped_only = ThrottleState {
            freq_capped_now: true,
            ..Default::default()
        };
        assert_eq!(
            debouncer.observe(freq_capped_only, 0),
            MuteAction::StayUnmuted
        );
    }
}
