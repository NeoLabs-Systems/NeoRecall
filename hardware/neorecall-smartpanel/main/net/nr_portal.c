// SPDX-License-Identifier: MIT
#include "net/nr_portal.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_http_server.h"
#include "esp_wifi.h"
#include "lwip/sockets.h"

#include "config/nr_config.h"
#include "settings/nr_settings.h"
#include "net/nr_wifi.h"
#include "util/nr_util.h"

static const char *TAG = "nr_portal";
static httpd_handle_t s_httpd;
static TaskHandle_t s_dns_task;
static volatile bool s_dns_run;

// ---- HTML (styled to match the NeoRecall dark theme) -----------------------

static const char HEAD[] =
"<!doctype html><html><head><meta charset=utf-8>"
"<meta name=viewport content='width=device-width,initial-scale=1'>"
"<title>NeoRecall Panel</title><style>"
":root{--bg:#0E1511;--card:#171F1A;--gold:#E1B052;--rose:#D98AA6;--tx:#ECEFE5;--mut:#AEB7A6;--bd:#2a332c}"
"*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);"
"font-family:-apple-system,Segoe UI,Roboto,sans-serif;padding:22px;line-height:1.5}"
".w{max-width:480px;margin:0 auto}.logo{display:flex;align-items:center;gap:12px;margin-bottom:14px}"
".ring{width:32px;height:32px;border-radius:9px;background:#151922;position:relative}"
".ring:after{content:'';position:absolute;inset:6px;border:3px solid var(--gold);border-radius:50%}"
".ring:before{content:'';position:absolute;left:50%;top:50%;width:7px;height:7px;margin:-3px 0 0 -3px;"
"background:var(--rose);border-radius:50%;z-index:2}"
"h1{font-size:19px;margin:0;letter-spacing:-.4px}"
".sec{color:var(--gold);font-size:12px;font-weight:700;letter-spacing:1.2px;margin:20px 0 8px 4px}"
".card{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:14px;margin-bottom:6px}"
"label{display:block;font-size:12px;color:var(--mut);margin:12px 0 5px}"
"input[type=text],input[type=password],input[type=url],input[type=time]{width:100%;padding:12px;border-radius:11px;"
"border:1px solid var(--bd);background:#0f1713;color:var(--tx);font-size:15px}"
"input:focus{outline:none;border-color:var(--gold)}"
".row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:12px}"
".row label{margin:0}input[type=checkbox]{width:22px;height:22px;accent-color:var(--gold)}"
"input[type=range]{width:60%;accent-color:var(--gold)}.hint{font-size:11px;color:var(--mut);margin-top:4px}"
"button{width:100%;margin-top:20px;padding:15px;border:0;border-radius:12px;background:var(--gold);"
"color:#0E1511;font-size:15px;font-weight:700;cursor:pointer}"
"</style></head><body><div class=w>"
"<div class=logo><div class=ring></div><h1>NeoRecall Panel</h1></div>"
"<form method=POST action=/save>";

static const char TAIL[] =
"<button type=submit>Speichern &amp; verbinden</button></form>"
"<script>fetch('/scan').then(r=>r.json()).then(d=>{var l=document.getElementById('nets');"
"if(l)(d.networks||[]).forEach(function(n){if([].some.call(l.options,function(o){return o.value===n}))return;"
"var o=document.createElement('option');o.value=n;o.textContent=n;l.appendChild(o)})}).catch(function(){})</script>"
"</div></body></html>";

static const char DONE[] =
"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
"<body style='background:#0E1511;color:#ECEFE5;font-family:sans-serif;padding:40px;text-align:center'>"
"<h2 style='color:#84BA87'>&#10003; Gespeichert</h2><p>Die Einstellungen wurden übernommen. "
"Du kannst das Fenster schließen.</p></body>";

