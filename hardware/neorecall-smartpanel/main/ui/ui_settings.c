// SPDX-License-Identifier: MIT
// The on-device settings screen. All fields are generated from the shared
// NR_SETTINGS schema (see settings/nr_settings.h) — the exact same definition
// the Wi-Fi captive portal uses — so the two never drift and there is no
// duplicated field list.
#include "ui/ui_settings.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "lvgl.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "ui/ui_theme.h"
#include "ui/nr_fonts.h"
#include "ui/nr_ui.h"
#include "board/nr_board.h"
#include "config/nr_config.h"
#include "settings/nr_settings.h"
#include "net/nr_wifi.h"
#include "services/nr_geo.h"
#include "services/nr_weather.h"
#include "ingest/nr_recorder.h"
#include "util/nr_util.h"

#define MAX_FIELDS 48

static lv_obj_t *s_scr, *s_kb;
static lv_obj_t *s_w[MAX_FIELDS];    // primary widget per schema field
static lv_obj_t *s_w2[MAX_FIELDS];   // secondary widget (minute roller for TIME)
static lv_obj_t *s_dd_ssid;          // the SSID dropdown (for scan population)
static lv_obj_t *s_ta_city;          // the city text field (for geocode search)

static char s_scan[20][33];
static int s_scan_n;
static volatile bool s_scanning;
static char s_city_query[96];
static volatile bool s_city_busy;

static const char *HOURS = "00\n01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23";
static const char *MINS5 = "00\n05\n10\n15\n20\n25\n30\n35\n40\n45\n50\n55";

// ---- widget builders -------------------------------------------------------

static lv_obj_t *section(lv_obj_t *parent, const char *title)
{
    lv_obj_t *hdr = lv_label_create(parent);
    lv_obj_set_style_text_font(hdr, &nr_font_14, 0);
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
        lv_obj_set_style_text_font(l, &nr_font_16, 0);
        lv_obj_set_style_text_color(l, NRC_TX, 0);
        lv_label_set_text(l, label);
    }
    return r;
}

static void ta_focus_cb(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    if (code != LV_EVENT_FOCUSED && code != LV_EVENT_CLICKED) return;
    lv_obj_t *ta = lv_event_get_target(e);
    lv_keyboard_set_textarea(s_kb, ta);
    lv_obj_remove_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(s_kb);
    lv_obj_scroll_to_view_recursive(ta, LV_ANIM_ON);
}
static void kb_cb(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_READY || code == LV_EVENT_CANCEL) {
        lv_obj_add_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
        lv_keyboard_set_textarea(s_kb, NULL);
    }
}

