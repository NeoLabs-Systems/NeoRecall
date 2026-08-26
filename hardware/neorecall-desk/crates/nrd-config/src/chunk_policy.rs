//! Chunk sizing policy. `ChunkPolicy` holds *local safety bounds* — the
//! device's own opinion of a sane chunk shape, independent of the server.
//! The server's `/meta` limits and a user's per-account `/settings`
//! overrides are merged *inside* those bounds by `EffectivePolicy::compute`,
//! so a misconfigured or malicious server response can never push the
//! device outside what it considers safe (e.g. an absurdly long chunk that
//! would hold audio in memory for hours).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkPolicy {
    pub target_ms: u32,
    pub overlap_ms: u32,
    pub min_ms_floor: u32,
    pub max_ms_ceiling: u32,
    pub max_upload_bytes_ceiling: u64,
    /// Overlap may never exceed this fraction of the effective target
    /// duration, regardless of what the server or user settings request.
    pub overlap_max_ratio: f64,
    pub max_session_ms: u64,
}

/// The subset of `GET /api/v1/meta`'s `limits` object this crate consumes.
#[derive(Debug, Clone, Copy)]
pub struct ServerChunkLimits {
    pub chunk_min_ms: u32,
    pub chunk_max_ms: u32,
    pub chunk_target_ms: u32,
    pub chunk_overlap_ms: u32,
    pub max_upload_bytes: u64,
    pub chunk_receipt_batch: u32,
}

/// The optional per-account overrides from `GET /api/v1/settings`. `/meta`
/// reports process config only, not a signed-in user's preference — a
/// device that wants the user's preference must read `/settings` (and needs
/// the `settings:read` scope to do so; it is optional).
#[derive(Debug, Clone, Copy, Default)]
pub struct UserChunkOverrides {
    pub target_ms: Option<u32>,
    pub overlap_ms: Option<u32>,
}

/// The chunk shape actually in force, after merging server limits and user
/// overrides into the local safety bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectivePolicy {
    pub min_ms: u32,
    pub max_ms: u32,
    pub target_ms: u32,
    pub overlap_ms: u32,
    pub max_upload_bytes: u64,
    pub receipt_batch: u32,
}

