// SPDX-License-Identifier: MIT
#include "nr_ota.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_app_desc.h"
#include "esp_ota_ops.h"
#include "esp_https_ota.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "cJSON.h"

#include "config/nr_config.h"
#include "net/nr_http.h"
#include "net/nr_wifi.h"
#include "util/nr_util.h"

static const char *TAG = "nr_ota";

// Fixed to the NeoRecall repo — not user-configurable. The build-firmware GitHub
// Action publishes this manifest on the rolling `firmware-latest` release.
#define NR_OTA_MANIFEST_URL \
    "https://github.com/NeoLabs-Systems/NeoRecall/releases/download/firmware-latest/manifest.json"

#define CHECK_INTERVAL_MS   (6 * 60 * 60 * 1000)   // every 6 hours
#define STARTUP_GRACE_MS    60000                  // confirm boot healthy after 60 s

static SemaphoreHandle_t s_wake;
static SemaphoreHandle_t s_lock;
static nr_ota_status_t s_status;

static void set_status(const char *msg)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    nr_strlcpy(s_status.status, msg ? msg : "", sizeof(s_status.status));
    xSemaphoreGive(s_lock);
}

void nr_ota_get_status(nr_ota_status_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_status;
    xSemaphoreGive(s_lock);
}

// Confirm the freshly-booted image so the bootloader stops holding a rollback.
static void confirm_boot_ok(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK)
            ESP_LOGI(TAG, "new firmware confirmed healthy");
    }
}

// esp_https_ota progress -> status.progress
static void run_update(const char *url)
{
    ESP_LOGI(TAG, "starting OTA from %s", url);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.updating = true; s_status.progress = 0;
    xSemaphoreGive(s_lock);
    set_status("Update wird geladen …");

    esp_http_client_config_t http_cfg = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .keep_alive_enable = true,
        .timeout_ms = 20000,
        .buffer_size = 4096,
        .buffer_size_tx = 2048,
    };
    esp_https_ota_config_t ota_cfg = { .http_config = &http_cfg };

    esp_https_ota_handle_t handle = NULL;
    esp_err_t err = esp_https_ota_begin(&ota_cfg, &handle);
    if (err != ESP_OK) { set_status("Update fehlgeschlagen (Verbindung)"); goto done; }

    int total = esp_https_ota_get_image_size(handle);
    while (1) {
        err = esp_https_ota_perform(handle);
        if (err != ESP_ERR_HTTPS_OTA_IN_PROGRESS) break;
        int read = esp_https_ota_get_image_len_read(handle);
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_status.progress = total > 0 ? (read * 100 / total) : 0;
        xSemaphoreGive(s_lock);
    }

    if (err == ESP_OK && esp_https_ota_is_complete_data_received(handle)) {
        err = esp_https_ota_finish(handle);
        if (err == ESP_OK) {
            set_status("Update installiert – Neustart …");
            ESP_LOGI(TAG, "OTA complete; rebooting");
            vTaskDelay(pdMS_TO_TICKS(1200));
            esp_restart();
        } else {
            set_status("Update-Image ungültig");
        }
    } else {
        esp_https_ota_abort(handle);
        set_status("Update fehlgeschlagen (Download)");
    }
done:
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.updating = false;
    xSemaphoreGive(s_lock);
}

static void check_once(void)
{
    nr_config_t c; nr_config_get(&c);
    if (!c.ota_enabled || !nr_net_is_online()) return;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.checking = true;
    xSemaphoreGive(s_lock);

    nr_http_result_t res;
    esp_err_t err = nr_http_get(NR_OTA_MANIFEST_URL, false, 15000, &res);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.checking = false;
    xSemaphoreGive(s_lock);

    if (err != ESP_OK || res.status != 200 || !res.body) {
        nr_http_result_free(&res);
        set_status("Update-Prüfung fehlgeschlagen");
        return;
    }
    cJSON *j = cJSON_Parse(res.body);
    nr_http_result_free(&res);
    if (!j) { set_status("Update-Manifest ungültig"); return; }

    const cJSON *ver = cJSON_GetObjectItem(j, "version");
    const cJSON *url = cJSON_GetObjectItem(j, "url");
    if (cJSON_IsString(ver) && cJSON_IsString(url)) {
        const char *running = esp_app_get_description()->version;
        xSemaphoreTake(s_lock, portMAX_DELAY);
        nr_strlcpy(s_status.latest_version, ver->valuestring, sizeof(s_status.latest_version));
        xSemaphoreGive(s_lock);
        if (strcmp(running, ver->valuestring) != 0) {
            ESP_LOGI(TAG, "update available: %s -> %s", running, ver->valuestring);
            char dl[NR_CFG_URL_MAX]; nr_strlcpy(dl, url->valuestring, sizeof(dl));
            cJSON_Delete(j);
            run_update(dl);
            return;
        }
        set_status("Firmware ist aktuell");
    }
    cJSON_Delete(j);
}

static void ota_task(void *arg)
{
    (void) arg;
    const esp_app_desc_t *app = esp_app_get_description();
    xSemaphoreTake(s_lock, portMAX_DELAY);
    nr_strlcpy(s_status.running_version, app->version, sizeof(s_status.running_version));
    xSemaphoreGive(s_lock);

    // Give the app time to prove itself, then confirm the image (rollback guard).
    xSemaphoreTake(s_wake, pdMS_TO_TICKS(STARTUP_GRACE_MS));
    confirm_boot_ok();

    for (;;) {
        check_once();
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(CHECK_INTERVAL_MS));
    }
}

void nr_ota_check_now(void) { if (s_wake) xSemaphoreGive(s_wake); }

esp_err_t nr_ota_init(void)
{
    s_wake = xSemaphoreCreateBinary();
    s_lock = xSemaphoreCreateMutex();
    if (!s_wake || !s_lock) return ESP_ERR_NO_MEM;
    nr_config_t c; nr_config_get(&c);
    s_status.enabled = c.ota_enabled;
    if (xTaskCreatePinnedToCore(ota_task, "nr_ota", 8192, NULL, 4, NULL, tskNO_AFFINITY) != pdPASS)
        return ESP_FAIL;
    return ESP_OK;
}
