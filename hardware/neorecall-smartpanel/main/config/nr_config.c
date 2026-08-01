// SPDX-License-Identifier: MIT
#include "nr_config.h"

#include <string.h>
#include <stdlib.h>
#include <time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "esp_log.h"

#include "util/nr_util.h"

static const char *TAG = "nr_cfg";
static const char *NS = "neorecall";

static nr_config_t s_cfg;
static SemaphoreHandle_t s_lock;

// ---- NVS helpers -----------------------------------------------------------

static void load_str(nvs_handle_t h, const char *key, char *dst, size_t cap, const char *dflt)
{
    size_t len = cap;
    if (nvs_get_str(h, key, dst, &len) != ESP_OK) {
        nr_strlcpy(dst, dflt ? dflt : "", cap);
    }
}

static uint32_t load_u32(nvs_handle_t h, const char *key, uint32_t dflt)
{
    uint32_t v = dflt;
    nvs_get_u32(h, key, &v);
    return v;
}

static uint8_t load_u8(nvs_handle_t h, const char *key, uint8_t dflt)
{
    uint8_t v = dflt;
    nvs_get_u8(h, key, &v);
    return v;
}

static double load_dbl(nvs_handle_t h, const char *key, double dflt)
{
    // NVS has no double type; store the raw bytes as a blob.
    double v = dflt;
    size_t len = sizeof(v);
    nvs_get_blob(h, key, &v, &len);
    return v;
}

// ---- Defaults --------------------------------------------------------------

static void apply_defaults(nr_config_t *c)
{
    memset(c, 0, sizeof(*c));
    c->provisioned = false;
    c->tls_insecure = false;
    nr_strlcpy(c->device_name, "NeoRecall Panel", sizeof(c->device_name));
    c->location_auto = true;
    c->latitude = 0.0;
    c->longitude = 0.0;
    nr_strlcpy(c->tz_name, "UTC", sizeof(c->tz_name));
    nr_strlcpy(c->tz_posix, "UTC0", sizeof(c->tz_posix));
    c->clock_24h = true;
    c->units_metric = true;
    c->brightness_day = 90;
    c->brightness_night = 12;
    c->night_enabled = false;
    c->night_mode = NR_NIGHT_DIM;
    c->night_start_min = 23 * 60;   // 23:00
    c->night_end_min = 7 * 60;      // 07:00
    c->wake_seconds = 8;
    c->recording_enabled = true;    // 24/7 by default
    c->ota_enabled = true;
    c->ota_url[0] = '\0';
    c->chunk_target_ms = 30000;
    c->chunk_overlap_ms = 2000;
    c->chunk_min_ms = 15000;
    c->chunk_max_ms = 120000;
    c->max_upload_bytes = 32u * 1024u * 1024u;
}

// ---- Load ------------------------------------------------------------------

