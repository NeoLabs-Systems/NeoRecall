// SPDX-License-Identifier: MIT
// Keyless weather via Open-Meteo. One HTTPS call yields the current conditions,
// today's high/low, and the local UTC offset — all rendered on the dashboard.
// Runs entirely on-device; the backend is never involved (per the goal).
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    NR_WX_CLEAR = 0, NR_WX_CLOUDY, NR_WX_RAIN, NR_WX_SNOW, NR_WX_THUNDER, NR_WX_FOG,
} nr_wx_cat_t;

typedef struct {
    bool valid;
    int64_t fetched_epoch_ms;
    float temp;                // current temperature, in the configured unit
    float apparent;
    int humidity;              // %
    int weather_code;          // WMO
    bool is_day;
    float wind;                // in the configured unit
    float today_min, today_max;
    nr_wx_cat_t category;
    char desc[40];             // short German description
    char units_temp[4];        // "°C" / "°F"
    int utc_offset_seconds;
    char tz_abbr[8];
} nr_weather_t;

esp_err_t nr_weather_init(void);
void nr_weather_get(nr_weather_t *out);
void nr_weather_refresh_now(void);   // e.g. after the location changes

// Map a WMO code to a category + short German description.
nr_wx_cat_t nr_weather_map(int code, char *desc, size_t desc_len);

#ifdef __cplusplus
}
#endif
