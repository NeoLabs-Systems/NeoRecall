// SPDX-License-Identifier: MIT
#include "nr_common.h"

ESP_EVENT_DEFINE_BASE(NR_EVENT);

const char *nr_gap_reason_str(nr_gap_reason_t reason)
{
    switch (reason) {
        case NR_GAP_SLEEP:           return "sleep";
        case NR_GAP_PERMISSION_LOST: return "permission_lost";
        case NR_GAP_STORAGE_FULL:    return "storage_full";
        case NR_GAP_CAPTURE_ERROR:   return "capture_error";
        case NR_GAP_USER_PAUSED:     return "user_paused";
        case NR_GAP_DEVICE_SHUTDOWN: return "device_shutdown";
    }
    return "capture_error";
}