esp_err_t nr_config_init(void)
{
    if (!s_lock) s_lock = xSemaphoreCreateMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;

    apply_defaults(&s_cfg);

    nvs_handle_t h;
    esp_err_t err = nvs_open(NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        return err;
    }

    s_cfg.provisioned = load_u8(h, "provisioned", 0);
    load_str(h, "wifi_ssid", s_cfg.wifi_ssid, sizeof(s_cfg.wifi_ssid), "");
    load_str(h, "wifi_pass", s_cfg.wifi_pass, sizeof(s_cfg.wifi_pass), "");
    load_str(h, "backend_url", s_cfg.backend_url, sizeof(s_cfg.backend_url), "");
    load_str(h, "api_key", s_cfg.api_key, sizeof(s_cfg.api_key), "");
    load_str(h, "auth_user", s_cfg.auth_user, sizeof(s_cfg.auth_user), "");
    load_str(h, "auth_pass", s_cfg.auth_pass, sizeof(s_cfg.auth_pass), "");
    s_cfg.tls_insecure = load_u8(h, "tls_insecure", 0);
    load_str(h, "device_id", s_cfg.device_id, sizeof(s_cfg.device_id), "");
    load_str(h, "dev_client", s_cfg.device_client_uuid, sizeof(s_cfg.device_client_uuid), "");
    load_str(h, "device_name", s_cfg.device_name, sizeof(s_cfg.device_name), s_cfg.device_name);

    s_cfg.location_auto = load_u8(h, "loc_auto", 1);
    s_cfg.latitude = load_dbl(h, "lat", 0.0);
    s_cfg.longitude = load_dbl(h, "lon", 0.0);
    load_str(h, "city", s_cfg.city, sizeof(s_cfg.city), "");
    load_str(h, "tz_name", s_cfg.tz_name, sizeof(s_cfg.tz_name), s_cfg.tz_name);
    load_str(h, "tz_posix", s_cfg.tz_posix, sizeof(s_cfg.tz_posix), s_cfg.tz_posix);
    s_cfg.clock_24h = load_u8(h, "clock24", 1);
    s_cfg.units_metric = load_u8(h, "metric", 1);

    s_cfg.brightness_day = load_u8(h, "bri_day", s_cfg.brightness_day);
    s_cfg.brightness_night = load_u8(h, "bri_night", s_cfg.brightness_night);
    s_cfg.night_enabled = load_u8(h, "night_en", 0);
    s_cfg.night_mode = (nr_night_mode_t) load_u8(h, "night_mode", NR_NIGHT_DIM);
    s_cfg.night_start_min = (uint16_t) load_u32(h, "night_start", s_cfg.night_start_min);
    s_cfg.night_end_min = (uint16_t) load_u32(h, "night_end", s_cfg.night_end_min);
    s_cfg.wake_seconds = (uint16_t) load_u32(h, "wake_secs", s_cfg.wake_seconds);

    s_cfg.recording_enabled = load_u8(h, "rec_en", 1);
    s_cfg.ota_enabled = load_u8(h, "ota_en", 1);
    load_str(h, "ota_url", s_cfg.ota_url, sizeof(s_cfg.ota_url), "");

    s_cfg.chunk_target_ms = load_u32(h, "chunk_tgt", s_cfg.chunk_target_ms);
    s_cfg.chunk_overlap_ms = load_u32(h, "chunk_ovl", s_cfg.chunk_overlap_ms);
    s_cfg.chunk_min_ms = load_u32(h, "chunk_min", s_cfg.chunk_min_ms);
    s_cfg.chunk_max_ms = load_u32(h, "chunk_max", s_cfg.chunk_max_ms);
    s_cfg.max_upload_bytes = load_u32(h, "max_upload", s_cfg.max_upload_bytes);

    // Generate stable identities the first time we ever boot.
    bool dirty = false;
    if (strlen(s_cfg.device_id) != NR_UUID_LEN - 1) {
        nr_uuid_v4(s_cfg.device_id);
        nvs_set_str(h, "device_id", s_cfg.device_id);
        dirty = true;
    }
    if (strlen(s_cfg.device_client_uuid) != NR_UUID_LEN - 1) {
        nr_uuid_v4(s_cfg.device_client_uuid);
        nvs_set_str(h, "dev_client", s_cfg.device_client_uuid);
        dirty = true;
    }
    if (dirty) nvs_commit(h);
    nvs_close(h);

    ESP_LOGI(TAG, "config loaded (provisioned=%d, device_id=%.8s..., city=%s)",
             s_cfg.provisioned, s_cfg.device_id, s_cfg.city);
    return ESP_OK;
}

// ---- Accessors -------------------------------------------------------------

void nr_config_get(nr_config_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_cfg;
    xSemaphoreGive(s_lock);
}

bool nr_config_is_provisioned(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool has_auth = s_cfg.api_key[0] || (s_cfg.auth_user[0] && s_cfg.auth_pass[0]);
    bool ok = s_cfg.provisioned && s_cfg.wifi_ssid[0] && s_cfg.backend_url[0] && has_auth;
    xSemaphoreGive(s_lock);
    return ok;
}