static lv_obj_t *make_textarea(lv_obj_t *card, const char *label, const char *hint)
{
    lv_obj_t *box = row(card, "");
    lv_obj_set_flex_flow(box, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(box, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_t *l = lv_label_create(box);
    lv_obj_set_style_text_color(l, NRC_TX2, 0);
    lv_obj_set_style_text_font(l, &nr_font_14, 0);
    lv_label_set_text(l, label);
    lv_obj_t *ta = lv_textarea_create(box);
    lv_textarea_set_one_line(ta, true);
    lv_obj_set_width(ta, lv_pct(100));
    if (hint) lv_textarea_set_placeholder_text(ta, hint);
    lv_obj_add_event_cb(ta, ta_focus_cb, LV_EVENT_ALL, NULL);
    return ta;
}

static lv_obj_t *make_switch(lv_obj_t *card, const char *label)
{
    lv_obj_t *r = row(card, label);
    lv_obj_t *sw = lv_switch_create(r);
    lv_obj_set_style_bg_color(sw, NRC_GOLD, LV_PART_INDICATOR | LV_STATE_CHECKED);
    return sw;
}

static lv_obj_t *make_slider(lv_obj_t *card, const char *label, int min, int max)
{
    lv_obj_t *r = row(card, label);
    lv_obj_t *sl = lv_slider_create(r);
    lv_obj_set_width(sl, 180);
    lv_slider_set_range(sl, min, max);
    lv_obj_set_style_bg_color(sl, NRC_GOLD, LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(sl, NRC_GOLD, LV_PART_KNOB);
    return sl;
}

static lv_obj_t *make_roller(lv_obj_t *parent, const char *opts)
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
    lv_obj_set_style_text_font(l, &nr_font_16, 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

// ---- Wi-Fi scan (populates the SSID dropdown) ------------------------------

static void apply_scan(void *unused)
{
    (void) unused;
    if (!s_dd_ssid) return;
    nr_config_t c; nr_config_get(&c);
    char opts[20 * 34 + 64];
    opts[0] = '\0';
    int sel = 0, idx = 0;
    bool listed = false;
    for (int i = 0; i < s_scan_n; i++) if (strcmp(s_scan[i], c.wifi_ssid) == 0) listed = true;
    if (c.wifi_ssid[0] && !listed) { strcat(opts, c.wifi_ssid); idx = 1; }
    for (int i = 0; i < s_scan_n; i++) {
        if (opts[0]) strcat(opts, "\n");
        if (strcmp(s_scan[i], c.wifi_ssid) == 0) sel = idx;
        strcat(opts, s_scan[i]);
        idx++;
    }
    if (opts[0] == '\0') strcpy(opts, "(keine Netzwerke gefunden)");
    lv_dropdown_set_options(s_dd_ssid, opts);
    lv_dropdown_set_selected(s_dd_ssid, sel);
}

static void scan_task(void *arg)
{
    (void) arg;
    s_scan_n = nr_wifi_scan(s_scan, 20);
    if (nr_board_lock(2000)) { apply_scan(NULL); nr_board_unlock(); }
    s_scanning = false;
    vTaskDelete(NULL);
}
static void start_scan(void)
{
    if (s_scanning || !s_dd_ssid) return;
    s_scanning = true;
    lv_dropdown_set_options(s_dd_ssid, "Suche …");
    if (xTaskCreate(scan_task, "wifi_scan", 4096, NULL, 4, NULL) != pdPASS) s_scanning = false;
}
static void scan_btn_cb(lv_event_t *e) { (void) e; start_scan(); }

// ---- city geocode (background; TLS must not run on the LVGL task) ----------

static void city_task(void *arg)
{
    (void) arg;
    nr_geo_from_city(s_city_query);
    nr_weather_refresh_now();
    s_city_busy = false;
    vTaskDelete(NULL);
}
static void city_search_cb(lv_event_t *e)
{
    (void) e;
    if (!s_ta_city || s_city_busy) return;
    const char *city = lv_textarea_get_text(s_ta_city);
    if (!city || !city[0]) return;
    nr_strlcpy(s_city_query, city, sizeof(s_city_query));
    s_city_busy = true;
    if (xTaskCreate(city_task, "nr_city", 8192, NULL, 4, NULL) != pdPASS) s_city_busy = false;
}

// ---- load / save (both drive off the schema) -------------------------------

static void load_values(void)
{
    nr_config_t c; nr_config_get(&c);
    char v[NR_CFG_URL_MAX];
    for (int i = 0; i < NR_SETTINGS_COUNT; i++) {
        const nrs_field_t *f = &NR_SETTINGS[i];
        lv_obj_t *w = s_w[i];
        if (!w) continue;
        nrs_get(&c, f, v, sizeof(v));
        switch (f->type) {
            case NRS_TEXT: case NRS_URL:
                lv_textarea_set_text(w, v); break;
            case NRS_PASSWORD:
                lv_textarea_set_text(w, ""); break;   // never echo stored secrets
            case NRS_SSID:
                apply_scan(NULL); break;              // dropdown filled by scan
            case NRS_BOOL: case NRS_BOOL_INV: case NRS_NIGHTMODE:
                if (v[0] == '1') lv_obj_add_state(w, LV_STATE_CHECKED); else lv_obj_remove_state(w, LV_STATE_CHECKED);
                break;
            case NRS_PCT:
                lv_slider_set_value(w, atoi(v), LV_ANIM_OFF); break;
            case NRS_TIME: {
                int h = 0, m = 0; sscanf(v, "%d:%d", &h, &m);
                lv_roller_set_selected(w, h, LV_ANIM_OFF);
                if (s_w2[i]) lv_roller_set_selected(s_w2[i], m / 5, LV_ANIM_OFF);
                break;
            }
            default: break;
        }
    }
    start_scan();
}

static void save_cb(lv_event_t *e)
{
    (void) e;
    nr_config_t c; nr_config_get(&c);
    char v[NR_CFG_URL_MAX];
    for (int i = 0; i < NR_SETTINGS_COUNT; i++) {
        const nrs_field_t *f = &NR_SETTINGS[i];
        lv_obj_t *w = s_w[i];
        if (!w) continue;
        switch (f->type) {
            case NRS_TEXT: case NRS_URL: case NRS_PASSWORD:
                nrs_set(&c, f, lv_textarea_get_text(w)); break;
            case NRS_SSID: {
                char ssid[33]; lv_dropdown_get_selected_str(w, ssid, sizeof(ssid));
                if (ssid[0] && ssid[0] != '(' && strcmp(ssid, "Suche …") != 0) nrs_set(&c, f, ssid);
                break;
            }
            case NRS_BOOL: case NRS_BOOL_INV: case NRS_NIGHTMODE:
                nrs_set(&c, f, lv_obj_has_state(w, LV_STATE_CHECKED) ? "1" : "0"); break;
            case NRS_PCT:
                snprintf(v, sizeof(v), "%d", (int) lv_slider_get_value(w)); nrs_set(&c, f, v); break;
            case NRS_TIME:
                snprintf(v, sizeof(v), "%02d:%02d", (int) lv_roller_get_selected(w),
                         (int) (s_w2[i] ? lv_roller_get_selected(s_w2[i]) * 5 : 0));
                nrs_set(&c, f, v); break;
            default: break;
        }
    }
    c.provisioned = c.wifi_ssid[0] && c.backend_url[0] && c.auth_user[0] && c.auth_pass[0];
    nr_config_set(&c);
    nr_wifi_reconfigure();
    nr_weather_refresh_now();
    nr_ui_show_dashboard();
}

static void reconnect_cb(lv_event_t *e) { (void) e; nr_wifi_reconfigure(); }
static void restart_cb(lv_event_t *e) { (void) e; esp_restart(); }
static void back_cb(lv_event_t *e) { (void) e; nr_ui_show_dashboard(); }
static void on_show(lv_event_t *e) { (void) e; load_values(); }

// Purge the whole pending-upload backlog after a confirmation.
static void discard_all_confirm_cb(lv_event_t *e)
{
    lv_obj_t *mb = lv_event_get_user_data(e);
    nr_recorder_discard_all();
    if (mb) lv_msgbox_close(mb);
}
static void discard_all_cb(lv_event_t *e)
{
    (void) e;
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, "Alle wartenden verwerfen?");
    lv_msgbox_add_text(mb, "Alle lokal gespeicherten, noch nicht hochgeladenen Aufnahmen werden gelöscht. Das lässt sich nicht rückgängig machen.");
    lv_obj_t *ok = lv_msgbox_add_footer_button(mb, "Alle löschen");
    lv_obj_set_style_bg_color(ok, NRC_DANGER, 0);
    lv_obj_add_event_cb(ok, discard_all_confirm_cb, LV_EVENT_CLICKED, mb);
    lv_msgbox_add_close_button(mb);
}

// Start the config hotspot and show the SSID + URL to enter from a phone.
static void open_ap_cb(lv_event_t *e)
{
    (void) e;
    nr_wifi_start_ap();
    char ssid[33]; nr_wifi_ap_ssid(ssid);
    char msg[128];
    snprintf(msg, sizeof(msg), "Verbinde dein Handy mit dem WLAN\n\n%s\n\nund öffne http://192.168.4.1", ssid);
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, "Einrichtung per Handy");
    lv_msgbox_add_text(mb, msg);
    lv_msgbox_add_close_button(mb);
}

// ---- build -----------------------------------------------------------------

lv_obj_t *ui_settings_create(void)
{
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, NRC_BG, 0);
    // Inherit a Latin-1 font so textareas/dropdown/keyboard render umlauts
    // (widgets that don't set their own font would fall back to ASCII-only).
    lv_obj_set_style_text_font(s_scr, &nr_font_16, 0);
    lv_obj_set_flex_flow(s_scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(s_scr, 16, 0);
    lv_obj_set_style_pad_row(s_scr, 8, 0);
    lv_obj_set_scroll_dir(s_scr, LV_DIR_VER);
    lv_obj_add_event_cb(s_scr, on_show, LV_EVENT_SCREEN_LOAD_START, NULL);

    // Header: back + title
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
    lv_obj_set_style_text_font(title, &nr_font_20, 0);
    lv_obj_set_style_text_color(title, NRC_TX, 0);
    lv_label_set_text(title, "Einstellungen");

    // Generate every field from the shared schema. The schema starts with a
    // section, which opens the first card.
    lv_obj_t *card = NULL;
    for (int i = 0; i < NR_SETTINGS_COUNT && i < MAX_FIELDS; i++) {
        const nrs_field_t *f = &NR_SETTINGS[i];
        s_w[i] = s_w2[i] = NULL;
        switch (f->type) {
            case NRS_SECTION:
                card = section(s_scr, f->label);
                break;
            case NRS_TEXT: case NRS_URL: case NRS_PASSWORD:
                s_w[i] = make_textarea(card, f->label, f->hint);
                if (strcmp(f->id, "city") == 0) {
                    s_ta_city = s_w[i];
                    action_button(card, LV_SYMBOL_GPS "  Stadt suchen", NRC_CARD2, NRC_GOLD, city_search_cb);
                }
                break;
            case NRS_SSID: {
                lv_obj_t *box = row(card, "");
                lv_obj_set_flex_flow(box, LV_FLEX_FLOW_COLUMN);
                lv_obj_set_flex_align(box, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
                lv_obj_t *l = lv_label_create(box);
                lv_obj_set_style_text_color(l, NRC_TX2, 0);
                lv_obj_set_style_text_font(l, &nr_font_14, 0);
                lv_label_set_text(l, f->label);
                s_dd_ssid = lv_dropdown_create(box);
                lv_obj_set_width(s_dd_ssid, lv_pct(100));
                lv_dropdown_set_options(s_dd_ssid, "Suche …");
                lv_obj_set_style_bg_color(s_dd_ssid, NRC_CARD2, 0);
                lv_obj_set_style_border_color(s_dd_ssid, NRC_BORDER, 0);
                lv_obj_set_style_text_color(s_dd_ssid, NRC_TX, 0);
                s_w[i] = s_dd_ssid;
                action_button(card, LV_SYMBOL_REFRESH "  Netzwerke suchen", NRC_CARD2, NRC_GOLD, scan_btn_cb);
                break;
            }
            case NRS_BOOL: case NRS_BOOL_INV: case NRS_NIGHTMODE:
                s_w[i] = make_switch(card, f->label);
                break;
            case NRS_PCT:
                s_w[i] = make_slider(card, f->label, f->min, f->max);
                break;
            case NRS_TIME: {
                lv_obj_t *r = row(card, f->label);
                s_w[i] = make_roller(r, HOURS);
                s_w2[i] = make_roller(r, MINS5);
                break;
            }
        }
    }

    // Actions
    card = section(s_scr, "AKTIONEN");
    action_button(card, LV_SYMBOL_SAVE "  Speichern & verbinden", NRC_GOLD, NRC_BG, save_cb);
    action_button(card, LV_SYMBOL_WIFI "  Einrichtung per Handy (Hotspot)", NRC_CARD2, NRC_GOLD_HI, open_ap_cb);
    action_button(card, LV_SYMBOL_WIFI "  Erneut verbinden", NRC_CARD2, NRC_TX, reconnect_cb);
    action_button(card, LV_SYMBOL_TRASH "  Wartende Aufnahmen verwerfen", NRC_CARD2, NRC_DANGER, discard_all_cb);
    action_button(card, LV_SYMBOL_REFRESH "  Neu starten", NRC_CARD2, NRC_TX2, restart_cb);

    // spacer so the last card clears the keyboard
    lv_obj_t *spacer = lv_obj_create(s_scr);
    lv_obj_set_size(spacer, lv_pct(100), 200);
    lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(spacer, 0, 0);

    // Floating keyboard (stays fixed at the bottom, not in the scroll flow)
    s_kb = lv_keyboard_create(s_scr);
    lv_obj_add_flag(s_kb, LV_OBJ_FLAG_FLOATING);
    lv_obj_set_size(s_kb, lv_pct(100), lv_pct(45));
    lv_obj_align(s_kb, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_add_flag(s_kb, LV_OBJ_FLAG_HIDDEN);
    lv_keyboard_set_textarea(s_kb, NULL);
    lv_obj_add_event_cb(s_kb, kb_cb, LV_EVENT_ALL, NULL);

    load_values();
    return s_scr;
}
