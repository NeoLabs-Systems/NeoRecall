use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageConfig {
    pub root: String,
    pub reserve_bytes: u64,
    pub soft_ratio: f64,
    pub hard_ratio: f64,
    pub fsync_dir_on_rename: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PressureLevel {
    Normal,
    Soft,
    Hard,
}

impl StorageConfig {
    /// Never deletes anything — the caller decides what to do with the
    /// level (warn, prioritize drain, finalize capture with a `storage_full`
    /// gap). Audio is never discarded to make room; see `AGENTS.md`.
    pub fn pressure(&self, total_bytes: u64, available_bytes: u64) -> PressureLevel {
        if total_bytes == 0 {
            return PressureLevel::Normal;
        }
        let used_ratio = 1.0 - (available_bytes as f64 / total_bytes as f64);
        let below_reserve = available_bytes < self.reserve_bytes;
        if below_reserve || used_ratio >= self.hard_ratio {
            PressureLevel::Hard
        } else if used_ratio >= self.soft_ratio {
            PressureLevel::Soft
        } else {
            PressureLevel::Normal
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> StorageConfig {
        StorageConfig {
            root: "/var/lib/neorecall-device".to_string(),
            reserve_bytes: 512 * 1024 * 1024,
            soft_ratio: 0.80,
            hard_ratio: 0.93,
            fsync_dir_on_rename: true,
        }
    }

    #[test]
    fn plenty_of_free_space_is_normal() {
        assert_eq!(
            config().pressure(32_000_000_000, 20_000_000_000),
            PressureLevel::Normal
        );
    }

    #[test]
    fn crossing_the_soft_ratio_warns() {
        assert_eq!(
            config().pressure(10_000_000_000, 1_500_000_000),
            PressureLevel::Soft
        );
    }

    #[test]
    fn crossing_the_hard_ratio_finalizes() {
        assert_eq!(
            config().pressure(10_000_000_000, 600_000_000),
            PressureLevel::Hard
        );
    }

    #[test]
    fn dropping_below_the_absolute_reserve_is_hard_even_on_a_huge_disk() {
        // 1% free on a 1 TB disk is far below both ratios numerically small,
        // but the absolute reserve_bytes floor must still trip Hard.
        assert_eq!(
            config().pressure(1_000_000_000_000, 100_000_000),
            PressureLevel::Hard
        );
    }
}
