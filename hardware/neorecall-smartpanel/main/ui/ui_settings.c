// SPDX-License-Identifier: MIT
#include "ui/ui_settings.h"

#include <stdio.h>
#include <string.h>

#include "lvgl.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "ui/ui_theme.h"
#include "ui/nr_ui.h"
#include "board/nr_board.h"
#include "config/nr_config.h"
#include "net/nr_wifi.h"
#include "services/nr_geo.h"
#include "services/nr_weather.h"

static lv_obj_t *s_scr, *s_kb;
static lv_obj_t *dd_ssid, *ta_pass, *ta_url, *ta_key, *ta_city;
static lv_obj_t *sw_tls, *sw_loc_auto, *sw_24h, *sw_units, *sw_night, *sw_night_off;
static lv_obj_t *sl_bri_day, *sl_bri_night;
static lv_obj_t *rol_sh, *rol_sm, *rol_eh, *rol_em;

// Wi-Fi scan results, filled by a background task and applied on the LVGL task.
static char s_scan[20][33];
static int s_scan_n;
static volatile bool s_scanning;

static const char *HOURS = "00\n01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23";
static const char *MINS5 = "00\n05\n10\n15\n20\n25\n30\n35\n40\n45\n50\n55";

// ---- builders --------------------------------------------------------------

