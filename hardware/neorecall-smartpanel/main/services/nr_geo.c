// SPDX-License-Identifier: MIT
#include "nr_geo.h"

#include <string.h>
#include <stdio.h>

#include "esp_log.h"
#include "cJSON.h"

#include "net/nr_http.h"
#include "config/nr_config.h"
#include "util/nr_util.h"

static const char *TAG = "nr_geo";

// Common IANA -> POSIX TZ strings with full DST rules (from research). Covers
// the large majority of users; unknown zones fall back to a fixed offset.
static const struct { const char *iana; const char *posix; } TZ_TABLE[] = {
    { "UTC", "UTC0" },
    { "Europe/Berlin", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Paris", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Madrid", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Rome", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Amsterdam", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Vienna", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Zurich", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/London", "GMT0BST,M3.5.0/1,M10.5.0" },
    { "Europe/Lisbon", "WET0WEST,M3.5.0/1,M10.5.0" },
    { "Europe/Athens", "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    { "Europe/Helsinki", "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    { "Europe/Warsaw", "CET-1CEST,M3.5.0,M10.5.0/3" },
    { "Europe/Moscow", "MSK-3" },
    { "America/New_York", "EST5EDT,M3.2.0,M11.1.0" },
    { "America/Chicago", "CST6CDT,M3.2.0,M11.1.0" },
    { "America/Denver", "MST7MDT,M3.2.0,M11.1.0" },
    { "America/Los_Angeles", "PST8PDT,M3.2.0,M11.1.0" },
    { "America/Phoenix", "MST7" },
    { "America/Sao_Paulo", "<-03>3" },
    { "America/Toronto", "EST5EDT,M3.2.0,M11.1.0" },
    { "Asia/Kolkata", "IST-5:30" },
    { "Asia/Shanghai", "CST-8" },
    { "Asia/Tokyo", "JST-9" },
    { "Asia/Singapore", "<+08>-8" },
    { "Asia/Dubai", "<+04>-4" },
    { "Australia/Sydney", "AEST-10AEDT,M10.1.0,M4.1.0/3" },
    { "Pacific/Auckland", "NZST-12NZDT,M9.5.0,M4.1.0/3" },
};

void nr_geo_posix_tz(const char *iana, int offset_seconds, char *out, size_t out_len)
{
    if (iana && iana[0]) {
        for (size_t i = 0; i < sizeof(TZ_TABLE) / sizeof(TZ_TABLE[0]); i++) {
            if (strcmp(iana, TZ_TABLE[i].iana) == 0) { nr_strlcpy(out, TZ_TABLE[i].posix, out_len); return; }
        }
    }
    // Fixed-offset fallback (no DST). POSIX offset sign is inverted from UTC.
    int total_min = -offset_seconds / 60;
    int hh = total_min / 60;
    int mm = total_min % 60; if (mm < 0) mm = -mm;
    int disp = offset_seconds / 3600;
    if (mm) snprintf(out, out_len, "<%+03d>%d:%02d", disp, hh < 0 ? -hh : hh, mm);
    else    snprintf(out, out_len, "<%+03d>%d", disp, hh);
}

esp_err_t nr_geo_autolocate(void)
{
    nr_http_result_t res;
    if (nr_http_get("https://ipwho.is/", false, 12000, &res) != ESP_OK || res.status != 200 || !res.body) {
        nr_http_result_free(&res);
        ESP_LOGW(TAG, "IP geolocation request failed");
        return ESP_FAIL;
    }
    cJSON *j = cJSON_Parse(res.body);
    nr_http_result_free(&res);
    if (!j) return ESP_FAIL;

    esp_err_t err = ESP_FAIL;
    cJSON *ok = cJSON_GetObjectItem(j, "success");
    cJSON *lat = cJSON_GetObjectItem(j, "latitude");
    cJSON *lon = cJSON_GetObjectItem(j, "longitude");
    if ((!ok || cJSON_IsTrue(ok)) && cJSON_IsNumber(lat) && cJSON_IsNumber(lon)) {
        const char *city = "";
        cJSON *c = cJSON_GetObjectItem(j, "city");
        if (cJSON_IsString(c)) city = c->valuestring;
        const char *iana = "";
        int offset = 0;
        cJSON *tz = cJSON_GetObjectItem(j, "timezone");
        if (tz) {
            cJSON *id = cJSON_GetObjectItem(tz, "id");
            if (cJSON_IsString(id)) iana = id->valuestring;
            cJSON *off = cJSON_GetObjectItem(tz, "offset");
            if (cJSON_IsNumber(off)) offset = off->valueint;
        }
        char posix[64];
        nr_geo_posix_tz(iana, offset, posix, sizeof(posix));
        nr_config_set_location(lat->valuedouble, lon->valuedouble, city, iana, posix);
        ESP_LOGI(TAG, "located: %s (%.3f,%.3f) %s", city, lat->valuedouble, lon->valuedouble, iana);
        err = ESP_OK;
    }
    cJSON_Delete(j);
    return err;
}

esp_err_t nr_geo_from_city(const char *city)
{
    if (!city || !city[0]) return ESP_ERR_INVALID_ARG;
    char url[256];
    // Minimal URL-encoding: spaces -> %20 (city names rarely need more).
    char enc[128]; size_t o = 0;
    for (const char *p = city; *p && o + 3 < sizeof(enc); p++) {
        if (*p == ' ') { enc[o++] = '%'; enc[o++] = '2'; enc[o++] = '0'; }
        else enc[o++] = *p;
    }
    enc[o] = '\0';
    snprintf(url, sizeof(url), "https://geocoding-api.open-meteo.com/v1/search?name=%s&count=1&language=de&format=json", enc);

    nr_http_result_t res;
    if (nr_http_get(url, false, 12000, &res) != ESP_OK || res.status != 200 || !res.body) {
        nr_http_result_free(&res);
        return ESP_FAIL;
    }
    cJSON *j = cJSON_Parse(res.body);
    nr_http_result_free(&res);
    if (!j) return ESP_FAIL;

    esp_err_t err = ESP_FAIL;
    cJSON *results = cJSON_GetObjectItem(j, "results");
    cJSON *first = results ? cJSON_GetArrayItem(results, 0) : NULL;
    if (first) {
        cJSON *lat = cJSON_GetObjectItem(first, "latitude");
        cJSON *lon = cJSON_GetObjectItem(first, "longitude");
        cJSON *name = cJSON_GetObjectItem(first, "name");
        cJSON *tz = cJSON_GetObjectItem(first, "timezone");
        if (cJSON_IsNumber(lat) && cJSON_IsNumber(lon)) {
            const char *iana = cJSON_IsString(tz) ? tz->valuestring : "";
            char posix[64];
            nr_geo_posix_tz(iana, 0, posix, sizeof(posix));
            nr_config_set_location(lat->valuedouble, lon->valuedouble,
                                   cJSON_IsString(name) ? name->valuestring : city, iana, posix);
            err = ESP_OK;
        }
    }
    cJSON_Delete(j);
    return err;
}
