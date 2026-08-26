//! Layered, validated configuration for NeoRecall Desk.
//!
//! Nothing tunable belongs as a literal in any other crate — hardware
//! identifiers, chunk policy, power/storage limits, retry counts, and the
//! supported OS/kernel range all live here (`AGENTS.md`: "Do not hardcode
//! scenario-specific behavior. Centralize configurable thresholds and
//! limits.").
//!
//! Layering (lowest to highest precedence): the shipped hardware profile
//! (`profiles/<profile>.toml`, required — it *is* the product's defaults,
//! since a device with no hardware profile is not meaningful) →
//! `/etc/neorecall-desk/config.toml` (optional operator overrides) →
//! `NRD_*` environment variables (see `layers::apply_env_overrides`). Layers
//! are deep-merged as `toml::Value` trees before a single typed
//! deserialization, so a partial override file only touches the keys it
//! names — see `layers::merge_toml`.

mod audio_policy;
mod chunk_policy;
mod error;
mod hardware;
mod layers;
mod network;
mod power;
mod storage;
mod support_matrix;
mod validate;

pub use audio_policy::{AecConfig, AudioConfig, Resampler};
pub use chunk_policy::{ChunkPolicy, EffectivePolicy, ServerChunkLimits, UserChunkOverrides};
pub use error::ConfigError;
pub use hardware::{DisplayProfile, HardwareProfile, Uac2Params, UsbGadgetProfile, Wm8960Profile};
pub use network::{DeviceConfig, NetworkConfig};
pub use power::{PowerConfig, ThrottleState};
pub use storage::{PressureLevel, StorageConfig};
pub use support_matrix::SupportMatrix;

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub schema_version: u32,
    pub profile: String,
    pub support: SupportMatrix,
    pub hardware: HardwareProfile,
    pub audio: AudioConfig,
    pub chunk: ChunkPolicy,
    pub storage: StorageConfig,
    pub network: NetworkConfig,
    pub device: DeviceConfig,
    pub power: PowerConfig,
}

/// The file paths for each config layer. `profile_path` must exist;
/// `operator_override_path` is read only if present.
#[derive(Debug, Clone)]
pub struct LoadPaths {
    pub profile_path: PathBuf,
    pub operator_override_path: PathBuf,
}

impl Config {
    /// Loads and validates the layered config. Environment variables are
    /// read from the process environment; see `load_with_env` to inject a
    /// specific set (used by tests, and by anything that wants
    /// reproducible behavior independent of the ambient environment).
    pub fn load(paths: &LoadPaths) -> Result<Config, ConfigError> {
        Self::load_with_env(paths, std::env::vars())
    }

    pub fn load_with_env<I>(paths: &LoadPaths, env: I) -> Result<Config, ConfigError>
    where
        I: IntoIterator<Item = (String, String)>,
    {
        let profile_text =
            std::fs::read_to_string(&paths.profile_path).map_err(|source| ConfigError::Io {
                path: paths.profile_path.display().to_string(),
                source,
            })?;
        let mut merged: toml::Value =
            toml::from_str(&profile_text).map_err(|source| ConfigError::Parse {
                path: paths.profile_path.display().to_string(),
                source,
            })?;

        if let Some(overlay) = layers::read_optional_toml_file(&paths.operator_override_path)? {
            layers::merge_toml(&mut merged, overlay);
        }

        layers::apply_env_overrides(&mut merged, env);

        let config: Config = merged.try_into().map_err(|source| ConfigError::Parse {
            path: format!(
                "{} (merged with {})",
                paths.profile_path.display(),
                paths.operator_override_path.display()
            ),
            source,
        })?;

        validate::validate(&config)?;
        Ok(config)
    }