// Emit one field as HTML into the response stream.
static void emit_field(httpd_req_t *req, const nr_config_t *c, const nrs_field_t *f)
{
    char v[NR_CFG_URL_MAX];
    nrs_get(c, f, v, sizeof(v));
    char buf[NR_CFG_URL_MAX + 512];

    switch (f->type) {
        case NRS_SECTION:
            httpd_resp_sendstr_chunk(req, "</div><div class=sec>");
            httpd_resp_sendstr_chunk(req, f->label);
            httpd_resp_sendstr_chunk(req, "</div><div class=card>");
            break;
        case NRS_TEXT: case NRS_URL: case NRS_PASSWORD: {
            const char *itype = f->type == NRS_URL ? "url" : (f->type == NRS_PASSWORD ? "password" : "text");
            const char *val = f->type == NRS_PASSWORD ? "" : v;   // never prefill passwords
            snprintf(buf, sizeof(buf),
                "<label>%s</label><input type=%s name=%s value=\"%s\">%s%s%s",
                f->label, itype, f->id, val,
                f->hint ? "<div class=hint>" : "", f->hint ? f->hint : "", f->hint ? "</div>" : "");
            httpd_resp_sendstr_chunk(req, buf);
            break;
        }
        case NRS_SSID:
            // A real selector, populated with the scan results by the page script.
            snprintf(buf, sizeof(buf),
                "<label>%s</label><select name=%s id=nets>%s%s%s</select>",
                f->label, f->id,
                v[0] ? "<option selected>" : "", v[0] ? v : "", v[0] ? "</option>" : "");
            httpd_resp_sendstr_chunk(req, buf);
            break;
        case NRS_BOOL: case NRS_BOOL_INV: case NRS_NIGHTMODE:
            snprintf(buf, sizeof(buf),
                "<div class=row><label>%s</label><input type=checkbox name=%s value=1 %s></div>",
                f->label, f->id, v[0] == '1' ? "checked" : "");
            httpd_resp_sendstr_chunk(req, buf);
            break;
        case NRS_PCT:
            snprintf(buf, sizeof(buf),
                "<div class=row><label>%s</label><input type=range name=%s min=%u max=%u value=%s></div>",
                f->label, f->id, f->min, f->max, v);
            httpd_resp_sendstr_chunk(req, buf);
            break;
        case NRS_TIME:
            snprintf(buf, sizeof(buf),
                "<label>%s</label><input type=time name=%s value=\"%s\">", f->label, f->id, v);
            httpd_resp_sendstr_chunk(req, buf);
            break;
    }
}

static esp_err_t get_root(httpd_req_t *req)
{
    // OS captive-portal probes and the root all get the form; else redirect.
    if (!(strcmp(req->uri, "/") == 0 || strstr(req->uri, "hotspot") || strstr(req->uri, "generate_204") ||
          strstr(req->uri, "ncsi") || strstr(req->uri, "connectivity") || strstr(req->uri, "canonical"))) {
        httpd_resp_set_status(req, "302 Found");
        httpd_resp_set_hdr(req, "Location", "http://192.168.4.1/");
        return httpd_resp_send(req, NULL, 0);
    }
    nr_config_t c; nr_config_get(&c);
    httpd_resp_set_type(req, "text/html");
    httpd_resp_sendstr_chunk(req, HEAD);
    httpd_resp_sendstr_chunk(req, "<div class=card style='display:none'>");  // closed by the first section
    for (int i = 0; i < NR_SETTINGS_COUNT; i++) emit_field(req, &c, &NR_SETTINGS[i]);
    httpd_resp_sendstr_chunk(req, "</div>");
    httpd_resp_sendstr_chunk(req, TAIL);
    httpd_resp_sendstr_chunk(req, NULL);
    return ESP_OK;
}

static esp_err_t get_scan(httpd_req_t *req)
{
    uint16_t n = 0;
    wifi_scan_config_t sc = { .show_hidden = false };
    esp_wifi_scan_start(&sc, true);
    esp_wifi_scan_get_ap_num(&n);
    if (n > 20) n = 20;
    wifi_ap_record_t *recs = calloc(n ? n : 1, sizeof(*recs));
    uint16_t got = n;
    if (recs) esp_wifi_scan_get_ap_records(&got, recs);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr_chunk(req, "{\"networks\":[");
    int emitted = 0;
    for (uint16_t i = 0; i < got && recs; i++) {
        if (recs[i].ssid[0] == '\0') continue;
        char item[80];
        snprintf(item, sizeof(item), "%s\"%s\"", emitted++ ? "," : "", (char *) recs[i].ssid);
        httpd_resp_sendstr_chunk(req, item);
    }
    httpd_resp_sendstr_chunk(req, "]}");
    httpd_resp_sendstr_chunk(req, NULL);
    free(recs);
    return ESP_OK;
}

// ---- form parsing ----------------------------------------------------------

static int hexv(char x) { return (x >= '0' && x <= '9') ? x - '0' : (x >= 'a' && x <= 'f') ? x - 'a' + 10 : (x >= 'A' && x <= 'F') ? x - 'A' + 10 : -1; }

static void url_decode(char *s)
{
    char *o = s;
    for (char *p = s; *p; p++) {
        if (*p == '+') *o++ = ' ';
        else if (*p == '%' && hexv(p[1]) >= 0 && hexv(p[2]) >= 0) { *o++ = (char) (hexv(p[1]) * 16 + hexv(p[2])); p += 2; }
        else *o++ = *p;
    }
    *o = '\0';
}

