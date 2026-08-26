//! Deterministic layered config: each layer is a (possibly partial) TOML
//! document. Layers are deep-merged as `toml::Value` trees — tables merge
//! key-by-key, recursively; any other value (scalar, array) in a later layer
//! replaces the earlier one outright. Only after every layer is merged is the
//! result deserialized into the typed `Config`, so a profile that sets only
//! `[audio.aec] max_cpu_percent = 30` does not reset the rest of `[audio]` to
//! built-in defaults.

use std::path::Path;

use crate::error::ConfigError;

/// Deep-merges `overlay` into `base` in place. A table key present in both
/// merges recursively; any other conflicting value type is replaced wholesale
/// by `overlay`'s value.
pub fn merge_toml(base: &mut toml::Value, overlay: toml::Value) {
    match (base, overlay) {
        (toml::Value::Table(base_table), toml::Value::Table(overlay_table)) => {
            for (key, overlay_value) in overlay_table {
                match base_table.get_mut(&key) {
                    Some(base_value) => merge_toml(base_value, overlay_value),
                    None => {
                        base_table.insert(key, overlay_value);
                    }
                }
            }
        }
        (base_slot, overlay_value) => *base_slot = overlay_value,
    }
}

/// Parses a TOML file and returns it as a `toml::Value`, or `Ok(None)` if the
/// file does not exist (an optional layer, e.g. the operator override file).
pub fn read_optional_toml_file(path: &Path) -> Result<Option<toml::Value>, ConfigError> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let value: toml::Value =
                toml::from_str(&text).map_err(|source| ConfigError::Parse {
                    path: path.display().to_string(),
                    source,
                })?;
            Ok(Some(value))
        }
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(ConfigError::Io {
            path: path.display().to_string(),
            source,
        }),
    }
}

/// Applies `NRD_*` environment overrides onto a merged `toml::Value` tree.
/// `NRD_AUDIO__AEC__MAX_CPU_PERCENT=30` sets `audio.aec.max_cpu_percent = 30`.
/// A double underscore (`__`) separates path segments; a single underscore is
/// kept as part of a segment name (so `NRD_HARDWARE__USB_GADGET__ID_VENDOR`
/// maps to `hardware.usb_gadget.id_vendor`). Values are parsed as TOML scalars
/// (bool, int, float) and fall back to a plain string.
pub fn apply_env_overrides<I>(base: &mut toml::Value, vars: I)
where
    I: IntoIterator<Item = (String, String)>,
{
    for (key, raw_value) in vars {
        let Some(rest) = key.strip_prefix("NRD_") else {
            continue;
        };
        if rest.is_empty() {
            continue;
        }
        let path: Vec<String> = rest
            .split("__")
            .map(|segment| segment.to_lowercase())
            .collect();
        if path.iter().any(|segment| segment.is_empty()) {
            continue;
        }
        set_path(base, &path, parse_scalar(&raw_value));
    }
}

fn parse_scalar(raw: &str) -> toml::Value {
    if let Ok(b) = raw.parse::<bool>() {
        return toml::Value::Boolean(b);
    }
    if let Ok(i) = raw.parse::<i64>() {
        return toml::Value::Integer(i);
    }
    if let Ok(f) = raw.parse::<f64>() {
        return toml::Value::Float(f);
    }
    toml::Value::String(raw.to_string())
}

fn set_path(root: &mut toml::Value, path: &[String], value: toml::Value) {
    if !root.is_table() {
        *root = toml::Value::Table(toml::map::Map::new());
    }
    let toml::Value::Table(table) = root else {
        unreachable!()
    };
    match path {
        [] => {}
        [last] => {
            table.insert(last.clone(), value);
        }
        [head, tail @ ..] => {
            let entry = table
                .entry(head.clone())
                .or_insert_with(|| toml::Value::Table(toml::map::Map::new()));
            set_path(entry, tail, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_keeps_sibling_keys_when_overlay_sets_one_leaf() {
        let mut base: toml::Value =
            toml::from_str("[audio.aec]\nenabled = true\nmax_cpu_percent = 45\n").unwrap();
        let overlay: toml::Value = toml::from_str("[audio.aec]\nmax_cpu_percent = 30\n").unwrap();
        merge_toml(&mut base, overlay);
        assert_eq!(base["audio"]["aec"]["enabled"].as_bool(), Some(true));
        assert_eq!(
            base["audio"]["aec"]["max_cpu_percent"].as_integer(),
            Some(30)
        );
    }

    #[test]
    fn merge_replaces_scalars_and_arrays_wholesale() {
        let mut base: toml::Value = toml::from_str("[support]\nos_ids = [\"raspbian\"]\n").unwrap();
        let overlay: toml::Value = toml::from_str("[support]\nos_ids = [\"debian\"]\n").unwrap();
        merge_toml(&mut base, overlay);
        let ids: Vec<&str> = base["support"]["os_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(ids, vec!["debian"]);
    }

    #[test]
    fn env_override_sets_a_nested_path_without_disturbing_siblings() {
        let mut base: toml::Value =
            toml::from_str("[audio.aec]\nenabled = true\nmax_cpu_percent = 45\n").unwrap();
        apply_env_overrides(
            &mut base,
            vec![(
                "NRD_AUDIO__AEC__MAX_CPU_PERCENT".to_string(),
                "30".to_string(),
            )],
        );
        assert_eq!(
            base["audio"]["aec"]["max_cpu_percent"].as_integer(),
            Some(30)
        );
        assert_eq!(base["audio"]["aec"]["enabled"].as_bool(), Some(true));
    }

    #[test]
    fn env_override_creates_missing_intermediate_tables() {
        let mut base = toml::Value::Table(toml::map::Map::new());
        apply_env_overrides(
            &mut base,
            vec![(
                "NRD_NETWORK__BASE_URL".to_string(),
                "https://example.com".to_string(),
            )],
        );
        assert_eq!(
            base["network"]["base_url"].as_str(),
            Some("https://example.com")
        );
    }

    #[test]
    fn env_override_parses_booleans_and_numbers_but_falls_back_to_string() {
        let mut base = toml::Value::Table(toml::map::Map::new());
        apply_env_overrides(
            &mut base,
            vec![
                (
                    "NRD_NETWORK__ALLOW_INSECURE_TLS".to_string(),
                    "true".to_string(),
                ),
                ("NRD_CHUNK__TARGET_MS".to_string(), "30000".to_string()),
                (
                    "NRD_DEVICE__PLATFORM".to_string(),
                    "raspberrypi-zero2w".to_string(),
                ),
            ],
        );
        assert_eq!(base["network"]["allow_insecure_tls"].as_bool(), Some(true));
        assert_eq!(base["chunk"]["target_ms"].as_integer(), Some(30000));
        assert_eq!(
            base["device"]["platform"].as_str(),
            Some("raspberrypi-zero2w")
        );
    }

    #[test]
    fn a_bare_nrd_prefix_with_nothing_after_it_is_ignored() {
        let mut base = toml::Value::Table(toml::map::Map::new());
        apply_env_overrides(&mut base, vec![("NRD_".to_string(), "x".to_string())]);
        assert!(base.as_table().unwrap().is_empty());
    }
}
