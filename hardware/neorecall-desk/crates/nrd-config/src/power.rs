use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PowerConfig {
    pub poll_interval_ms: u32,
    /// e.g. `/sys/devices/platform/soc/soc:firmware/get_throttled`. Preferred
    /// over shelling out to `vcgencmd`.
    pub throttle_source: String,
    pub undervoltage_bit: u8,
    pub freq_capped_bit: u8,
    pub throttled_bit: u8,
    pub soft_temp_bit: u8,
    /// Which decoded conditions trigger an immediate amp mute.
    pub mute_on: Vec<String>,
    pub recovery_debounce_ms: u32,
}

/// Decoded bits from `get_throttled`, per
/// <https://www.raspberrypi.com/documentation/computers/os.html#get_throttled>.
/// Field names, not bit positions, are load-bearing here — the bit positions
/// themselves are config so a future SoC revision is a data change.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ThrottleState {
    pub undervoltage_now: bool,
    pub freq_capped_now: bool,
    pub throttled_now: bool,
    pub soft_temp_limit_now: bool,
}

impl PowerConfig {
    pub fn decode(&self, raw: u32) -> ThrottleState {
        ThrottleState {
            undervoltage_now: raw & (1 << self.undervoltage_bit) != 0,
            freq_capped_now: raw & (1 << self.freq_capped_bit) != 0,
            throttled_now: raw & (1 << self.throttled_bit) != 0,
            soft_temp_limit_now: raw & (1 << self.soft_temp_bit) != 0,
        }
    }

    /// Whether this decoded state should trigger `mute_amp()`, per the
    /// operator-configured `mute_on` condition list.
    pub fn should_mute(&self, state: ThrottleState) -> bool {
        self.mute_on
            .iter()
            .any(|condition| match condition.as_str() {
                "undervoltage_now" => state.undervoltage_now,
                "freq_capped_now" => state.freq_capped_now,
                "throttled_now" => state.throttled_now,
                "soft_temp_limit_now" => state.soft_temp_limit_now,
                _ => false,
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> PowerConfig {
        PowerConfig {
            poll_interval_ms: 1000,
            throttle_source: "/sys/devices/platform/soc/soc:firmware/get_throttled".to_string(),
            undervoltage_bit: 0,
            freq_capped_bit: 1,
            throttled_bit: 2,
            soft_temp_bit: 3,
            mute_on: vec!["undervoltage_now".to_string(), "throttled_now".to_string()],
            recovery_debounce_ms: 15_000,
        }
    }

    #[test]
    fn decodes_the_documented_bit_layout() {
        // 0x50005 = undervoltage-now (bit 0) + throttled-now (bit 2) set,
        // matching the Raspberry Pi firmware's real encoding pattern (the
        // low nibble is "now", a higher nibble is "has happened since boot").
        let state = config().decode(0x0000_0005);
        assert!(state.undervoltage_now);
        assert!(!state.freq_capped_now);
        assert!(state.throttled_now);
        assert!(!state.soft_temp_limit_now);
    }

    #[test]
    fn zero_means_no_condition_is_active() {
        let state = config().decode(0);
        assert_eq!(state, ThrottleState::default());
        assert!(!config().should_mute(state));
    }

    #[test]
    fn should_mute_only_for_configured_conditions() {
        let cfg = config();
        let freq_capped_only = ThrottleState {
            freq_capped_now: true,
            ..Default::default()
        };
        // freq_capped_now is not in mute_on for this profile.
        assert!(!cfg.should_mute(freq_capped_only));

        let undervoltage = ThrottleState {
            undervoltage_now: true,
            ..Default::default()
        };
        assert!(cfg.should_mute(undervoltage));
    }
}