static bool form_get(const char *body, const char *key, char *out, size_t n)
{
    size_t klen = strlen(key);
    for (const char *p = body; p && *p; ) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            const char *v = p + klen + 1;
            const char *end = strchr(v, '&');
            size_t len = end ? (size_t) (end - v) : strlen(v);
            if (len >= n) len = n - 1;
            memcpy(out, v, len); out[len] = '\0';
            url_decode(out);
            return true;
        }
        p = strchr(p, '&');
        if (p) p++;
    }
    if (n) out[0] = '\0';
    return false;
}

static esp_err_t post_save(httpd_req_t *req)
{
    int len = req->content_len;
    if (len <= 0 || len > 4096) { httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body"); return ESP_FAIL; }
    char *body = malloc(len + 1);
    if (!body) return ESP_FAIL;
    int r = httpd_req_recv(req, body, len);
    if (r <= 0) { free(body); return ESP_FAIL; }
    body[r] = '\0';

    nr_config_t c; nr_config_get(&c);
    char val[NR_CFG_URL_MAX];
    for (int i = 0; i < NR_SETTINGS_COUNT; i++) {
        const nrs_field_t *f = &NR_SETTINGS[i];
        if (f->type == NRS_SECTION) continue;
        bool found = form_get(body, f->id, val, sizeof(val));
        // Unchecked checkboxes are simply absent -> treat as off.
        if (f->type == NRS_BOOL || f->type == NRS_BOOL_INV || f->type == NRS_NIGHTMODE)
            nrs_set(&c, f, found ? "1" : "0");
        else if (found)
            nrs_set(&c, f, val);
    }
    free(body);
    c.provisioned = c.wifi_ssid[0] && c.backend_url[0] &&
                    (c.api_key[0] || (c.auth_user[0] && c.auth_pass[0]));
    nr_config_set(&c);
    ESP_LOGI(TAG, "settings saved via portal (provisioned=%d)", c.provisioned);
    // Tell the device UI the phone setup is complete so it can leave the settings
    // screen and show the dashboard — otherwise the two views look out of sync.
    if (c.provisioned) esp_event_post(NR_EVENT, NR_EVT_PORTAL_SAVED, NULL, 0, 0);

    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, DONE, HTTPD_RESP_USE_STRLEN);
    vTaskDelay(pdMS_TO_TICKS(300));
    nr_wifi_reconfigure();
    return ESP_OK;
}

// ---- captive DNS -----------------------------------------------------------

static void dns_task(void *arg)
{
    (void) arg;
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) { vTaskDelete(NULL); return; }
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(sock, (struct sockaddr *) &addr, sizeof(addr)) < 0) { close(sock); vTaskDelete(NULL); return; }
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t buf[512];
    while (s_dns_run) {
        struct sockaddr_in from; socklen_t fl = sizeof(from);
        int n = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr *) &from, &fl);
        if (n < 12) continue;
        buf[2] |= 0x80;                 // QR = response
        buf[3] = (uint8_t) (buf[3] & 0x0F);
        buf[6] = 0; buf[7] = 1;         // ANCOUNT = 1
        buf[8] = 0; buf[9] = 0; buf[10] = 0; buf[11] = 0;
        int len = n;
        if (len + 16 > (int) sizeof(buf)) continue;
        uint8_t ans[] = { 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 192, 168, 4, 1 };
        memcpy(buf + len, ans, sizeof(ans));
        len += sizeof(ans);
        sendto(sock, buf, len, 0, (struct sockaddr *) &from, fl);
    }
    close(sock);
    vTaskDelete(NULL);
}

// ---- lifecycle -------------------------------------------------------------

esp_err_t nr_portal_start(void)
{
    if (s_httpd) return ESP_OK;
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    cfg.max_uri_handlers = 8;
    cfg.lru_purge_enable = true;
    cfg.stack_size = 8192;
    NR_RETURN_ON_ERR(httpd_start(&s_httpd, &cfg));

    httpd_uri_t save = { .uri = "/save", .method = HTTP_POST, .handler = post_save };
    httpd_uri_t scan = { .uri = "/scan", .method = HTTP_GET, .handler = get_scan };
    httpd_uri_t any = { .uri = "/*", .method = HTTP_GET, .handler = get_root };
    httpd_register_uri_handler(s_httpd, &save);
    httpd_register_uri_handler(s_httpd, &scan);
    httpd_register_uri_handler(s_httpd, &any);

    s_dns_run = true;
    xTaskCreate(dns_task, "nr_dns", 3072, NULL, 4, &s_dns_task);
    return ESP_OK;
}

void nr_portal_stop(void)
{
    s_dns_run = false;
    if (s_httpd) { httpd_stop(s_httpd); s_httpd = NULL; }
}
