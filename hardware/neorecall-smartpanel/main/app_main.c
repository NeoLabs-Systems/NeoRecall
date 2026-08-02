// SPDX-License-Identifier: MIT
// NeoRecall Smart Panel — application entry point.
//
// Boot order is chosen so capture can begin as early as possible and the UI
// appears quickly, while nothing that depends on another subsystem starts
// before it. Every long-running activity is its own supervised task; app_main
// returns once they are launched.
#include "nr_common.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "esp_log.h"
#include "esp_littlefs.h"

#include "board/board_config.h"
#include "config/nr_config.h"
#include "util/nr_util.h"
#include "net/nr_time.h"
#include "net/nr_wifi.h"
#include "net/nr_ota.h"
#include "ingest/nr_spool.h"
#include "ingest/nr_ingest.h"
#include "ingest/nr_recorder.h"
#include "board/nr_board.h"
#include "services/nr_weather.h"
#include "ui/nr_ui.h"

static const char *TAG = "nr_app";

// Once the wall clock lands, sessions can be declared and their chunks flushed.
static void on_time_synced(void *a, esp_event_base_t b, int32_t id, void *d)
{
    (void) a; (void) b; (void) id; (void) d;
    nr_ingest_kick();
}

// Config or network changes should wake the upload pump immediately so a
// freshly provisioned panel starts draining instead of waiting the idle timer.
static void on_pump_wake(void *a, esp_event_base_t b, int32_t id, void *d)
{
    (void) a; (void) b; (void) id; (void) d;
    nr_ingest_kick();
}

static esp_err_t mount_spool(void)
{
    esp_vfs_littlefs_conf_t conf = {
        .base_path = BRD_SPOOL_MOUNT,
        .partition_label = BRD_SPOOL_LABEL,
        .format_if_mount_failed = true,
        .dont_mount = false,
    };
    esp_err_t err = esp_vfs_littlefs_register(&conf);
    if (err != ESP_OK) { ESP_LOGE(TAG, "LittleFS mount failed: %s", esp_err_to_name(err)); return err; }
    size_t total = 0, used = 0;
    esp_littlefs_info(BRD_SPOOL_LABEL, &total, &used);
    ESP_LOGI(TAG, "spool fs: %u KiB total, %u KiB used", (unsigned) (total / 1024), (unsigned) (used / 1024));
    return ESP_OK;
}

void app_main(void)
{
    ESP_LOGI(TAG, "NeoRecall Smart Panel %s starting", NR_FIRMWARE_VERSION);

    // --- Persistent state --------------------------------------------------
    esp_err_t nvs = nvs_flash_init();
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(nr_config_init());

    // --- Stream spool (PSRAM hold, brief LittleFS overflow only) -----------
    ESP_ERROR_CHECK(mount_spool());
    // Hold at most ~2 chunks in RAM (~2 MB) before spill; hard cap ~4 MB so a
    // stuck backend cannot accumulate minutes of audio on a board with no SD.
    // The pump abandons anything older than MAX_CHUNK_HOLD_MS regardless.
    ESP_ERROR_CHECK(nr_spool_init(BRD_SPOOL_MOUNT, 2000u * 1024u, 4ull * 1024 * 1024));

    // --- Display bring-up (so the UI can render) ---------------------------
    esp_err_t board = nr_board_init();
    if (board != ESP_OK)
        ESP_LOGE(TAG, "display bring-up failed (%s); running headless", esp_err_to_name(board));

    // --- Networking + clock (before the UI, so the first-boot setup screen's
    //     Wi-Fi scan works immediately) ------------------------------------
    ESP_ERROR_CHECK(nr_wifi_init());
    nr_time_init();
    esp_event_handler_instance_register(NR_EVENT, NR_EVT_TIME_SYNCED, on_time_synced, NULL, NULL);
    esp_event_handler_instance_register(NR_EVENT, NR_EVT_CONFIG_CHANGED, on_pump_wake, NULL, NULL);
    esp_event_handler_instance_register(NR_EVENT, NR_EVT_PORTAL_SAVED, on_pump_wake, NULL, NULL);
    esp_event_handler_instance_register(NR_EVENT, NR_EVT_WIFI_CHANGED, on_pump_wake, NULL, NULL);

    // --- UI: dashboard, or the on-device setup screen on first boot --------
    if (board == ESP_OK) nr_ui_init();

    // Everything is configured on the device's touchscreen. Connect if we
    // already have credentials; otherwise the setup screen is already open.
    nr_wifi_connect();

    // --- Keyless services + backend sync + capture -------------------------
    nr_weather_init();
    nr_ingest_init();
    nr_ota_init();               // confirms this image + polls for OTA updates

    // The recorder is the reason this device exists: start it last so every
    // dependency (spool, config, board mic/I2C) is ready, then never stop.
    esp_err_t rec = nr_recorder_init();
    if (rec != ESP_OK) ESP_LOGE(TAG, "recorder failed to start: %s", esp_err_to_name(rec));

    ESP_LOGI(TAG, "NeoRecall Smart Panel up (provisioned=%d)", nr_config_is_provisioned());
}