esp_err_t nr_config_set_device_id(const char *device_id)
{
    if (!device_id || strlen(device_id) != NR_UUID_LEN - 1) return ESP_ERR_INVALID_ARG;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (strcmp(s_cfg.device_id, device_id) == 0) { xSemaphoreGive(s_lock); return ESP_OK; }
    nr_strlcpy(s_cfg.device_id, device_id, sizeof(s_cfg.device_id));
    nvs_handle_t h;
    esp_err_t err = nvs_open(NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        nvs_set_str(h, "device_id", s_cfg.device_id);
        err = nvs_commit(h);
        nvs_close(h);
    }
    xSemaphoreGive(s_lock);
    ESP_LOGI(TAG, "device_id reconciled to %.8s…", device_id);
    return err;
}

void nr_config_apply_timezone(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    char tz[NR_CFG_TZPOSIX_MAX];
    nr_strlcpy(tz, s_cfg.tz_posix[0] ? s_cfg.tz_posix : "UTC0", sizeof(tz));
    xSemaphoreGive(s_lock);
    setenv("TZ", tz, 1);
    tzset();
}

// ---- Persistence -----------------------------------------------------------

static esp_err_t persist_all_locked(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    nvs_set_u8(h, "provisioned", s_cfg.provisioned);
    nvs_set_str(h, "wifi_ssid", s_cfg.wifi_ssid);
    nvs_set_str(h, "wifi_pass", s_cfg.wifi_pass);
    nvs_set_str(h, "backend_url", s_cfg.backend_url);
    nvs_set_str(h, "api_key", s_cfg.api_key);
    nvs_set_str(h, "auth_user", s_cfg.auth_user);
    nvs_set_str(h, "auth_pass", s_cfg.auth_pass);
    nvs_set_u8(h, "tls_insecure", s_cfg.tls_insecure);
    nvs_set_str(h, "device_id", s_cfg.device_id);
    nvs_set_str(h, "dev_client", s_cfg.device_client_uuid);
    nvs_set_str(h, "device_name", s_cfg.device_name);

    nvs_set_u8(h, "loc_auto", s_cfg.location_auto);
    nvs_set_blob(h, "lat", &s_cfg.latitude, sizeof(s_cfg.latitude));
    nvs_set_blob(h, "lon", &s_cfg.longitude, sizeof(s_cfg.longitude));
    nvs_set_str(h, "city", s_cfg.city);
    nvs_set_str(h, "tz_name", s_cfg.tz_name);
    nvs_set_str(h, "tz_posix", s_cfg.tz_posix);
    nvs_set_u8(h, "clock24", s_cfg.clock_24h);
    nvs_set_u8(h, "metric", s_cfg.units_metric);

    nvs_set_u8(h, "bri_day", s_cfg.brightness_day);
    nvs_set_u8(h, "bri_night", s_cfg.brightness_night);
    nvs_set_u8(h, "night_en", s_cfg.night_enabled);
    nvs_set_u8(h, "night_mode", s_cfg.night_mode);
    nvs_set_u32(h, "night_start", s_cfg.night_start_min);
    nvs_set_u32(h, "night_end", s_cfg.night_end_min);
    nvs_set_u32(h, "wake_secs", s_cfg.wake_seconds);

    nvs_set_u8(h, "rec_en", s_cfg.recording_enabled);
    nvs_set_u8(h, "ota_en", s_cfg.ota_enabled);
    nvs_set_str(h, "ota_url", s_cfg.ota_url);

    nvs_set_u32(h, "chunk_tgt", s_cfg.chunk_target_ms);
    nvs_set_u32(h, "chunk_ovl", s_cfg.chunk_overlap_ms);
    nvs_set_u32(h, "chunk_min", s_cfg.chunk_min_ms);
    nvs_set_u32(h, "chunk_max", s_cfg.chunk_max_ms);
    nvs_set_u32(h, "max_upload", s_cfg.max_upload_bytes);

    err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static void emit_changed(void)
{
    esp_event_post(NR_EVENT, NR_EVT_CONFIG_CHANGED, NULL, 0, portMAX_DELAY);
}

static void sanitize(nr_config_t *c)
{
    // URL must have no trailing slash; the client always prefixes /api/v1/...
    size_t n = strlen(c->backend_url);
    while (n > 0 && c->backend_url[n - 1] == '/') c->backend_url[--n] = '\0';

    c->brightness_day = nr_clampi(c->brightness_day, 3, 100);
    c->brightness_night = nr_clampi(c->brightness_night, 0, 100);
    if (c->night_start_min > 1439) c->night_start_min = 1439;
    if (c->night_end_min > 1439) c->night_end_min = 1439;
    if (c->wake_seconds < 2) c->wake_seconds = 2;
    if (c->wake_seconds > 120) c->wake_seconds = 120;

    // Never trust an incoming struct to clear our stable identity.
    if (strlen(c->device_id) != NR_UUID_LEN - 1) nr_uuid_v4(c->device_id);
    if (strlen(c->device_client_uuid) != NR_UUID_LEN - 1) nr_uuid_v4(c->device_client_uuid);

    if (c->chunk_target_ms < 1000) c->chunk_target_ms = 30000;
    if (c->chunk_overlap_ms >= c->chunk_target_ms) c->chunk_overlap_ms = c->chunk_target_ms / 4;
    if (c->tz_posix[0] == '\0') nr_strlcpy(c->tz_posix, "UTC0", sizeof(c->tz_posix));
    if (c->tz_name[0] == '\0') nr_strlcpy(c->tz_name, "UTC", sizeof(c->tz_name));
}

esp_err_t nr_config_set(const nr_config_t *in)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    nr_config_t next = *in;
    // Preserve identity fields the caller may not have populated.
    if (strlen(next.device_id) != NR_UUID_LEN - 1)
        nr_strlcpy(next.device_id, s_cfg.device_id, sizeof(next.device_id));
    if (strlen(next.device_client_uuid) != NR_UUID_LEN - 1)
        nr_strlcpy(next.device_client_uuid, s_cfg.device_client_uuid, sizeof(next.device_client_uuid));
    sanitize(&next);
    s_cfg = next;
    esp_err_t err = persist_all_locked();
    xSemaphoreGive(s_lock);
    nr_config_apply_timezone();
    emit_changed();
    return err;
}

