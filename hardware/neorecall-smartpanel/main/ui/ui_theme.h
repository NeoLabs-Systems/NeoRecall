// SPDX-License-Identifier: MIT
// NeoRecall visual language, extracted from the Flutter app (main_theme.dart):
// a calm, warm, dark forest-green canvas, cream text, a single gold accent, and
// rose reserved for the live-recording state. Reproduced here for the panel.
#pragma once

#include "lvgl.h"

// Canvas & surfaces
#define NRC_BG        lv_color_hex(0x0E1511)   // near-black forest green
#define NRC_BG2       lv_color_hex(0x141C17)
#define NRC_CARD      lv_color_hex(0x171F1A)
#define NRC_CARD2     lv_color_hex(0x1C261F)
#define NRC_BORDER    lv_color_hex(0x2A332C)

// Accents
#define NRC_GOLD      lv_color_hex(0xE1B052)   // brand / idle / primary
#define NRC_GOLD_HI   lv_color_hex(0xEAC272)
#define NRC_ROSE      lv_color_hex(0xD98AA6)   // live recording
#define NRC_SAGE      lv_color_hex(0x84BA87)   // online / secondary

// Text
#define NRC_TX        lv_color_hex(0xECEFE5)   // cream
#define NRC_TX2       lv_color_hex(0xAEB7A6)   // sage-grey
#define NRC_TX3       lv_color_hex(0x7E8877)   // muted

// Semantic
#define NRC_SUCCESS   lv_color_hex(0x74C07C)
#define NRC_WARNING   lv_color_hex(0xE1B052)
#define NRC_DANGER    lv_color_hex(0xDE8A78)
#define NRC_INFO      lv_color_hex(0x6FB0A4)

// Radii (from main_spacing.dart)
#define NRC_R_INPUT   14
#define NRC_R_CARD    18
#define NRC_R_PANEL   24
