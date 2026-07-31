// SPDX-License-Identifier: MIT
#include "nr_time.h"

#include <string.h>
#include <sys/time.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_netif_sntp.h"
#include "esp_sntp.h"

#include "config/nr_config.h"

static const char *TAG = "nr_time";
static volatile bool s_valid;

static void on_sync(struct timeval *tv)
{
    (void) tv;
    if (!s_valid) {
        s_valid = true;
        ESP_LOGI(TAG, "wall clock acquired via SNTP");
    }
    esp_event_post(NR_EVENT, NR_EVT_TIME_SYNCED, NULL, 0, 0);
}

esp_err_t nr_time_init(void)
{
    nr_config_apply_timezone();

    // Two servers for resilience; smooth sync would delay first fix, so the
    // default (immediate step) is used to get a usable clock fast at boot.
    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG_MULTIPLE(
        2, ESP_SNTP_SERVER_LIST("pool.ntp.org", "time.cloudflare.com"));
    cfg.sync_cb = on_sync;
    cfg.start = true;
    cfg.server_from_dhcp = true;              // honour a router-advertised NTP server
    cfg.renew_servers_after_new_IP = true;

    esp_err_t err = esp_netif_sntp_init(&cfg);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "sntp init failed: %s", esp_err_to_name(err));
        return err;
    }

    // If RTC survived a warm reboot the clock may already be valid.
    struct timeval now;
    gettimeofday(&now, NULL);
    if (now.tv_sec > 1735689600 /* 2025-01-01 */) s_valid = true;
    return ESP_OK;
}

bool nr_time_is_valid(void) { return s_valid; }

int64_t nr_time_monotonic_ms(void) { return esp_timer_get_time() / 1000; }

int64_t nr_time_epoch_ms(void)
{
    if (!s_valid) return 0;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t) tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void nr_time_iso_from_epoch_ms(int64_t epoch_ms, char out[NR_ISO8601_LEN])
{
    time_t secs = (time_t) (epoch_ms / 1000);
    int ms = (int) (epoch_ms % 1000);
    if (ms < 0) { ms += 1000; secs -= 1; }
    struct tm tm_utc;
    gmtime_r(&secs, &tm_utc);
    // "YYYY-MM-DDTHH:MM:SS.mmmZ"
    snprintf(out, NR_ISO8601_LEN, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
             tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
             tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec, ms);
}

void nr_time_now_iso(char out[NR_ISO8601_LEN])
{
    nr_time_iso_from_epoch_ms(nr_time_epoch_ms(), out);
}

bool nr_time_local(struct tm *out)
{
    if (!s_valid) return false;
    time_t secs = (time_t) (nr_time_epoch_ms() / 1000);
    localtime_r(&secs, out);
    return true;
}
