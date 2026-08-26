use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Uac2Params {
    /// Capture channel mask the host will see (2 = stereo).
    pub c_chmask: u8,
    pub c_srate: u32,
    /// Sample size in bytes (2 = S16LE).
    pub c_ssize: u8,
    /// Playback channel mask exposed to the host. Must stay 0: Desk is
    /// output-only and must never present a USB microphone.
    pub p_chmask: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsbGadgetProfile {
    pub name: String,
    pub id_vendor: u16,
    pub id_product: u16,
    pub bcd_device: u16,
    pub manufacturer: String,
    pub product: String,
    /// How the device serial number is derived; "cpuserial" reads
    /// `/proc/cpuinfo`'s Serial field. Kept as data so a profile can name a
    /// different source without a code change.
    pub serial_source: String,
    pub uac2: Uac2Params,
    /// Declared bus power draw in the gadget descriptor (mA). Must be honest
    /// about single-cable power reality — see Risk R4.
    pub max_power_ma: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Wm8960Profile {
    pub card_alias: String,
    pub playback_volume_control: String,
    pub capture_volume_control: String,
    pub max_playback_percent: u8,
    pub startup_playback_percent: u8,
    /// ALSA mixer controls toggled to mute the amplifier immediately on an
    /// undervoltage/throttle event.
    pub amp_mute_controls: Vec<String>,
    /// The WM8960 HAT's GPIO17 button is unused: GPIO17 is reserved for the
    /// ELEGOO display's touch interrupt.
    pub button_gpio_disabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DisplayProfile {
    pub drm_card: String,
    pub width: u32,
    pub height: u32,
    pub rotation: u16,
    pub touch_device_hint: String,
    pub touch_irq_gpio: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareProfile {
    pub usb_gadget: UsbGadgetProfile,
    pub wm8960: Wm8960Profile,
    pub display: DisplayProfile,
}