esp_err_t nr_config_set_recording_enabled(bool enabled)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_cfg.recording_enabled = enabled;
    nvs_handle_t h;
    esp_err_t err = nvs_open(NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        nvs_set_u8(h, "rec_en", enabled);
        err = nvs_commit(h);
        nvs_close(h);
    }
    xSemaphoreGive(s_lock);
    emit_changed();
    return err;
}

esp_err_t nr_config_set_location(double lat, double lon, const char *city,
                                 const char *tz_name, const char *tz_posix)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_cfg.latitude = lat;
    s_cfg.longitude = lon;
    if (city) nr_strlcpy(s_cfg.city, city, sizeof(s_cfg.city));
    if (tz_name && tz_name[0]) nr_strlcpy(s_cfg.tz_name, tz_name, sizeof(s_cfg.tz_name));
    if (tz_posix && tz_posix[0]) nr_strlcpy(s_cfg.tz_posix, tz_posix, sizeof(s_cfg.tz_posix));
    esp_err_t err = persist_all_locked();
    xSemaphoreGive(s_lock);
    nr_config_apply_timezone();
    emit_changed();
    return err;
}

esp_err_t nr_config_set_server_limits(uint32_t target_ms, uint32_t overlap_ms,
                                      uint32_t min_ms, uint32_t max_ms,
                                      uint32_t max_upload_bytes)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (target_ms) s_cfg.chunk_target_ms = target_ms;
    if (overlap_ms || overlap_ms == 0) s_cfg.chunk_overlap_ms = overlap_ms;
    if (min_ms) s_cfg.chunk_min_ms = min_ms;
    if (max_ms) s_cfg.chunk_max_ms = max_ms;
    if (max_upload_bytes) s_cfg.max_upload_bytes = max_upload_bytes;
    if (s_cfg.chunk_overlap_ms >= s_cfg.chunk_target_ms)
        s_cfg.chunk_overlap_ms = s_cfg.chunk_target_ms / 4;
    esp_err_t err = persist_all_locked();
    xSemaphoreGive(s_lock);
    return err;
}