    /// Convenience for the common case: the shipped profile plus the
    /// standard operator-override location.
    pub fn load_standard(profile_path: impl AsRef<Path>) -> Result<Config, ConfigError> {
        Self::load(&LoadPaths {
            profile_path: profile_path.as_ref().to_path_buf(),
            operator_override_path: PathBuf::from("/etc/neorecall-desk/config.toml"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn shipped_profile_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../profiles/pi-zero2w-wm8960-elegoo480x320.toml")
    }

    #[test]
    fn the_shipped_profile_loads_and_validates_on_its_own() {
        let config = Config::load(&LoadPaths {
            profile_path: shipped_profile_path(),
            operator_override_path: PathBuf::from("/nonexistent/config.toml"),
        })
        .unwrap();
        assert_eq!(config.device.kind, "appliance");
        assert_eq!(config.hardware.usb_gadget.uac2.p_chmask, 0);
    }

    #[test]
    fn a_missing_operator_override_file_is_not_an_error() {
        let result = Config::load(&LoadPaths {
            profile_path: shipped_profile_path(),
            operator_override_path: PathBuf::from("/definitely/does/not/exist.toml"),
        });
        assert!(result.is_ok());
    }

    #[test]
    fn a_missing_profile_file_is_an_error() {
        let result = Config::load(&LoadPaths {
            profile_path: PathBuf::from("/definitely/does/not/exist.toml"),
            operator_override_path: PathBuf::from("/also/missing.toml"),
        });
        assert!(matches!(result, Err(ConfigError::Io { .. })));
    }

    #[test]
    fn an_operator_override_file_changes_only_the_keys_it_sets() {
        let mut override_file = tempfile::NamedTempFile::new().unwrap();
        writeln!(override_file, "[audio.aec]\nmax_cpu_percent = 20\n").unwrap();

        let config = Config::load(&LoadPaths {
            profile_path: shipped_profile_path(),
            operator_override_path: override_file.path().to_path_buf(),
        })
        .unwrap();
        assert_eq!(config.audio.aec.max_cpu_percent, 20);
        // Untouched by the override, still the shipped default.
        assert!(config.audio.aec.enabled);
    }

    #[test]
    fn an_env_override_takes_precedence_over_the_operator_file() {
        let mut override_file = tempfile::NamedTempFile::new().unwrap();
        writeln!(
            override_file,
            "[network]\nbase_url = \"https://from-file.example.com\"\n"
        )
        .unwrap();

        let config = Config::load_with_env(
            &LoadPaths {
                profile_path: shipped_profile_path(),
                operator_override_path: override_file.path().to_path_buf(),
            },
            vec![(
                "NRD_NETWORK__BASE_URL".to_string(),
                "https://from-env.example.com".to_string(),
            )],
        )
        .unwrap();
        assert_eq!(config.network.base_url, "https://from-env.example.com");
    }

    #[test]
    fn an_invalid_override_fails_loudly_rather_than_starting_with_a_broken_config() {
        let mut override_file = tempfile::NamedTempFile::new().unwrap();
        // Violates the hard output-only invariant.
        writeln!(override_file, "[hardware.usb_gadget.uac2]\np_chmask = 2\nc_chmask = 3\nc_srate = 48000\nc_ssize = 2\n").unwrap();

        let result = Config::load(&LoadPaths {
            profile_path: shipped_profile_path(),
            operator_override_path: override_file.path().to_path_buf(),
        });
        assert!(matches!(result, Err(ConfigError::Validation(_))));
    }

    #[test]
    fn empty_base_url_is_allowed_before_enrollment() {
        // Not asserted elsewhere: an appliance fresh out of the box has no
        // server URL yet, and that must not be a validation failure.
        let mut override_file = tempfile::NamedTempFile::new().unwrap();
        writeln!(override_file, "[network]\nbase_url = \"\"\n").unwrap();
        let config = Config::load(&LoadPaths {
            profile_path: shipped_profile_path(),
            operator_override_path: override_file.path().to_path_buf(),
        })
        .unwrap();
        assert_eq!(config.network.base_url, "");
    }
}
