// SPDX-License-Identifier: MIT
// Wall-clock and monotonic time. NTP over the network gives us UTC; the
// configured POSIX TZ turns that into DST-correct local time for the dashboard.
//
// Capture never waits for the clock — chunks are timestamped from a monotonic
// base and the true wall-clock start is stamped onto the session the moment NTP
// lands, so "always recording" holds even before the network is up.
#pragma once

#include <time.h>
#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// Start SNTP (pool.ntp.org + a fallback) and apply the configured timezone.
esp_err_t nr_time_init(void);

// True once we have obtained a real wall clock at least once (year >= 2024).
bool nr_time_is_valid(void);

// Seed the wall clock from an HTTP "Date" response header (RFC 1123, e.g.
// "Wed, 01 Aug 2026 12:34:56 GMT"). Used to show a correct time within the first
// HTTP round-trip after coming online, without waiting for SNTP. No-op once the
// clock is already valid (SNTP remains authoritative).
void nr_time_seed_from_http_date(const char *http_date);

// Monotonic milliseconds since boot — never jumps, safe for durations/offsets.
int64_t nr_time_monotonic_ms(void);

// Current UTC epoch in milliseconds (0 if the clock is not valid yet).
int64_t nr_time_epoch_ms(void);

// Format an epoch-ms instant as ISO-8601 UTC with millisecond precision and a
// trailing 'Z' (e.g. "2026-07-31T02:47:47.739Z"). out must hold NR_ISO8601_LEN.
void nr_time_iso_from_epoch_ms(int64_t epoch_ms, char out[NR_ISO8601_LEN]);

// Convenience: current instant as ISO-8601 UTC.
void nr_time_now_iso(char out[NR_ISO8601_LEN]);

// Fill *out with the current LOCAL time (respects the configured TZ). Returns
// false if the clock is not valid yet.
bool nr_time_local(struct tm *out);

#ifdef __cplusplus
}
#endif