static lv_obj_t *section(lv_obj_t *parent, const char *title)
{
    lv_obj_t *hdr = lv_label_create(parent);
    lv_obj_set_style_text_font(hdr, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(hdr, NRC_GOLD_HI, 0);
    lv_obj_set_style_pad_left(hdr, 6, 0);
    lv_obj_set_style_pad_top(hdr, 10, 0);
    lv_label_set_text(hdr, title);

    lv_obj_t *card = lv_obj_create(parent);
    lv_obj_set_width(card, lv_pct(100));
    lv_obj_set_height(card, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_color(card, NRC_CARD, 0);
    lv_obj_set_style_border_color(card, NRC_BORDER, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_radius(card, NRC_R_CARD, 0);
    lv_obj_set_style_pad_all(card, 14, 0);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(card, 12, 0);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    return card;
}

static lv_obj_t *row(lv_obj_t *parent, const char *label)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_set_width(r, lv_pct(100));
    lv_obj_set_height(r, LV_SIZE_CONTENT);
    lv_obj_set_style_bg_opa(r, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(r, 0, 0);
    lv_obj_set_style_pad_all(r, 0, 0);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_remove_flag(r, LV_OBJ_FLAG_SCROLLABLE);
    if (label && label[0]) {
        lv_obj_t *l = lv_label_create(r);
        lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
        lv_obj_set_style_text_color(l, NRC_TX, 0);
        lv_label_set_text(l, label);
    }
    return r;
}

// A labelled full-width text field (with optional password masking).
static lv_obj_t *field(lv_obj_t *parent, const char *label, const char *placeholder, bool password);

static lv_obj_t *add_switch(lv_obj_t *parent, const char *label, bool on)
{
    lv_obj_t *r = row(parent, label);
    lv_obj_t *sw = lv_switch_create(r);
    lv_obj_set_style_bg_color(sw, NRC_GOLD, LV_PART_INDICATOR | LV_STATE_CHECKED);
    if (on) lv_obj_add_state(sw, LV_STATE_CHECKED);
    return sw;
}

static lv_obj_t *add_slider(lv_obj_t *parent, const char *label, int min, int max, int val)
{
    lv_obj_t *r = row(parent, label);
    lv_obj_t *sl = lv_slider_create(r);
    lv_obj_set_width(sl, 180);
    lv_slider_set_range(sl, min, max);
    lv_slider_set_value(sl, val, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(sl, NRC_GOLD, LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(sl, NRC_GOLD, LV_PART_KNOB);
    return sl;
}

static lv_obj_t *time_roller(lv_obj_t *parent, const char *opts)
{
    lv_obj_t *rol = lv_roller_create(parent);
    lv_roller_set_options(rol, opts, LV_ROLLER_MODE_NORMAL);
    lv_roller_set_visible_row_count(rol, 2);
    lv_obj_set_width(rol, 62);
    lv_obj_set_style_bg_color(rol, NRC_CARD2, 0);
    lv_obj_set_style_border_width(rol, 0, 0);
    lv_obj_set_style_text_color(rol, NRC_TX, 0);
    lv_obj_set_style_bg_color(rol, NRC_GOLD, LV_PART_SELECTED);
    lv_obj_set_style_text_color(rol, NRC_BG, LV_PART_SELECTED);
    return rol;
}

// ---- events ----------------------------------------------------------------

static void ta_focus_cb(lv_event_t *e)
{
    lv_obj_t *ta = lv_event_get_target(e);
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_FOCUSED) {
        lv_keyboard_set_textarea(s_kb, ta);
        lv_obj_remove_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(s_kb);
    } else if (code == LV_EVENT_DEFOCUSED || code == LV_EVENT_READY || code == LV_EVENT_CANCEL) {
        lv_obj_add_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
        lv_keyboard_set_textarea(s_kb, NULL);
    }
}

static lv_obj_t *field(lv_obj_t *parent, const char *label, const char *placeholder, bool password)
{
    lv_obj_t *box = row(parent, "");
    lv_obj_set_flex_flow(box, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(box, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_t *l = lv_label_create(box);
    lv_obj_set_style_text_color(l, NRC_TX2, 0);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_14, 0);
    lv_label_set_text(l, label);
    lv_obj_t *ta = lv_textarea_create(box);
    lv_textarea_set_one_line(ta, true);
    lv_obj_set_width(ta, lv_pct(100));
    if (placeholder) lv_textarea_set_placeholder_text(ta, placeholder);
    if (password) lv_textarea_set_password_mode(ta, true);
    lv_obj_add_event_cb(ta, ta_focus_cb, LV_EVENT_ALL, NULL);
    return ta;
}

// Rebuild the SSID dropdown from the latest scan (runs on the LVGL task).
static void apply_scan(void *unused)
{
    (void) unused;
    if (!dd_ssid) return;
    nr_config_t c; nr_config_get(&c);
    char opts[20 * 34 + 64];
    opts[0] = '\0';
    int sel = 0, idx = 0;
    bool current_listed = false;
    for (int i = 0; i < s_scan_n; i++) if (strcmp(s_scan[i], c.wifi_ssid) == 0) current_listed = true;
    if (c.wifi_ssid[0] && !current_listed) { strcat(opts, c.wifi_ssid); idx = 1; }
    for (int i = 0; i < s_scan_n; i++) {
        if (opts[0]) strcat(opts, "\n");
        if (strcmp(s_scan[i], c.wifi_ssid) == 0) sel = idx;
        strcat(opts, s_scan[i]);
        idx++;
    }
    if (opts[0] == '\0') strcpy(opts, "(keine Netzwerke gefunden)");
    lv_dropdown_set_options(dd_ssid, opts);
    lv_dropdown_set_selected(dd_ssid, sel);
}

static void scan_task(void *arg)
{
    (void) arg;
    s_scan_n = nr_wifi_scan(s_scan, 20);
    // Touch LVGL only under its lock (this runs off the LVGL task).
    if (nr_board_lock(2000)) { apply_scan(NULL); nr_board_unlock(); }
    s_scanning = false;
    vTaskDelete(NULL);
}

// Kick a background scan (guarded against overlapping scans).
static void start_scan(void)
{
    if (s_scanning) return;
    s_scanning = true;
    lv_dropdown_set_options(dd_ssid, "Suche …");
    if (xTaskCreate(scan_task, "wifi_scan", 4096, NULL, 4, NULL) != pdPASS) s_scanning = false;
}

static void scan_btn_cb(lv_event_t *e) { (void) e; start_scan(); }

static void load_values(void)
{
    nr_config_t c; nr_config_get(&c);
    lv_textarea_set_text(ta_url, c.backend_url);
    lv_textarea_set_text(ta_key, c.api_key);
    lv_textarea_set_text(ta_pass, "");
    lv_textarea_set_text(ta_city, c.city);
    if (c.tls_insecure) lv_obj_add_state(sw_tls, LV_STATE_CHECKED); else lv_obj_remove_state(sw_tls, LV_STATE_CHECKED);
    if (c.location_auto) lv_obj_add_state(sw_loc_auto, LV_STATE_CHECKED); else lv_obj_remove_state(sw_loc_auto, LV_STATE_CHECKED);
    if (c.clock_24h) lv_obj_add_state(sw_24h, LV_STATE_CHECKED); else lv_obj_remove_state(sw_24h, LV_STATE_CHECKED);
    if (!c.units_metric) lv_obj_add_state(sw_units, LV_STATE_CHECKED); else lv_obj_remove_state(sw_units, LV_STATE_CHECKED);
    if (c.night_enabled) lv_obj_add_state(sw_night, LV_STATE_CHECKED); else lv_obj_remove_state(sw_night, LV_STATE_CHECKED);
    if (c.night_mode == NR_NIGHT_OFF) lv_obj_add_state(sw_night_off, LV_STATE_CHECKED); else lv_obj_remove_state(sw_night_off, LV_STATE_CHECKED);
    lv_slider_set_value(sl_bri_day, c.brightness_day, LV_ANIM_OFF);
    lv_slider_set_value(sl_bri_night, c.brightness_night, LV_ANIM_OFF);
    lv_roller_set_selected(rol_sh, c.night_start_min / 60, LV_ANIM_OFF);
    lv_roller_set_selected(rol_sm, (c.night_start_min % 60) / 5, LV_ANIM_OFF);
    lv_roller_set_selected(rol_eh, c.night_end_min / 60, LV_ANIM_OFF);
    lv_roller_set_selected(rol_em, (c.night_end_min % 60) / 5, LV_ANIM_OFF);
    // Show whatever we last found, then refresh in the background.
    apply_scan(NULL);
    start_scan();
}

static void save_cb(lv_event_t *e)
{
    (void) e;
    nr_config_t c; nr_config_get(&c);

    char ssid[33] = {0};
    lv_dropdown_get_selected_str(dd_ssid, ssid, sizeof(ssid));
    bool ssid_valid = ssid[0] && ssid[0] != '(' && strcmp(ssid, "Suche …") != 0;
    bool ssid_changed = ssid_valid && strcmp(ssid, c.wifi_ssid) != 0;
    if (ssid_valid) nr_strlcpy(c.wifi_ssid, ssid, sizeof(c.wifi_ssid));

    const char *pass = lv_textarea_get_text(ta_pass);
    // Empty password: keep the old one for the same network; clear it (open
    // network) only when the network changed.
    if (pass[0]) nr_strlcpy(c.wifi_pass, pass, sizeof(c.wifi_pass));
    else if (ssid_changed) c.wifi_pass[0] = '\0';

    nr_strlcpy(c.backend_url, lv_textarea_get_text(ta_url), sizeof(c.backend_url));
    nr_strlcpy(c.api_key, lv_textarea_get_text(ta_key), sizeof(c.api_key));
    nr_strlcpy(c.city, lv_textarea_get_text(ta_city), sizeof(c.city));
    c.tls_insecure = lv_obj_has_state(sw_tls, LV_STATE_CHECKED);
    c.location_auto = lv_obj_has_state(sw_loc_auto, LV_STATE_CHECKED);
    c.clock_24h = lv_obj_has_state(sw_24h, LV_STATE_CHECKED);
    c.units_metric = !lv_obj_has_state(sw_units, LV_STATE_CHECKED);
    c.night_enabled = lv_obj_has_state(sw_night, LV_STATE_CHECKED);
    c.night_mode = lv_obj_has_state(sw_night_off, LV_STATE_CHECKED) ? NR_NIGHT_OFF : NR_NIGHT_DIM;
    c.brightness_day = lv_slider_get_value(sl_bri_day);
    c.brightness_night = lv_slider_get_value(sl_bri_night);
    c.night_start_min = lv_roller_get_selected(rol_sh) * 60 + lv_roller_get_selected(rol_sm) * 5;
    c.night_end_min = lv_roller_get_selected(rol_eh) * 60 + lv_roller_get_selected(rol_em) * 5;
    c.provisioned = c.wifi_ssid[0] && c.backend_url[0] && c.api_key[0];

    nr_config_set(&c);
    nr_wifi_reconfigure();       // apply Wi-Fi credentials and connect
    nr_weather_refresh_now();
    nr_ui_show_dashboard();
}

static void city_search_cb(lv_event_t *e)
{
    (void) e;
    const char *city = lv_textarea_get_text(ta_city);
    if (city && city[0]) { nr_geo_from_city(city); nr_weather_refresh_now(); }
}

static void reconnect_cb(lv_event_t *e) { (void) e; nr_wifi_reconfigure(); }
static void restart_cb(lv_event_t *e) { (void) e; esp_restart(); }
static void back_cb(lv_event_t *e) { (void) e; nr_ui_show_dashboard(); }
static void on_show(lv_event_t *e) { (void) e; load_values(); }

static lv_obj_t *action_button(lv_obj_t *parent, const char *text, lv_color_t bg, lv_color_t fg, lv_event_cb_t cb)
{
    lv_obj_t *b = lv_button_create(parent);
    lv_obj_set_width(b, lv_pct(100));
    lv_obj_set_style_bg_color(b, bg, 0);
    lv_obj_set_style_radius(b, NRC_R_INPUT, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_color(l, fg, 0);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

// ---- create ----------------------------------------------------------------

lv_obj_t *ui_settings_create(void)
{
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, NRC_BG, 0);
    lv_obj_set_flex_flow(s_scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(s_scr, 16, 0);
    lv_obj_set_style_pad_row(s_scr, 8, 0);
    lv_obj_set_scroll_dir(s_scr, LV_DIR_VER);
    lv_obj_add_event_cb(s_scr, on_show, LV_EVENT_SCREEN_LOAD_START, NULL);

    // Header
    lv_obj_t *head = row(s_scr, "");
    lv_obj_t *back = lv_button_create(head);
    lv_obj_set_size(back, 44, 44);
    lv_obj_set_style_bg_color(back, NRC_CARD, 0);
    lv_obj_set_style_radius(back, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_shadow_width(back, 0, 0);
    lv_obj_add_event_cb(back, back_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *bi = lv_label_create(back);
    lv_label_set_text(bi, LV_SYMBOL_LEFT);
    lv_obj_set_style_text_color(bi, NRC_TX, 0);
    lv_obj_center(bi);
    lv_obj_t *title = lv_label_create(head);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(title, NRC_TX, 0);
    lv_label_set_text(title, "Einstellungen");

    // --- Wi-Fi (all on-device) ---
    lv_obj_t *sec = section(s_scr, "WLAN");
    lv_obj_t *wrow = row(sec, "");
    lv_obj_set_flex_flow(wrow, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(wrow, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_t *wl = lv_label_create(wrow);
    lv_obj_set_style_text_color(wl, NRC_TX2, 0);
    lv_obj_set_style_text_font(wl, &lv_font_montserrat_14, 0);
    lv_label_set_text(wl, "Netzwerk");
    dd_ssid = lv_dropdown_create(wrow);
    lv_obj_set_width(dd_ssid, lv_pct(100));
    lv_dropdown_set_options(dd_ssid, "Suche …");
    lv_obj_set_style_bg_color(dd_ssid, NRC_CARD2, 0);
    lv_obj_set_style_border_color(dd_ssid, NRC_BORDER, 0);
    lv_obj_set_style_text_color(dd_ssid, NRC_TX, 0);
    action_button(sec, LV_SYMBOL_REFRESH "  Netzwerke suchen", NRC_CARD2, NRC_GOLD, scan_btn_cb);
    ta_pass = field(sec, "Passwort (leer lassen = unverändert)", "WLAN-Passwort", true);

    // --- Backend ---
    sec = section(s_scr, "BACKEND");
    ta_url = field(sec, "Backend-URL", "https://recall.example.com", false);
    ta_key = field(sec, "API-Key (Scope ingest:write)", "nrk_...", false);
    sw_tls = add_switch(sec, "TLS-Zertifikat nicht prüfen", false);

    // --- Location ---
    sec = section(s_scr, "STANDORT");
    sw_loc_auto = add_switch(sec, "Automatisch (per IP)", true);
    ta_city = field(sec, "Stadt", "z. B. Berlin", false);
    action_button(sec, LV_SYMBOL_GPS "  Stadt suchen", NRC_CARD2, NRC_GOLD, city_search_cb);

    // --- Display ---
    sec = section(s_scr, "ANZEIGE");
    sw_24h = add_switch(sec, "24-Stunden-Uhr", true);
    sw_units = add_switch(sec, "Fahrenheit statt Celsius", false);
    sl_bri_day = add_slider(sec, "Helligkeit Tag", 5, 100, 90);
    sl_bri_night = add_slider(sec, "Helligkeit Nacht", 0, 100, 12);

    // --- Night mode ---
    sec = section(s_scr, "NACHTMODUS");
    sw_night = add_switch(sec, "Nachtmodus aktiv", false);
    sw_night_off = add_switch(sec, "Display ganz aus (statt dimmen)", false);
    lv_obj_t *rstart = row(sec, "Beginn");
    rol_sh = time_roller(rstart, HOURS);
    rol_sm = time_roller(rstart, MINS5);
    lv_obj_t *rend = row(sec, "Ende");
    rol_eh = time_roller(rend, HOURS);
    rol_em = time_roller(rend, MINS5);

    // --- Actions ---
    sec = section(s_scr, "AKTIONEN");
    action_button(sec, LV_SYMBOL_SAVE "  Speichern & verbinden", NRC_GOLD, NRC_BG, save_cb);
    action_button(sec, LV_SYMBOL_WIFI "  Erneut verbinden", NRC_CARD2, NRC_TX, reconnect_cb);
    action_button(sec, LV_SYMBOL_REFRESH "  Neu starten", NRC_CARD2, NRC_TX2, restart_cb);

    // spacer so the last card clears the keyboard
    lv_obj_t *spacer = lv_obj_create(s_scr);
    lv_obj_set_size(spacer, lv_pct(100), 200);
    lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(spacer, 0, 0);

    // Keyboard (hidden until a text field is focused)
    s_kb = lv_keyboard_create(s_scr);
    lv_obj_add_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
    lv_keyboard_set_textarea(s_kb, NULL);

    load_values();
    return s_scr;
}
