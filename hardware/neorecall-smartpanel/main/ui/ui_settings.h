// SPDX-License-Identifier: MIT
// The swipe-up settings app: backend URL, location, display and night-mode
// schedule, plus re-provisioning and restart. Writes straight to nr_config.
#pragma once

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

// Build (once) and return the settings screen.
lv_obj_t *ui_settings_create(void);

#ifdef __cplusplus
}
#endif
