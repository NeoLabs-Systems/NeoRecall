use serde::{Deserialize, Serialize};

/// What this release is validated against. `nrd-setup`'s preflight refuses to
/// start the gadget unit outside this range rather than let the app start
/// into a half-working audio graph (Risk R3: WM8960 driver breakage on
/// kernel bumps).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupportMatrix {
    pub kernel_min: String,
    pub kernel_max: String,
    pub os_ids: Vec<String>,
    pub os_versions: Vec<String>,
    pub required_modules: Vec<String>,
}
