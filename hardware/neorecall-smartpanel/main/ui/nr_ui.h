// SPDX-License-Identifier: MIT
// The on-device UI: a NeoRecall-styled dashboard (clock, weekday, date, weather,
// live recording state, pause/resume) and a swipe-up settings app. Night-mode
// dimming/blanking with tap-to-wake. All LVGL work happens on the LVGL task.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// Build the screens and start the refresh + night timers. Requires nr_board_init.
esp_err_t nr_ui_init(void);

void nr_ui_show_dashboard(void);
void nr_ui_show_settings(void);

#ifdef __cplusplus
}
#endif