impl ChunkPolicy {
    pub fn compute_effective(
        &self,
        server: ServerChunkLimits,
        user: UserChunkOverrides,
    ) -> Result<EffectivePolicy, String> {
        let min_ms = server.chunk_min_ms.max(self.min_ms_floor);
        let max_ms = server.chunk_max_ms.min(self.max_ms_ceiling);
        if min_ms > max_ms {
            return Err(format!(
                "server chunk bounds [{}, {}] and local safety bounds [{}, {}] do not overlap",
                server.chunk_min_ms, server.chunk_max_ms, self.min_ms_floor, self.max_ms_ceiling
            ));
        }

        let requested_target = user.target_ms.unwrap_or(server.chunk_target_ms);
        let target_ms = requested_target.clamp(min_ms, max_ms);

        let requested_overlap = user.overlap_ms.unwrap_or(server.chunk_overlap_ms);
        let overlap_ceiling_from_ratio =
            ((target_ms as f64) * self.overlap_max_ratio).floor() as u32;
        // An overlap must never reach the full chunk (the server also requires
        // overlap_ms <= chunkMaxMs - 1); leave at least 1 ms of non-overlapping
        // audio in every chunk.
        let overlap_ceiling = overlap_ceiling_from_ratio.min(target_ms.saturating_sub(1));
        let overlap_ms = requested_overlap.min(overlap_ceiling);

        let max_upload_bytes = server.max_upload_bytes.min(self.max_upload_bytes_ceiling);

        Ok(EffectivePolicy {
            min_ms,
            max_ms,
            target_ms,
            overlap_ms,
            max_upload_bytes,
            receipt_batch: server.chunk_receipt_batch,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local_policy() -> ChunkPolicy {
        ChunkPolicy {
            target_ms: 30_000,
            overlap_ms: 1_500,
            min_ms_floor: 5_000,
            max_ms_ceiling: 120_000,
            max_upload_bytes_ceiling: 33_554_432,
            overlap_max_ratio: 0.25,
            max_session_ms: 43_200_000,
        }
    }

    fn server_limits() -> ServerChunkLimits {
        ServerChunkLimits {
            chunk_min_ms: 15_000,
            chunk_max_ms: 120_000,
            chunk_target_ms: 30_000,
            chunk_overlap_ms: 2_000,
            max_upload_bytes: 33_554_432,
            chunk_receipt_batch: 500,
        }
    }

    #[test]
    fn with_no_user_override_the_effective_policy_matches_server_limits() {
        let effective = local_policy()
            .compute_effective(server_limits(), UserChunkOverrides::default())
            .unwrap();
        assert_eq!(effective.target_ms, 30_000);
        assert_eq!(effective.overlap_ms, 2_000);
        assert_eq!(effective.min_ms, 15_000);
        assert_eq!(effective.max_ms, 120_000);
    }

    #[test]
    fn a_user_target_override_is_honored_within_bounds() {
        let user = UserChunkOverrides {
            target_ms: Some(45_000),
            overlap_ms: None,
        };
        let effective = local_policy()
            .compute_effective(server_limits(), user)
            .unwrap();
        assert_eq!(effective.target_ms, 45_000);
    }

    #[test]
    fn a_server_target_above_the_local_ceiling_is_clamped_down() {
        let mut server = server_limits();
        server.chunk_target_ms = 500_000;
        server.chunk_max_ms = 500_000;
        let effective = local_policy()
            .compute_effective(server, UserChunkOverrides::default())
            .unwrap();
        // The local safety ceiling (120_000) always wins over a server value.
        assert_eq!(effective.max_ms, 120_000);
        assert_eq!(effective.target_ms, 120_000);
    }

    #[test]
    fn a_server_target_below_the_local_floor_is_clamped_up() {
        let mut server = server_limits();
        server.chunk_min_ms = 1_000;
        server.chunk_target_ms = 1_000;
        let effective = local_policy()
            .compute_effective(server, UserChunkOverrides::default())
            .unwrap();
        // The local safety floor (5_000) always wins over a server value.
        assert_eq!(effective.min_ms, 5_000);
        assert_eq!(effective.target_ms, 5_000);
    }

    #[test]
    fn overlap_never_exceeds_the_configured_ratio_of_the_target() {
        let user = UserChunkOverrides {
            target_ms: Some(20_000),
            overlap_ms: Some(19_000),
        };
        let effective = local_policy()
            .compute_effective(server_limits(), user)
            .unwrap();
        assert_eq!(effective.target_ms, 20_000);
        // 25% of 20_000 is 5_000; the requested 19_000 must be clamped down to it.
        assert_eq!(effective.overlap_ms, 5_000);
    }

    #[test]
    fn overlap_leaves_at_least_one_millisecond_of_non_overlapping_audio() {
        let mut local = local_policy();
        local.overlap_max_ratio = 1.0; // pathological profile: allow up to 100%
        local.min_ms_floor = 1; // let the target actually land at 1_000, unclamped
        let mut server = server_limits();
        server.chunk_min_ms = 1;
        let user = UserChunkOverrides {
            target_ms: Some(1_000),
            overlap_ms: Some(1_000),
        };
        let effective = local.compute_effective(server, user).unwrap();
        assert_eq!(effective.target_ms, 1_000);
        assert_eq!(effective.overlap_ms, 999);
    }

    #[test]
    fn max_upload_bytes_is_the_tighter_of_server_and_local_ceiling() {
        let mut server = server_limits();
        server.max_upload_bytes = 100_000_000;
        let effective = local_policy()
            .compute_effective(server, UserChunkOverrides::default())
            .unwrap();
        assert_eq!(effective.max_upload_bytes, 33_554_432);
    }

    #[test]
    fn contradictory_bounds_fail_loudly_instead_of_silently_clamping() {
        let mut local = local_policy();
        local.min_ms_floor = 200_000; // above the server's own max
        let result = local.compute_effective(server_limits(), UserChunkOverrides::default());
        assert!(result.is_err());
    }
}
