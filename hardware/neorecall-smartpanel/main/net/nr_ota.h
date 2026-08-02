// SPDX-License-Identifier: MIT
// Over-the-air firmware updates. A background task periodically fetches a JSON
// manifest (published by the build-firmware GitHub Action) and, if it names a
// version different from the running one, downloads and installs it with
// esp_https_ota, then reboots. A failed/rolled-back image is reverted by the
// bootloader; a healthy boot is confirmed after an uptime grace period.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool enabled;
    bool checking;
    bool updating;
    int  progress;                 // 0..100 during a download
    char running_version[48];
    char latest_version[48];
    char status[80];               // human-readable last result (German)
} nr_ota_status_t;

esp_err_t nr_ota_init(void);

// Trigger an immediate check (and install if a newer image is available).
// force=true runs even when automatic updates are disabled in config — used by
// the Settings "Jetzt prüfen" button.
void nr_ota_check_now(bool force);
void nr_ota_get_status(nr_ota_status_t *out);

#ifdef __cplusplus
}
#endif
