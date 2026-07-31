// SPDX-License-Identifier: MIT
// Wi-Fi station manager with resilient reconnect. Everything is configured on
// the device itself (touchscreen), so there is no SoftAP/provisioning mode — the
// settings app scans for networks and applies credentials directly.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// Initialise netif + Wi-Fi and start the station (so scanning works even before
// any credentials exist). Requires the default event loop.
esp_err_t nr_wifi_init(void);

// Connect to the currently configured SSID. No-op if no SSID is set.
esp_err_t nr_wifi_connect(void);

// Apply freshly saved credentials and (re)connect the station.
void nr_wifi_reconfigure(void);

// Blocking scan for nearby networks. Fills up to `max` unique SSIDs into `out`
// (each up to 32 chars + NUL) and returns the count. Safe to call from a task.
int nr_wifi_scan(char (*out)[33], int max);

nr_net_state_t nr_net_state(void);
bool nr_net_is_online(void);

// Copy the current IPv4 address string. Returns false when not connected.
bool nr_wifi_ip(char out[16]);

#ifdef __cplusplus
}
#endif
