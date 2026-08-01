// SPDX-License-Identifier: MIT
#include "settings/nr_settings.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/nr_util.h"

#define OFF(m)  (uint16_t) offsetof(nr_config_t, m)
#define SZ(m)   (uint16_t) sizeof(((nr_config_t *) 0)->m)

// The whole configurable surface, in display order. Sections group the fields.
const nrs_field_t NR_SETTINGS[] = {
    { NULL, "WLAN", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "ssid", "Netzwerk", NULL, NRS_SSID, OFF(wifi_ssid), SZ(wifi_ssid), 0, 0 },
    { "wifipass", "WLAN-Passwort", "leer lassen = unverändert", NRS_PASSWORD, OFF(wifi_pass), SZ(wifi_pass), 0, 0 },

    { NULL, "BACKEND", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "url", "Backend-URL", "https://recall.example.com", NRS_URL, OFF(backend_url), SZ(backend_url), 0, 0 },
    { "apikey", "API-Key", "nrk_… (empfohlen, ingest:write)", NRS_PASSWORD, OFF(api_key), SZ(api_key), 0, 0 },
    { "user", "Benutzername", "oder Login statt API-Key", NRS_TEXT, OFF(auth_user), SZ(auth_user), 0, 0 },
    { "authpass", "Passwort", "leer lassen = unverändert", NRS_PASSWORD, OFF(auth_pass), SZ(auth_pass), 0, 0 },
    { "tls", "TLS-Zertifikat nicht prüfen", NULL, NRS_BOOL, OFF(tls_insecure), SZ(tls_insecure), 0, 0 },

    { NULL, "STANDORT", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "locauto", "Standort automatisch (per IP)", NULL, NRS_BOOL, OFF(location_auto), SZ(location_auto), 0, 0 },
    { "city", "Stadt", "z. B. Berlin", NRS_TEXT, OFF(city), SZ(city), 0, 0 },

    { NULL, "ANZEIGE", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "clock24", "24-Stunden-Uhr", NULL, NRS_BOOL, OFF(clock_24h), SZ(clock_24h), 0, 0 },
    { "fahrenheit", "Fahrenheit statt Celsius", NULL, NRS_BOOL_INV, OFF(units_metric), SZ(units_metric), 0, 0 },
    { "briday", "Helligkeit Tag", NULL, NRS_PCT, OFF(brightness_day), SZ(brightness_day), 5, 100 },
    { "brinight", "Helligkeit Nacht", NULL, NRS_PCT, OFF(brightness_night), SZ(brightness_night), 0, 100 },

    { NULL, "NACHTMODUS", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "nighton", "Nachtmodus aktiv", NULL, NRS_BOOL, OFF(night_enabled), SZ(night_enabled), 0, 0 },
    { "nightoff", "Display ganz aus (statt dimmen)", NULL, NRS_NIGHTMODE, OFF(night_mode), SZ(night_mode), 0, 0 },
    { "nstart", "Beginn", NULL, NRS_TIME, OFF(night_start_min), SZ(night_start_min), 0, 0 },
    { "nend", "Ende", NULL, NRS_TIME, OFF(night_end_min), SZ(night_end_min), 0, 0 },

    { NULL, "SOFTWARE-UPDATE (OTA)", NULL, NRS_SECTION, 0, 0, 0, 0 },
    { "ota", "Automatische Updates (aus dem NeoRecall-Repo)", NULL, NRS_BOOL, OFF(ota_enabled), SZ(ota_enabled), 0, 0 },
};
const int NR_SETTINGS_COUNT = (int) (sizeof(NR_SETTINGS) / sizeof(NR_SETTINGS[0]));

static bool truthy(const char *v) { return v && (v[0] == '1' || v[0] == 'o' || v[0] == 't' || v[0] == 'y'); }

void nrs_get(const nr_config_t *c, const nrs_field_t *f, char *out, size_t n)
{
    const void *p = (const char *) c + f->offset;
    switch (f->type) {
        case NRS_TEXT: case NRS_PASSWORD: case NRS_URL: case NRS_SSID:
            nr_strlcpy(out, (const char *) p, n); break;
        case NRS_BOOL:     snprintf(out, n, "%d", *(const bool *) p ? 1 : 0); break;
        case NRS_BOOL_INV: snprintf(out, n, "%d", *(const bool *) p ? 0 : 1); break;
        case NRS_PCT:      snprintf(out, n, "%u", *(const uint8_t *) p); break;
        case NRS_TIME: { uint16_t m = *(const uint16_t *) p; snprintf(out, n, "%02u:%02u", m / 60, m % 60); } break;
        case NRS_NIGHTMODE: snprintf(out, n, "%d", (*(const nr_night_mode_t *) p == NR_NIGHT_OFF) ? 1 : 0); break;
        default: if (n) out[0] = '\0'; break;
    }
}

void nrs_set(nr_config_t *c, const nrs_field_t *f, const char *val)
{
    void *p = (char *) c + f->offset;
    switch (f->type) {
        case NRS_TEXT: case NRS_URL: case NRS_SSID:
            nr_strlcpy((char *) p, val ? val : "", f->size); break;
        case NRS_PASSWORD:
            if (val && val[0]) nr_strlcpy((char *) p, val, f->size);   // empty keeps stored value
            break;
        case NRS_BOOL:      *(bool *) p = truthy(val); break;
        case NRS_BOOL_INV:  *(bool *) p = !truthy(val); break;
        case NRS_PCT: { int v = val ? atoi(val) : 0; v = nr_clampi(v, f->min, f->max); *(uint8_t *) p = (uint8_t) v; } break;
        case NRS_TIME: { int h = 0, m = 0; if (val) sscanf(val, "%d:%d", &h, &m);
                         *(uint16_t *) p = (uint16_t) (nr_clampi(h, 0, 23) * 60 + nr_clampi(m, 0, 59)); } break;
        case NRS_NIGHTMODE: *(nr_night_mode_t *) p = truthy(val) ? NR_NIGHT_OFF : NR_NIGHT_DIM; break;
        default: break;
    }
}
