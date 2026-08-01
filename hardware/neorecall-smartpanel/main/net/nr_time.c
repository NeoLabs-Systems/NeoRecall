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

    // One server keeps us within lwip's default CONFIG_LWIP_SNTP_MAX_SERVERS=1;
    // pool.ntp.org is itself a load-balanced pool. Immediate (step) sync gives a
    // usable clock fast at boot.
    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    cfg.sync_cb = on_sync;
    cfg.start = true;

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

// Days since 1970-01-01 for a proleptic-Gregorian date (m in 1..12). Avoids
// timegm(), which ESP's newlib does not declare, and the TZ side effects of
// mktime(). (Howard Hinnant's days_from_civil.)
static int64_t days_from_civil(int y, unsigned m, unsigned d)
{
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned) (y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int64_t) doe - 719468;
}

void nr_time_seed_from_http_date(const char *http_date)
{
    if (s_valid || !http_date) return;   // SNTP is authoritative; only seed once
    struct tm tm = {0};
    // RFC 1123, always English/GMT: "Wed, 01 Aug 2026 12:34:56 GMT"
    if (strptime(http_date, "%a, %d %b %Y %H:%M:%S", &tm) == NULL) return;
    time_t secs = (time_t) (days_from_civil(tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday) * 86400
                            + tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec);
    if (secs < 1735689600 /* 2025-01-01 */) return;
    struct timeval tv = { .tv_sec = secs, .tv_usec = 0 };
    settimeofday(&tv, NULL);
    s_valid = true;
    ESP_LOGI(TAG, "wall clock seeded from HTTP Date header");
    esp_event_post(NR_EVENT, NR_EVT_TIME_SYNCED, NULL, 0, 0);
}

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
