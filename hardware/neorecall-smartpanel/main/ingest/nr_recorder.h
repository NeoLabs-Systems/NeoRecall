// SPDX-License-Identifier: MIT
// The always-on recorder. Owns the recording-session lifecycle and the capture
// loop: it pulls 16 kHz mono PCM from the board microphone, slices it into WAV
// chunks with the same target/overlap semantics as the NeoRecall Flutter client,
// hashes them, and hands them to the durable spool. It never stops on its own —
// pausing (user) and faults (mic) become truthful capture gaps, and a reboot is
// recovered by closing the prior session as interrupted and opening a new one.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    nr_capture_state_t state;
    float level;             // smoothed input level 0..1 for the UI meter
    int64_t session_started_epoch_ms;  // 0 until the clock is known
    int64_t elapsed_ms;      // since the current session began
    uint32_t sequence;       // chunks emitted this session
} nr_recorder_status_t;

// Start the recorder: recover prior sessions, open a fresh one, launch the
// capture task. Requires nr_spool_init + nr_config_init + board mic available.
esp_err_t nr_recorder_init(void);

// Reflect the persisted pause state (config.recording_enabled) into capture.
// Pausing flushes any partial chunk and begins accumulating a user_paused gap;
// resuming starts a fresh run. Safe to call from the UI task.
void nr_recorder_set_paused(bool paused);

void nr_recorder_get_status(nr_recorder_status_t *out);

#ifdef __cplusplus
}
#endif
