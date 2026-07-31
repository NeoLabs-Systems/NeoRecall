// SPDX-License-Identifier: MIT
// Single source of truth for every pin and I2C address on the
// Waveshare ESP32-S3-Touch-LCD-4B ("Smart 86 Box").
//
// Verified against the official schematic (Rev 2.1.1) AND a compile-tested
// ESPHome reference for this exact board. Where a value is a datasheet default
// rather than a schematic label it is marked; verify with an I2C scan / test
// image on first bring-up (see README "Board bring-up notes").
#pragma once

// ---- Shared I2C bus (400 kHz) ---------------------------------------------
#define BRD_I2C_PORT        0
#define BRD_I2C_SDA         47
#define BRD_I2C_SCL         48
#define BRD_I2C_HZ          400000

// I2C addresses on the shared bus
#define BRD_ADDR_TCA9554    0x20   // IO expander (LCD CS/SDA/SCL/RST, PA enable)
#define BRD_ADDR_GT911      0x5D   // touch (or 0x14 depending on reset strap)
#define BRD_ADDR_ES7210     0x40   // 4-ch ADC (microphones)
#define BRD_ADDR_ES8311     0x18   // codec/DAC (speaker)
#define BRD_ADDR_AXP2101    0x34   // PMU (left at power-on defaults)
#define BRD_ADDR_QMI8658    0x6B   // IMU (unused by this firmware)
#define BRD_ADDR_PCF85063   0x51   // RTC (unused; we use SNTP)

// ---- TCA9554 expander EXIO assignment -------------------------------------
#define BRD_EXIO_LCD_CS     0
#define BRD_EXIO_LCD_SDA    1      // ST7701 3-wire SPI data (MOSI)
#define BRD_EXIO_LCD_SCL    2      // ST7701 3-wire SPI clock
#define BRD_EXIO_PA_EN      3      // NS4150B speaker amplifier enable
#define BRD_EXIO_TP_RST     5      // GT911 reset (schematic); ESPHome leaves it alone
#define BRD_EXIO_TP_INT     6      // GT911 interrupt (schematic)
#define BRD_EXIO_LCD_RST    7

// ---- RGB (16-bit parallel) LCD, ST7701 480x480 ----------------------------
#define BRD_LCD_H_RES       480
#define BRD_LCD_V_RES       480
#define BRD_LCD_PCLK        9
#define BRD_LCD_DE          17
#define BRD_LCD_HSYNC       46
#define BRD_LCD_VSYNC       3
#define BRD_LCD_BL          4      // backlight (active low, via AP3032 boost)
#define BRD_LCD_PCLK_HZ     (12 * 1000 * 1000)
#define BRD_LCD_HSYNC_PULSE 10
#define BRD_LCD_HSYNC_BACK  10
#define BRD_LCD_HSYNC_FRONT 20
#define BRD_LCD_VSYNC_PULSE 10
#define BRD_LCD_VSYNC_BACK  10
#define BRD_LCD_VSYNC_FRONT 10
// ST7701 3-wire SPI init clock (bit-banged through the expander)
#define BRD_LCD_SPI_HZ      (500 * 1000)

// RGB565 data lines in esp_lcd order: B0..B4, G0..G5, R0..R4
// (schematic mapping; if red/blue look swapped, toggle the panel RGB element
// order in nr_display.c — a known one-line bring-up tweak.)
#define BRD_LCD_DATA_GPIOS  { 40, 41, 42, 2, 1,  21, 8, 18, 45, 38, 39,  10, 11, 12, 13, 14 }

// ---- I2S audio (ES7210 mic in / ES8311 spk out) ---------------------------
#define BRD_I2S_MCLK        5
#define BRD_I2S_BCLK        16
#define BRD_I2S_WS          7
#define BRD_I2S_DIN         15     // ADC -> ESP (microphones)
#define BRD_I2S_DOUT        6      // ESP -> DAC (speaker)

// ---- Buttons ---------------------------------------------------------------
#define BRD_BTN_BOOT        0      // BOOT/Key1 (also strap)

// ---- Storage ---------------------------------------------------------------
// No SD slot on this board; the spool lives on an internal LittleFS partition.
#define BRD_SPOOL_MOUNT     "/spool"
#define BRD_SPOOL_LABEL     "spool"
