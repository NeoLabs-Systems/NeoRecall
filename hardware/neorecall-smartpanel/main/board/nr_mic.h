// SPDX-License-Identifier: MIT
// Board microphone interface. Implemented by the board layer (ES7210 4-channel
// ADC + I2S RX on the Waveshare ESP32-S3-Touch-LCD-4B). The recorder is written
// entirely against this abstraction so it stays board-independent and testable.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// Configure the codec and I2S for continuous mono capture at sample_rate Hz,
// 16-bit signed samples. Idempotent-ish: safe to call after nr_mic_stop().
esp_err_t nr_mic_start(uint32_t sample_rate);

// Read up to max_samples 16-bit mono samples. Blocks up to timeout_ms.
// *out_samples receives the number actually read (may be 0 on timeout).
// Returns ESP_OK on success (including a 0-sample timeout) or an error on a
// hardware fault so the recorder can attempt recovery.
esp_err_t nr_mic_read(int16_t *dst, size_t max_samples, size_t *out_samples, uint32_t timeout_ms);

// Stop capture and release the I2S channel (used during recovery).
void nr_mic_stop(void);

#ifdef __cplusplus
}
#endif
