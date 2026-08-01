// SPDX-License-Identifier: MIT
#include "nr_weather.h"

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "cJSON.h"

#include "net/nr_http.h"
#include "net/nr_wifi.h"
#include "config/nr_config.h"
#include "services/nr_geo.h"
#include "util/nr_util.h"

static const char *TAG = "nr_wx";
#define REFRESH_MS (10 * 60 * 1000)

static nr_weather_t s_wx;
static SemaphoreHandle_t s_lock;
static SemaphoreHandle_t s_wake;

nr_wx_cat_t nr_weather_map(int code, char *desc, size_t n)
{
    const char *d; nr_wx_cat_t cat;
    switch (code) {
        case 0:  d = "Klar"; cat = NR_WX_CLEAR; break;
        case 1:  d = "Überwiegend klar"; cat = NR_WX_CLEAR; break;
        case 2:  d = "Teils bewölkt"; cat = NR_WX_CLOUDY; break;
        case 3:  d = "Bedeckt"; cat = NR_WX_CLOUDY; break;
        case 45: d = "Nebel"; cat = NR_WX_FOG; break;
        case 48: d = "Reifnebel"; cat = NR_WX_FOG; break;
        case 51: d = "Leichter Niesel"; cat = NR_WX_RAIN; break;
        case 53: d = "Niesel"; cat = NR_WX_RAIN; break;
        case 55: d = "Dichter Niesel"; cat = NR_WX_RAIN; break;
        case 56: case 57: d = "Gefrierender Niesel"; cat = NR_WX_RAIN; break;
        case 61: d = "Leichter Regen"; cat = NR_WX_RAIN; break;
        case 63: d = "Regen"; cat = NR_WX_RAIN; break;
        case 65: d = "Starker Regen"; cat = NR_WX_RAIN; break;
        case 66: case 67: d = "Gefrierender Regen"; cat = NR_WX_RAIN; break;
        case 71: d = "Leichter Schnee"; cat = NR_WX_SNOW; break;
        case 73: d = "Schnee"; cat = NR_WX_SNOW; break;
        case 75: d = "Starker Schnee"; cat = NR_WX_SNOW; break;
        case 77: d = "Schneegriesel"; cat = NR_WX_SNOW; break;
        case 80: d = "Leichte Schauer"; cat = NR_WX_RAIN; break;
        case 81: d = "Schauer"; cat = NR_WX_RAIN; break;
        case 82: d = "Heftige Schauer"; cat = NR_WX_RAIN; break;
        case 85: d = "Schneeschauer"; cat = NR_WX_SNOW; break;
        case 86: d = "Starke Schneeschauer"; cat = NR_WX_SNOW; break;
        case 95: d = "Gewitter"; cat = NR_WX_THUNDER; break;
        case 96: d = "Gewitter, Hagel"; cat = NR_WX_THUNDER; break;
        case 99: d = "Schweres Gewitter"; cat = NR_WX_THUNDER; break;
        default: d = "Bewölkt"; cat = NR_WX_CLOUDY; break;
    }
    if (desc) nr_strlcpy(desc, d, n);
    return cat;
}

