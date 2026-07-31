// SPDX-License-Identifier: MIT
// Persisted device configuration, backed by NVS.
//
// A single in-RAM snapshot is loaded at boot and mutated through setters that
// persist immediately, so a power loss never leaves a torn setting. All access
// is serialised by an internal mutex; callers copy the struct out with
// nr_config_get() and never hold a pointer into shared state.

#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NR_CFG_STR_MAX     128   // ssid, city, device name, tz strings
#define NR_CFG_URL_MAX     200   // backend base url
#define NR_CFG_SECRET_MAX  128   // wifi password, api key
#define NR_CFG_TZPOSIX_MAX 64

typedef enum {
    NR_NIGHT_DIM = 0,   // reduce backlight to brightness_night
    NR_NIGHT_OFF,       // backlight fully off; tap wakes for a few seconds
} nr_night_mode_t;

typedef struct {
    // --- Provisioning / identity -------------------------------------------
    bool provisioned;                 // initial setup completed
    char wifi_ssid[NR_CFG_STR_MAX];
    char wifi_pass[NR_CFG_SECRET_MAX];
    char backend_url[NR_CFG_URL_MAX]; // e.g. https://recall.example.com  (no trailing slash)
    char api_key[NR_CFG_SECRET_MAX];  // nrk_...  (ingest:write scope)
    bool tls_insecure;                // skip cert verification (self-hosted/local only)
    char device_id[NR_UUID_LEN];      // stable NeoRecall device UUID
    char device_client_uuid[NR_UUID_LEN];
    char device_name[NR_CFG_STR_MAX]; // shown in the NeoRecall device list

    // --- Location / time ----------------------------------------------------
    bool  location_auto;              // auto-detect via IP on first boot
    double latitude;
    double longitude;
    char  city[NR_CFG_STR_MAX];
    char  tz_name[NR_CFG_STR_MAX];        // IANA, e.g. "Europe/Berlin"
    char  tz_posix[NR_CFG_TZPOSIX_MAX];   // POSIX TZ for DST-correct localtime
    bool  clock_24h;
    bool  units_metric;               // °C + km/h vs °F + mph

    // --- Display / night schedule ------------------------------------------
    uint8_t brightness_day;           // 0..100
    uint8_t brightness_night;         // 0..100 (used when night mode == DIM)
    bool    night_enabled;
    nr_night_mode_t night_mode;
    uint16_t night_start_min;         // minutes since local midnight
    uint16_t night_end_min;
    uint16_t wake_seconds;            // tap-to-wake duration during night-off

    // --- Recording ----------------------------------------------------------
    bool recording_enabled;           // false => user paused (persists across reboot)

    // --- Cached server limits (from GET /api/v1/meta) -----------------------
    uint32_t chunk_target_ms;         // default 30000
    uint32_t chunk_overlap_ms;        // default 2000
    uint32_t chunk_min_ms;            // default 15000
    uint32_t chunk_max_ms;            // default 120000
    uint32_t max_upload_bytes;        // default 32 MiB
} nr_config_t;

// Load the snapshot from NVS, applying defaults for missing keys and generating
// stable device UUIDs on first boot. Must be called once, early, after nvs init.
esp_err_t nr_config_init(void);

// Copy the current snapshot out. Thread-safe.
void nr_config_get(nr_config_t *out);

// Whole-struct replace (used by the settings UI "save"): validates, persists
// every field, and emits NR_EVT_CONFIG_CHANGED. Fields that must stay stable
// (device UUIDs) are preserved even if the incoming struct zeroed them.
esp_err_t nr_config_set(const nr_config_t *in);

// Targeted setters for hot paths that should not rewrite everything.
esp_err_t nr_config_set_recording_enabled(bool enabled);
esp_err_t nr_config_set_location(double lat, double lon, const char *city,
                                 const char *tz_name, const char *tz_posix);
esp_err_t nr_config_set_server_limits(uint32_t target_ms, uint32_t overlap_ms,
                                      uint32_t min_ms, uint32_t max_ms,
                                      uint32_t max_upload_bytes);

// True when Wi-Fi credentials and a backend URL + API key are all present.
bool nr_config_is_provisioned(void);

// Apply the configured POSIX TZ to the C runtime (setenv TZ + tzset).
void nr_config_apply_timezone(void);

#ifdef __cplusplus
}
#endif
