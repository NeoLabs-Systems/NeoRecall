// SPDX-License-Identifier: MIT
#include "nr_ui.h"

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <math.h>

#include "lvgl.h"
#include "esp_log.h"

#include "ui/ui_theme.h"
#include "ui/nr_fonts.h"
#include "ui/ui_settings.h"
#include "board/nr_board.h"
#include "config/nr_config.h"
#include "net/nr_time.h"
#include "net/nr_wifi.h"
#include "services/nr_weather.h"
#include "ingest/nr_recorder.h"
#include "ingest/nr_ingest.h"

static const char *TAG = "nr_ui";

#define EQ_BARS 7

static const char *WEEKDAYS[] = {"Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"};
static const char *MONTHS[] = {"Januar", "Februar", "März", "April", "Mai", "Juni",
                               "Juli", "August", "September", "Oktober", "November", "Dezember"};

static lv_obj_t *s_dash;
static lv_obj_t *s_settings;
static lv_obj_t *s_clock, *s_date, *s_city;
static lv_obj_t *s_wx_icon, *s_wx_temp, *s_wx_desc, *s_wx_hilo;
static lv_obj_t *s_rec_dot, *s_rec_text, *s_eq[EQ_BARS];
static lv_obj_t *s_pause_btn, *s_pause_icon;
static lv_obj_t *s_discard_btn;
static lv_obj_t *s_status;

static int64_t s_wake_until_ms;     // tap-to-wake deadline during night mode
static bool s_night_active;         // currently inside the night window (dim or off)
static int s_last_min = -1;
static int s_last_wx_code = -100000;
static volatile bool s_leave_settings;   // set from the portal-saved event, consumed in tick_cb

// ---- small builders --------------------------------------------------------

static lv_obj_t *mk_label(lv_obj_t *parent, const lv_font_t *font, lv_color_t color)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, color, 0);
    return l;
}

