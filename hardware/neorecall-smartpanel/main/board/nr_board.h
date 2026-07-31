// SPDX-License-Identifier: MIT
// Board bring-up for the Waveshare ESP32-S3-Touch-LCD-4B: shared I2C, the
// TCA9554 expander, the ST7701 480x480 RGB panel (init bit-banged over the
// expander's 3-wire SPI), GT911 touch, backlight PWM, and the LVGL port.
//
// The rest of the firmware only needs: init once, take the LVGL lock around UI
// mutations, and set the backlight. The microphone lives in nr_mic.c.
#pragma once

#include "nr_common.h"
#include "driver/i2c_master.h"

#ifdef __cplusplus
extern "C" {
#endif

// Initialise I2C, the display + touch stack, and LVGL. On success the LVGL
// task is running and a display + input device are registered.
esp_err_t nr_board_init(void);

// The shared I2C master bus (used by the microphone codec in nr_mic.c).
i2c_master_bus_handle_t nr_board_i2c_bus(void);

// LVGL is not thread-safe: hold this lock around any lv_* call made outside the
// LVGL task's own callbacks. timeout_ms < 0 waits forever.
bool nr_board_lock(int timeout_ms);
void nr_board_unlock(void);

// Backlight duty as a percentage (0..100). 0 turns the panel dark (night-off).
void nr_board_set_backlight(uint8_t percent);
uint8_t nr_board_get_backlight(void);

#ifdef __cplusplus
}
#endif