static bool fetch_once(void)
{
    nr_config_t c; nr_config_get(&c);
    if (c.latitude == 0.0 && c.longitude == 0.0) return false;

    char url[400];
    snprintf(url, sizeof(url),
        "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        "&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        "&timezone=auto&forecast_days=1&temperature_unit=%s&wind_speed_unit=%s",
        c.latitude, c.longitude,
        c.units_metric ? "celsius" : "fahrenheit",
        c.units_metric ? "kmh" : "mph");

    nr_http_result_t res;
    if (nr_http_get(url, false, 15000, &res) != ESP_OK || res.status != 200 || !res.body) {
        nr_http_result_free(&res);
        ESP_LOGW(TAG, "weather fetch failed (status=%d)", res.status);
        return false;
    }
    cJSON *j = cJSON_Parse(res.body);
    nr_http_result_free(&res);
    if (!j) return false;

    nr_weather_t w = {0};
    w.valid = true;
    nr_strlcpy(w.units_temp, c.units_metric ? "°C" : "°F", sizeof(w.units_temp));

    cJSON *cur = cJSON_GetObjectItem(j, "current");
    if (cur) {
        cJSON *v;
        v = cJSON_GetObjectItem(cur, "temperature_2m"); if (cJSON_IsNumber(v)) w.temp = v->valuedouble;
        v = cJSON_GetObjectItem(cur, "apparent_temperature"); if (cJSON_IsNumber(v)) w.apparent = v->valuedouble;
        v = cJSON_GetObjectItem(cur, "relative_humidity_2m"); if (cJSON_IsNumber(v)) w.humidity = v->valueint;
        v = cJSON_GetObjectItem(cur, "weather_code"); if (cJSON_IsNumber(v)) w.weather_code = v->valueint;
        v = cJSON_GetObjectItem(cur, "is_day"); if (cJSON_IsNumber(v)) w.is_day = v->valueint != 0;
        v = cJSON_GetObjectItem(cur, "wind_speed_10m"); if (cJSON_IsNumber(v)) w.wind = v->valuedouble;
    }
    cJSON *daily = cJSON_GetObjectItem(j, "daily");
    if (daily) {
        cJSON *mx = cJSON_GetObjectItem(daily, "temperature_2m_max");
        cJSON *mn = cJSON_GetObjectItem(daily, "temperature_2m_min");
        if (cJSON_IsArray(mx) && cJSON_GetArrayItem(mx, 0)) w.today_max = cJSON_GetArrayItem(mx, 0)->valuedouble;
        if (cJSON_IsArray(mn) && cJSON_GetArrayItem(mn, 0)) w.today_min = cJSON_GetArrayItem(mn, 0)->valuedouble;
    }
    cJSON *off = cJSON_GetObjectItem(j, "utc_offset_seconds");
    if (cJSON_IsNumber(off)) w.utc_offset_seconds = off->valueint;
    cJSON *abbr = cJSON_GetObjectItem(j, "timezone_abbreviation");
    if (cJSON_IsString(abbr)) nr_strlcpy(w.tz_abbr, abbr->valuestring, sizeof(w.tz_abbr));

    w.category = nr_weather_map(w.weather_code, w.desc, sizeof(w.desc));
    cJSON_Delete(j);

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_wx = w;
    xSemaphoreGive(s_lock);
    esp_event_post(NR_EVENT, NR_EVT_WEATHER_CHANGED, NULL, 0, 0);
    ESP_LOGI(TAG, "weather: %.1f%s %s (code %d)", w.temp, w.units_temp, w.desc, w.weather_code);
    return true;
}

static void weather_task(void *arg)
{
    (void) arg;
    bool located_this_boot = false;
    for (;;) {
        if (nr_net_is_online()) {
            nr_config_t c; nr_config_get(&c);
            if (c.location_auto && c.latitude == 0.0 && c.longitude == 0.0 && !located_this_boot) {
                if (nr_geo_autolocate() == ESP_OK) located_this_boot = true;
            }
            fetch_once();
        }
        // Sleep until the next refresh or an explicit wake (location changed).
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(REFRESH_MS));
    }
}

esp_err_t nr_weather_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    s_wake = xSemaphoreCreateBinary();
    if (!s_lock || !s_wake) return ESP_ERR_NO_MEM;
    // 8 KB: this task does TLS (ipwho.is geolocation + Open-Meteo) which needs
    // a generous stack; too small silently fails the handshake ("loading" forever).
    if (xTaskCreatePinnedToCore(weather_task, "nr_weather", 8192, NULL, 4, NULL, tskNO_AFFINITY) != pdPASS)
        return ESP_FAIL;
    return ESP_OK;
}

void nr_weather_get(nr_weather_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_wx;
    xSemaphoreGive(s_lock);
}

void nr_weather_refresh_now(void)
{
    if (s_wake) xSemaphoreGive(s_wake);
}
