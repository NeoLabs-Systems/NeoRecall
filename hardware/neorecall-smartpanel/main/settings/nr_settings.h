// SPDX-License-Identifier: MIT
// Declarative settings schema — the single source of truth for every
// configurable field. Both the on-device LVGL settings screen and the Wi-Fi
// captive portal are generated from this list and read/write the same
// nr_config_t, so the two can never drift apart (no duplicated field lists).
#pragma once

#include "nr_common.h"
#include "config/nr_config.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    NRS_SECTION,     // group header, no value
    NRS_TEXT,        // free string
    NRS_PASSWORD,    // string; empty input keeps the stored value
    NRS_URL,         // string (rendered as a URL field on the web)
    NRS_SSID,        // string; the device offers a Wi-Fi scan for it
    NRS_BOOL,        // bool member -> switch / checkbox
    NRS_BOOL_INV,    // bool member shown inverted (e.g. "Fahrenheit" = !metric)
    NRS_PCT,         // uint8 0..100 -> slider / range
    NRS_TIME,        // uint16 minutes-of-day -> HH:MM
    NRS_NIGHTMODE,   // nr_night_mode_t as a bool ("ganz aus" = OFF)
} nrs_type_t;

typedef struct {
    const char *id;      // stable id (web form field name)
    const char *label;   // German label / section title
    const char *hint;    // optional help text / placeholder
    nrs_type_t type;
    uint16_t offset;     // offsetof(nr_config_t, member)
    uint16_t size;       // sizeof member (for strings)
    uint8_t min, max;    // for NRS_PCT
} nrs_field_t;

extern const nrs_field_t NR_SETTINGS[];
extern const int NR_SETTINGS_COUNT;

// Render a field's current value into `out` as a string (for HTML value +
// LVGL widget initialisation).
void nrs_get(const nr_config_t *c, const nrs_field_t *f, char *out, size_t n);

// Apply a string value (from a web form or a widget read-back) into config.
void nrs_set(nr_config_t *c, const nrs_field_t *f, const char *val);

#ifdef __cplusplus
}
#endif
