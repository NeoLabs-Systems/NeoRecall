// SPDX-License-Identifier: MIT
// Captive-portal settings server. Started on demand together with the config
// SoftAP (see nr_wifi_start_ap). Every field it shows is generated from the
// shared NR_SETTINGS schema and written back into the same nr_config, so the
// phone form and the on-device screen always expose identical settings.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t nr_portal_start(void);
void nr_portal_stop(void);

#ifdef __cplusplus
}
#endif