static lv_obj_t *mk_card(lv_obj_t *parent, int w, int h)
{
    lv_obj_t *c = lv_obj_create(parent);
    lv_obj_set_size(c, w, h);
    lv_obj_set_style_bg_color(c, NRC_CARD, 0);
    lv_obj_set_style_bg_opa(c, LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(c, NRC_BORDER, 0);
    lv_obj_set_style_border_width(c, 1, 0);
    lv_obj_set_style_radius(c, NRC_R_PANEL, 0);
    lv_obj_set_style_pad_all(c, 16, 0);
    lv_obj_remove_flag(c, LV_OBJ_FLAG_SCROLLABLE);
    return c;
}

// A small NeoRecall mark: gold ring around a rose dot.
//
// Even outer/content/dot sizes keep the center on whole pixels. An odd-sized
// 7px dot inside a 20px content box lands at +6.5 and snaps one pixel off.
static void mk_logo(lv_obj_t *parent, int x, int y)
{
    const int outer = 26;
    const int border = 3;
    const int dot_d = 6; // (outer - 2*border - dot_d) / 2 == 7

    lv_obj_t *ring = lv_obj_create(parent);
    lv_obj_set_size(ring, outer, outer);
    lv_obj_set_pos(ring, x, y);
    lv_obj_set_style_radius(ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(ring, lv_color_hex(0x151922), 0);
    lv_obj_set_style_border_color(ring, NRC_GOLD, 0);
    lv_obj_set_style_border_width(ring, border, 0);
    lv_obj_set_style_pad_all(ring, 0, 0);
    lv_obj_set_style_outline_width(ring, 0, 0);
    lv_obj_set_style_shadow_width(ring, 0, 0);
    lv_obj_remove_flag(ring, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *dot = lv_obj_create(ring);
    lv_obj_set_size(dot, dot_d, dot_d);
    lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(dot, NRC_ROSE, 0);
    lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(dot, 0, 0);
    lv_obj_set_style_pad_all(dot, 0, 0);
    lv_obj_set_style_outline_width(dot, 0, 0);
    lv_obj_set_style_shadow_width(dot, 0, 0);
    lv_obj_remove_flag(dot, LV_OBJ_FLAG_SCROLLABLE);
    // Align after styles so padding/border content box is final.
    lv_obj_align(dot, LV_ALIGN_CENTER, 0, 0);
}

// ---- weather icon ----------------------------------------------------------

static lv_obj_t *circle(lv_obj_t *p, int d, lv_color_t c, int x, int y)
{
    lv_obj_t *o = lv_obj_create(p);
    lv_obj_set_size(o, d, d);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(o, c, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

static void draw_weather_icon(lv_obj_t *cont, nr_wx_cat_t cat, bool is_day)
{
    lv_obj_clean(cont);   // 56x56 canvas
    switch (cat) {
        case NR_WX_CLEAR: {
            lv_obj_t *sun = circle(cont, 34, is_day ? NRC_GOLD : lv_color_hex(0xC9D2C4), 11, 11);
            lv_obj_set_style_shadow_color(sun, NRC_GOLD, 0);
            lv_obj_set_style_shadow_width(sun, is_day ? 18 : 0, 0);
            break;
        }
        case NR_WX_CLOUDY:
            circle(cont, 22, NRC_TX3, 8, 22);
            circle(cont, 28, NRC_TX2, 18, 16);
            circle(cont, 20, NRC_TX3, 34, 24);
            break;
        case NR_WX_RAIN:
            circle(cont, 26, NRC_TX2, 15, 10);
            circle(cont, 18, NRC_TX3, 8, 18);
            circle(cont, 6, NRC_INFO, 16, 42);
            circle(cont, 6, NRC_INFO, 26, 44);
            circle(cont, 6, NRC_INFO, 36, 42);
            break;
        case NR_WX_SNOW:
            circle(cont, 26, NRC_TX2, 15, 10);
            circle(cont, 6, NRC_TX, 16, 42);
            circle(cont, 6, NRC_TX, 26, 44);
            circle(cont, 6, NRC_TX, 36, 42);
            break;
        case NR_WX_THUNDER: {
            circle(cont, 28, NRC_TX2, 14, 10);
            lv_obj_t *bolt = circle(cont, 12, NRC_GOLD, 22, 34);
            lv_obj_set_style_radius(bolt, 3, 0);
            break;
        }
        case NR_WX_FOG:
            for (int i = 0; i < 3; i++) {
                lv_obj_t *bar = lv_obj_create(cont);
                lv_obj_set_size(bar, 40, 5);
                lv_obj_set_pos(bar, 8, 14 + i * 12);
                lv_obj_set_style_radius(bar, 3, 0);
                lv_obj_set_style_bg_color(bar, NRC_TX2, 0);
                lv_obj_set_style_border_width(bar, 0, 0);
                lv_obj_remove_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
            }
            break;
    }
}

// ---- interactions ----------------------------------------------------------

static void pause_cb(lv_event_t *e)
{
    (void) e;
    nr_config_t c; nr_config_get(&c);
    bool now_paused = c.recording_enabled;   // toggling: if enabled -> pause
    nr_config_set_recording_enabled(!c.recording_enabled);
    nr_recorder_set_paused(now_paused);
}

static void gear_cb(lv_event_t *e) { (void) e; nr_ui_show_settings(); }

static void discard_confirm_cb(lv_event_t *e)
{
    lv_obj_t *mb = lv_event_get_user_data(e);
    nr_recorder_discard();
    if (mb) lv_msgbox_close(mb);
}
static void discard_cb(lv_event_t *e)
{
    (void) e;
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, "Aufnahme verwerfen?");
    lv_msgbox_add_text(mb, "Die lokale, noch nicht hochgeladene Aufnahme wird gelöscht und die Aufnahme gestoppt.");
    lv_obj_t *ok = lv_msgbox_add_footer_button(mb, "Verwerfen");
    lv_obj_set_style_bg_color(ok, NRC_DANGER, 0);
    lv_obj_add_event_cb(ok, discard_confirm_cb, LV_EVENT_CLICKED, mb);
    lv_msgbox_add_close_button(mb);
}

static void dash_gesture_cb(lv_event_t *e)
{
    (void) e;
    lv_dir_t d = lv_indev_get_gesture_dir(lv_indev_active());
    if (d == LV_DIR_TOP) nr_ui_show_settings();
}

// A touch wakes the panel to full brightness for a few seconds during night mode
// — whether it is dimmed or fully off.
static void wake_cb(lv_event_t *e)
{
    (void) e;
    if (s_night_active) {
        nr_config_t c; nr_config_get(&c);
        s_wake_until_ms = nr_time_monotonic_ms() + (int64_t) c.wake_seconds * 1000;
        nr_board_set_backlight(c.brightness_day);
    }
}

// ---- dashboard build -------------------------------------------------------

static void build_dashboard(void)
{
    s_dash = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_dash, NRC_BG, 0);
    lv_obj_set_style_text_font(s_dash, &nr_font_16, 0);   // Latin-1 default for umlauts
    lv_obj_set_style_bg_grad_color(s_dash, NRC_BG2, 0);
    lv_obj_set_style_bg_grad_dir(s_dash, LV_GRAD_DIR_VER, 0);
    lv_obj_remove_flag(s_dash, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(s_dash, dash_gesture_cb, LV_EVENT_GESTURE, NULL);
    lv_obj_add_event_cb(s_dash, wake_cb, LV_EVENT_PRESSED, NULL);

    // Header: logo + wordmark, gear button
    mk_logo(s_dash, 20, 18);
    lv_obj_t *word = mk_label(s_dash, &nr_font_20, NRC_TX);
    lv_label_set_text(word, "NeoRecall");
    lv_obj_set_pos(word, 54, 20);

    lv_obj_t *gear = lv_button_create(s_dash);
    lv_obj_set_size(gear, 44, 44);
    lv_obj_align(gear, LV_ALIGN_TOP_RIGHT, -16, 12);
    lv_obj_set_style_bg_color(gear, NRC_CARD, 0);
    lv_obj_set_style_border_color(gear, NRC_BORDER, 0);
    lv_obj_set_style_border_width(gear, 1, 0);
    lv_obj_set_style_radius(gear, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_shadow_width(gear, 0, 0);
    lv_obj_add_event_cb(gear, gear_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *gl = mk_label(gear, &nr_font_20, NRC_TX2);
    lv_label_set_text(gl, LV_SYMBOL_SETTINGS);
    lv_obj_center(gl);

    // Clock + date
    s_clock = mk_label(s_dash, &nr_font_48, NRC_TX);
    lv_label_set_text(s_clock, "--:--");
    lv_obj_align(s_clock, LV_ALIGN_TOP_MID, 0, 72);

    s_date = mk_label(s_dash, &nr_font_20, NRC_TX2);
    lv_label_set_text(s_date, "");
    lv_obj_align(s_date, LV_ALIGN_TOP_MID, 0, 138);

    // Weather card
    lv_obj_t *wx = mk_card(s_dash, 400, 132);
    lv_obj_align(wx, LV_ALIGN_TOP_MID, 0, 182);

    s_wx_icon = lv_obj_create(wx);
    lv_obj_set_size(s_wx_icon, 56, 56);
    lv_obj_align(s_wx_icon, LV_ALIGN_LEFT_MID, 4, -12);
    lv_obj_set_style_bg_opa(s_wx_icon, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_wx_icon, 0, 0);
    lv_obj_set_style_pad_all(s_wx_icon, 0, 0);
    lv_obj_remove_flag(s_wx_icon, LV_OBJ_FLAG_SCROLLABLE);

    s_wx_temp = mk_label(wx, &nr_font_36, NRC_TX);
    lv_label_set_text(s_wx_temp, "--°");
    lv_obj_align(s_wx_temp, LV_ALIGN_LEFT_MID, 78, -12);

    s_wx_desc = mk_label(wx, &nr_font_16, NRC_TX2);
    lv_label_set_text(s_wx_desc, "Wetter wird geladen …");
    lv_obj_align(s_wx_desc, LV_ALIGN_LEFT_MID, 80, 22);

    s_wx_hilo = mk_label(wx, &nr_font_14, NRC_TX3);
    lv_label_set_text(s_wx_hilo, "");
    lv_obj_align(s_wx_hilo, LV_ALIGN_TOP_RIGHT, -4, 4);

    s_city = mk_label(wx, &nr_font_14, NRC_TX3);
    lv_label_set_text(s_city, "");
    lv_obj_align(s_city, LV_ALIGN_BOTTOM_RIGHT, -4, 2);

    // Recording row (dot + text + equalizer)
    s_rec_dot = circle(s_dash, 12, NRC_TX3, 0, 0);
    lv_obj_align(s_rec_dot, LV_ALIGN_TOP_MID, -120, 340);
    s_rec_text = mk_label(s_dash, &nr_font_16, NRC_TX2);
    lv_label_set_text(s_rec_text, "…");
    lv_obj_align(s_rec_text, LV_ALIGN_TOP_MID, -40, 336);

    for (int i = 0; i < EQ_BARS; i++) {
        s_eq[i] = lv_obj_create(s_dash);
        lv_obj_set_size(s_eq[i], 7, 8);
        lv_obj_set_style_radius(s_eq[i], 3, 0);
        lv_obj_set_style_bg_color(s_eq[i], NRC_ROSE, 0);
        lv_obj_set_style_border_width(s_eq[i], 0, 0);
        lv_obj_remove_flag(s_eq[i], LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_align(s_eq[i], LV_ALIGN_TOP_MID, 70 + i * 11, 348);
    }

    // Pause / resume button, bottom-left
    s_pause_btn = lv_button_create(s_dash);
    lv_obj_set_size(s_pause_btn, 60, 60);
    lv_obj_align(s_pause_btn, LV_ALIGN_BOTTOM_LEFT, 22, -20);
    lv_obj_set_style_radius(s_pause_btn, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(s_pause_btn, NRC_CARD, 0);
    lv_obj_set_style_border_color(s_pause_btn, NRC_GOLD, 0);
    lv_obj_set_style_border_width(s_pause_btn, 2, 0);
    lv_obj_set_style_shadow_width(s_pause_btn, 0, 0);
    lv_obj_add_event_cb(s_pause_btn, pause_cb, LV_EVENT_CLICKED, NULL);
    s_pause_icon = mk_label(s_pause_btn, &nr_font_24, NRC_GOLD);
    lv_label_set_text(s_pause_icon, LV_SYMBOL_PAUSE);
    lv_obj_center(s_pause_icon);

    // Discard button, bottom-right (only visible while recording)
    s_discard_btn = lv_button_create(s_dash);
    lv_obj_set_size(s_discard_btn, 60, 60);
    lv_obj_align(s_discard_btn, LV_ALIGN_BOTTOM_RIGHT, -22, -20);
    lv_obj_set_style_radius(s_discard_btn, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(s_discard_btn, NRC_CARD, 0);
    lv_obj_set_style_border_color(s_discard_btn, NRC_DANGER, 0);
    lv_obj_set_style_border_width(s_discard_btn, 2, 0);
    lv_obj_set_style_shadow_width(s_discard_btn, 0, 0);
    lv_obj_add_event_cb(s_discard_btn, discard_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *dic = mk_label(s_discard_btn, &nr_font_24, NRC_DANGER);
    lv_label_set_text(dic, LV_SYMBOL_TRASH);
    lv_obj_center(dic);
    lv_obj_add_flag(s_discard_btn, LV_OBJ_FLAG_HIDDEN);

    // Status bar
    s_status = mk_label(s_dash, &nr_font_14, NRC_TX3);
    lv_label_set_text(s_status, "");
    lv_obj_align(s_status, LV_ALIGN_BOTTOM_MID, 24, -30);
}

// ---- refresh ---------------------------------------------------------------

static void refresh_clock(void)
{
    struct tm tm;
    if (!nr_time_local(&tm)) { lv_label_set_text(s_clock, "--:--"); return; }
    if (tm.tm_min == s_last_min) return;
    s_last_min = tm.tm_min;
    nr_config_t c; nr_config_get(&c);
    char buf[8];
    if (c.clock_24h) snprintf(buf, sizeof(buf), "%02d:%02d", tm.tm_hour, tm.tm_min);
    else {
        int h = tm.tm_hour % 12; if (h == 0) h = 12;
        snprintf(buf, sizeof(buf), "%d:%02d", h, tm.tm_min);
    }
    lv_label_set_text(s_clock, buf);
    char date[48];
    snprintf(date, sizeof(date), "%s · %d. %s", WEEKDAYS[tm.tm_wday % 7], tm.tm_mday, MONTHS[tm.tm_mon % 12]);
    lv_label_set_text(s_date, date);
}

static void refresh_weather(void)
{
    nr_weather_t w; nr_weather_get(&w);
    if (!w.valid) return;
    if (w.weather_code == s_last_wx_code) return;
    s_last_wx_code = w.weather_code;
    char t[16]; snprintf(t, sizeof(t), "%d°", (int) lroundf(w.temp));
    lv_label_set_text(s_wx_temp, t);
    lv_label_set_text(s_wx_desc, w.desc);
    char hilo[32]; snprintf(hilo, sizeof(hilo), "%d° / %d°", (int) lroundf(w.today_max), (int) lroundf(w.today_min));
    lv_label_set_text(s_wx_hilo, hilo);
    nr_config_t c; nr_config_get(&c);
    lv_label_set_text(s_city, c.city[0] ? c.city : "");
    draw_weather_icon(s_wx_icon, w.category, w.is_day);
}

static void refresh_recording(void)
{
    nr_recorder_status_t r; nr_recorder_get_status(&r);
    bool live = r.state == NR_CAP_RECORDING;
    lv_obj_set_style_bg_color(s_rec_dot, live ? NRC_ROSE : (r.state == NR_CAP_PAUSED ? NRC_TX3 : NRC_WARNING), 0);

    const char *txt = "Bereit";
    if (r.state == NR_CAP_RECORDING) txt = "Aufnahme läuft";
    else if (r.state == NR_CAP_PAUSED) txt = "Pausiert";
    else if (r.state == NR_CAP_ERROR) txt = "Mikrofon-Problem – erhole …";
    lv_label_set_text(s_rec_text, txt);

    lv_label_set_text(s_pause_icon, r.state == NR_CAP_PAUSED ? LV_SYMBOL_PLAY : LV_SYMBOL_PAUSE);
    lv_obj_set_style_border_color(s_pause_btn, r.state == NR_CAP_PAUSED ? NRC_GOLD : NRC_ROSE, 0);
    lv_obj_set_style_text_color(s_pause_icon, r.state == NR_CAP_PAUSED ? NRC_GOLD : NRC_ROSE, 0);
    if (live) lv_obj_remove_flag(s_discard_btn, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_discard_btn, LV_OBJ_FLAG_HIDDEN);

    // Equalizer: lively when recording, flat when not.
    static const int weight[EQ_BARS] = {40, 70, 100, 85, 100, 65, 45};
    static uint32_t phase;
    phase++;
    for (int i = 0; i < EQ_BARS; i++) {
        int h = 6;
        if (live) {
            float wob = 0.55f + 0.45f * ((float) ((phase * (i + 3)) % 7) / 6.0f);
            // sqrt makes quiet room sound clearly visible instead of a flat line.
            h = 6 + (int) (sqrtf(r.level) * weight[i] * 0.42f * wob);
            if (h > 40) h = 40;
        }
        lv_obj_set_height(s_eq[i], h);
        lv_obj_align(s_eq[i], LV_ALIGN_TOP_MID, 70 + i * 11, 348 + (40 - h));
        lv_obj_set_style_bg_opa(s_eq[i], live ? LV_OPA_COVER : LV_OPA_30, 0);
    }
}

static void refresh_status(void)
{
    char line[160];
    nr_net_state_t net = nr_net_state();
    nr_ingest_status_t ing; nr_ingest_get_status(&ing);

    if (nr_wifi_ap_active()) {
        char ssid[33]; nr_wifi_ap_ssid(ssid);
        char line[80];
        snprintf(line, sizeof(line), LV_SYMBOL_WIFI "  Hotspot: %s → 192.168.4.1", ssid);
        lv_label_set_text(s_status, line);
        lv_obj_set_style_text_color(s_status, NRC_GOLD_HI, 0);
        return;
    }
    if (!ing.provisioned) {
        lv_label_set_text(s_status, LV_SYMBOL_SETTINGS "  Einrichtung nötig – tippe auf das Zahnrad");
        lv_obj_set_style_text_color(s_status, NRC_GOLD_HI, 0);
        return;
    }
    const char *net_txt;
    switch (net) {
        case NR_NET_ONLINE: net_txt = LV_SYMBOL_WIFI " Online"; break;
        case NR_NET_CONNECTING: net_txt = LV_SYMBOL_WIFI " Verbinde …"; break;
        default: net_txt = LV_SYMBOL_WARNING " Offline"; break;
    }
    if (ing.pending_upload > 0) {
        if (ing.last_error[0] && net == NR_NET_ONLINE)
            snprintf(line, sizeof(line), "%s   %s %u senden · %s",
                     net_txt, LV_SYMBOL_UPLOAD, (unsigned) ing.pending_upload, ing.last_error);
        else
            snprintf(line, sizeof(line), "%s   %s %u senden …",
                     net_txt, LV_SYMBOL_UPLOAD, (unsigned) ing.pending_upload);
    } else if (ing.awaiting_receipt > 0)
        snprintf(line, sizeof(line), "%s   %s %u verarbeitet …",
                 net_txt, LV_SYMBOL_OK, (unsigned) ing.awaiting_receipt);
    else if (ing.last_error[0] && strstr(ing.last_error, "verworfen") && net == NR_NET_ONLINE)
        snprintf(line, sizeof(line), "%s   %s %s",
                 net_txt, LV_SYMBOL_WARNING, ing.last_error);
    else if (net == NR_NET_ONLINE && ing.provisioned)
        snprintf(line, sizeof(line), "%s   %s synchron", net_txt, LV_SYMBOL_OK);
    else
        snprintf(line, sizeof(line), "%s", net_txt);
    lv_label_set_text(s_status, line);
    lv_obj_set_style_text_color(s_status,
        (ing.pending_upload && ing.last_error[0]) ||
        (ing.last_error[0] && strstr(ing.last_error, "verworfen"))
            ? NRC_DANGER : NRC_TX3, 0);
}

// ---- night schedule --------------------------------------------------------

static bool in_night_window(const nr_config_t *c, int minute_of_day)
{
    if (!c->night_enabled) return false;
    int s = c->night_start_min, e = c->night_end_min;
    if (s == e) return false;
    if (s < e) return minute_of_day >= s && minute_of_day < e;
    return minute_of_day >= s || minute_of_day < e;   // crosses midnight
}

static void apply_night(void)
{
    nr_config_t c; nr_config_get(&c);
    struct tm tm;
    bool have = nr_time_local(&tm);
    int mod = have ? tm.tm_hour * 60 + tm.tm_min : -1;
    bool night = have && in_night_window(&c, mod);
    s_night_active = night;

    if (!night) { s_wake_until_ms = 0; nr_board_set_backlight(c.brightness_day); return; }

    // Inside the night window: a recent tap keeps full brightness briefly.
    if (s_wake_until_ms && nr_time_monotonic_ms() < s_wake_until_ms) {
        nr_board_set_backlight(c.brightness_day);
        return;
    }
    s_wake_until_ms = 0;
    nr_board_set_backlight(c.night_mode == NR_NIGHT_OFF ? 0 : c.brightness_night);
}

// Posted from the captive portal (other task) when phone setup completes; the
// actual screen switch must happen on the LVGL task, so just raise a flag here.
static void on_portal_saved(void *a, esp_event_base_t b, int32_t id, void *d)
{
    (void) a; (void) b; (void) id; (void) d;
    s_leave_settings = true;
}

static void tick_cb(lv_timer_t *t)
{
    (void) t;
    // Setup finished on the phone -> leave the on-device settings screen so the
    // two views don't disagree about whether configuration is done.
    if (s_leave_settings) {
        s_leave_settings = false;
        if (lv_screen_active() != s_dash) nr_ui_show_dashboard();
        nr_weather_refresh_now();   // fetch weather now that we're configured
    }
    if (lv_screen_active() == s_dash) {
        refresh_clock();
        refresh_weather();
        refresh_recording();
        refresh_status();
    }
    static int night_div;
    if (++night_div >= 5) { night_div = 0; apply_night(); }   // ~ every 1 s (snappy wake)
}

// ---- navigation ------------------------------------------------------------

void nr_ui_show_dashboard(void)
{
    if (s_dash) lv_screen_load_anim(s_dash, LV_SCR_LOAD_ANIM_MOVE_BOTTOM, 250, 0, false);
}

void nr_ui_show_settings(void)
{
    if (!s_settings) s_settings = ui_settings_create();
    if (s_settings) lv_screen_load_anim(s_settings, LV_SCR_LOAD_ANIM_MOVE_TOP, 250, 0, false);
}

esp_err_t nr_ui_init(void)
{
    if (!nr_board_lock(1000)) return ESP_FAIL;
    lv_obj_set_style_text_font(lv_layer_top(), &nr_font_16, 0);   // umlauts in msgboxes
    build_dashboard();
    lv_screen_load(s_dash);
    lv_timer_create(tick_cb, 200, NULL);
    esp_event_handler_instance_register(NR_EVENT, NR_EVT_PORTAL_SAVED, on_portal_saved, NULL, NULL);
    apply_night();
    // First boot: nothing is configured yet, so drop the user straight into the
    // on-device setup screen (Wi-Fi + backend URL + login).
    if (!nr_config_is_provisioned()) {
        s_settings = ui_settings_create();
        if (s_settings) lv_screen_load(s_settings);
    }
    nr_board_unlock();
    ESP_LOGI(TAG, "UI ready");
    return ESP_OK;
}
