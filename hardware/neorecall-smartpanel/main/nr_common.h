// SPDX-License-Identifier: MIT
// NeoRecall Smart Panel firmware — shared definitions.
//
// This firmware turns a Waveshare ESP32-S3 "Smart 86 Box" (4" 480x480 RGB
// touch panel) into an always-on NeoRecall room recorder with a dashboard.
//
// Design goals, in priority order:
//   1. Never lose audio. Capture runs 24/7 and audio is only released after the
//      NeoRecall backend proves a terminal transcript receipt (the reliability
//      invariant from AGENTS.md). Every dropped span is declared as a truthful
//      capture gap, never silently discarded.
//   2. Stay up. Every long-running activity is an independent supervised task
//      that recovers from its own failures without taking the device down.
//   3. Be beautiful and useful sitting in a room: clock, weekday, date and
//      keyless weather in the NeoRecall visual language.
//
// All backend interaction speaks the exact same /api/v1 ingest protocol the
// Flutter client uses (see flutter_app/lib/src/api_client.dart and
// capture_pipeline.dart) so the panel appears as just another device in the
// same transcribe/consolidate flow. No backend changes are required.

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "esp_err.h"
#include "esp_event.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NR_FIRMWARE_VERSION "1.0.1"

// UUID string length including the null terminator ("8-4-4-4-12").
#define NR_UUID_LEN 37
// ISO-8601 UTC timestamp, e.g. "2026-07-31T02:47:47.739Z".
#define NR_ISO8601_LEN 28

// Application-wide event base. The UI subscribes to these to stay in sync with
// the capture/upload/network subsystems without polling private state.
ESP_EVENT_DECLARE_BASE(NR_EVENT);

typedef enum {
    NR_EVT_WIFI_CHANGED = 1,   // connectivity state changed
    NR_EVT_TIME_SYNCED,        // wall clock became valid
    NR_EVT_RECORDING_CHANGED,  // paused/resumed or capture health changed
    NR_EVT_UPLOAD_CHANGED,     // spool backlog / terminal receipts changed
    NR_EVT_WEATHER_CHANGED,    // fresh weather available
    NR_EVT_CONFIG_CHANGED,     // persisted settings mutated
    NR_EVT_PORTAL_SAVED,       // user completed setup via the phone captive portal
} nr_event_id_t;

// Coarse connectivity state shown on the dashboard and used to gate uploads.
typedef enum {
    NR_NET_BOOT = 0,
    NR_NET_CONNECTING,
    NR_NET_ONLINE,         // station has an IP
    NR_NET_OFFLINE,        // no link / no credentials yet, retrying with backoff
} nr_net_state_t;

// Capture health, independent of whether uploads are flowing.
typedef enum {
    NR_CAP_IDLE = 0,       // not started yet
    NR_CAP_RECORDING,      // microphone delivering audio into the spool
    NR_CAP_PAUSED,         // user paused; a user_paused gap is being accumulated
    NR_CAP_ERROR,          // mic/codec fault; supervisor is recovering
} nr_capture_state_t;

// Reasons a span of time carries no audio. These map 1:1 onto the backend's
// recording_gaps.reason enum (see server/routes/ingest.js gapSchema).
typedef enum {
    NR_GAP_SLEEP = 0,
    NR_GAP_PERMISSION_LOST,
    NR_GAP_STORAGE_FULL,
    NR_GAP_CAPTURE_ERROR,
    NR_GAP_USER_PAUSED,
    NR_GAP_DEVICE_SHUTDOWN,
} nr_gap_reason_t;

const char *nr_gap_reason_str(nr_gap_reason_t reason);

// Convenience: log an esp_err_t and return it unchanged, so callers can write
//   return NR_LOGE_ON_ERR(TAG, some_call());
#define NR_RETURN_ON_ERR(expr)              \
    do {                                    \
        esp_err_t _err_rc = (expr);         \
        if (_err_rc != ESP_OK) return _err_rc; \
    } while (0)

#ifdef __cplusplus
}
#endif
