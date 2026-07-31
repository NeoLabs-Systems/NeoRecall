// SPDX-License-Identifier: MIT
// Keyless location: auto-detect the panel's city/coordinates/timezone from its
// IP on first boot (ipwho.is), or resolve a city name the user typed in settings
// (Open-Meteo geocoding). Results are written straight into the config so the
// weather module and the clock pick them up. No API key, no backend involvement.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// One-shot IP geolocation. On success writes lat/lon/city/tz into config.
esp_err_t nr_geo_autolocate(void);

// Resolve a city name to coordinates + timezone and store it in config.
esp_err_t nr_geo_from_city(const char *city);

// Best-effort IANA -> POSIX TZ mapping (with DST rules for common zones).
// Falls back to a fixed-offset TZ built from offset_seconds when unknown.
void nr_geo_posix_tz(const char *iana, int offset_seconds, char *out, size_t out_len);

#ifdef __cplusplus
}
#endif
