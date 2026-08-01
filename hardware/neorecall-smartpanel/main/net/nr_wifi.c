// SPDX-License-Identifier: MIT
#include "nr_wifi.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_mac.h"

#include "config/nr_config.h"
#include "ingest/nr_ingest.h"
#include "net/nr_portal.h"
#include "util/nr_util.h"

static const char *TAG = "nr_wifi";

static esp_netif_t *s_sta_netif;
static esp_netif_t *s_ap_netif;
static bool s_ap_active;
static volatile nr_net_state_t s_state = NR_NET_BOOT;
static int s_backoff_ms = 1000;
static TimerHandle_t s_retry_timer;
static char s_ip[16] = "0.0.0.0";

static bool have_ssid(void)
{
    nr_config_t c; nr_config_get(&c);
    return c.wifi_ssid[0] != '\0';
}

static void set_state(nr_net_state_t st)
{
    if (s_state == st) return;
    s_state = st;
    esp_event_post(NR_EVENT, NR_EVT_WIFI_CHANGED, NULL, 0, 0);
}

static void retry_cb(TimerHandle_t t)
{
    (void) t;
    if (have_ssid()) esp_wifi_connect();
}

static void schedule_retry(void)
{
    if (!s_retry_timer || !have_ssid()) return;
    xTimerChangePeriod(s_retry_timer, pdMS_TO_TICKS(s_backoff_ms), 0);
    xTimerStart(s_retry_timer, 0);
    s_backoff_ms = s_backoff_ms < 30000 ? s_backoff_ms * 2 : 30000;
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void) arg; (void) base; (void) data;
    switch (id) {
        case WIFI_EVENT_STA_START:
            // Only auto-connect once credentials exist; otherwise stay idle but
            // started, so the settings app can still scan.
            if (have_ssid()) { esp_wifi_connect(); set_state(NR_NET_CONNECTING); }
            else set_state(NR_NET_OFFLINE);
            break;
        case WIFI_EVENT_STA_DISCONNECTED:
            nr_strlcpy(s_ip, "0.0.0.0", sizeof(s_ip));
            set_state(NR_NET_OFFLINE);
            schedule_retry();
            break;
        default: break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void) arg; (void) base;
    if (id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        esp_ip4addr_ntoa(&e->ip_info.ip, s_ip, sizeof(s_ip));
        s_backoff_ms = 1000;
        ESP_LOGI(TAG, "online: %s", s_ip);
        set_state(NR_NET_ONLINE);
        nr_ingest_kick();
        if (s_ap_active) nr_wifi_stop_ap();   // config succeeded: tear down the hotspot
    }
}

esp_err_t nr_wifi_init(void)
{
    NR_RETURN_ON_ERR(esp_netif_init());
    s_sta_netif = esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    NR_RETURN_ON_ERR(esp_wifi_init(&cfg));
    NR_RETURN_ON_ERR(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL, NULL));
    NR_RETURN_ON_ERR(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_ip_event, NULL, NULL));
    NR_RETURN_ON_ERR(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    NR_RETURN_ON_ERR(esp_wifi_set_mode(WIFI_MODE_STA));

    // Apply any stored credentials before starting so STA_START can connect.
    nr_config_t c; nr_config_get(&c);
    if (c.wifi_ssid[0]) {
        wifi_config_t wc = {0};
        nr_strlcpy((char *) wc.sta.ssid, c.wifi_ssid, sizeof(wc.sta.ssid));
        nr_strlcpy((char *) wc.sta.password, c.wifi_pass, sizeof(wc.sta.password));
        wc.sta.threshold.authmode = c.wifi_pass[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
        wc.sta.pmf_cfg.capable = true;
        esp_wifi_set_config(WIFI_IF_STA, &wc);
    }

    esp_wifi_set_ps(WIFI_PS_NONE);       // strong, stable link for a 24/7 device
    NR_RETURN_ON_ERR(esp_wifi_start());  // start now so scanning works pre-setup

    s_retry_timer = xTimerCreate("wifi_retry", pdMS_TO_TICKS(1000), pdFALSE, NULL, retry_cb);
    return ESP_OK;
}

esp_err_t nr_wifi_connect(void)
{
    if (!have_ssid()) { ESP_LOGW(TAG, "no SSID configured yet"); return ESP_ERR_INVALID_STATE; }
    nr_wifi_reconfigure();
    return ESP_OK;
}

void nr_wifi_reconfigure(void)
{
    nr_config_t c; nr_config_get(&c);
    wifi_config_t wc = {0};
    nr_strlcpy((char *) wc.sta.ssid, c.wifi_ssid, sizeof(wc.sta.ssid));
    nr_strlcpy((char *) wc.sta.password, c.wifi_pass, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = c.wifi_pass[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    wc.sta.pmf_cfg.capable = true;
    esp_wifi_set_config(WIFI_IF_STA, &wc);
    s_backoff_ms = 1000;
    if (c.wifi_ssid[0]) {
        ESP_LOGI(TAG, "connecting to \"%s\"", c.wifi_ssid);
        esp_wifi_disconnect();
        esp_wifi_connect();
        set_state(NR_NET_CONNECTING);
    }
}

int nr_wifi_scan(char (*out)[33], int max)
{
    if (max <= 0) return 0;
    wifi_scan_config_t sc = { .show_hidden = false };
    if (esp_wifi_scan_start(&sc, true) != ESP_OK) return 0;
    uint16_t num = 0;
    esp_wifi_scan_get_ap_num(&num);
    if (num == 0) return 0;
    wifi_ap_record_t *recs = calloc(num, sizeof(*recs));
    if (!recs) return 0;
    esp_wifi_scan_get_ap_records(&num, recs);

    int count = 0;
    for (uint16_t i = 0; i < num && count < max; i++) {
        const char *ssid = (const char *) recs[i].ssid;
        if (ssid[0] == '\0') continue;
        bool dup = false;
        for (int k = 0; k < count; k++) if (strcmp(out[k], ssid) == 0) { dup = true; break; }
        if (dup) continue;
        nr_strlcpy(out[count], ssid, 33);
        count++;
    }
    free(recs);
    ESP_LOGI(TAG, "scan found %d networks", count);
    return count;
}

nr_net_state_t nr_net_state(void) { return s_state; }
bool nr_net_is_online(void) { return s_state == NR_NET_ONLINE; }

bool nr_wifi_ip(char out[16])
{
    nr_strlcpy(out, s_ip, 16);
    return s_state == NR_NET_ONLINE;
}

// ---- optional config hotspot + captive portal ------------------------------

void nr_wifi_ap_ssid(char out[33])
{
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    snprintf(out, 33, "NeoRecall-Panel-%02X%02X", mac[4], mac[5]);
}

esp_err_t nr_wifi_start_ap(void)
{
    if (s_ap_active) return ESP_OK;
    if (!s_ap_netif) s_ap_netif = esp_netif_create_default_wifi_ap();

    char ssid[33];
    nr_wifi_ap_ssid(ssid);
    wifi_config_t ap = {0};
    nr_strlcpy((char *) ap.ap.ssid, ssid, sizeof(ap.ap.ssid));
    ap.ap.ssid_len = strlen(ssid);
    ap.ap.channel = 1;
    ap.ap.max_connection = 4;
    ap.ap.authmode = WIFI_AUTH_OPEN;   // open network -> one-tap join from a phone

    NR_RETURN_ON_ERR(esp_wifi_set_mode(WIFI_MODE_APSTA));
    NR_RETURN_ON_ERR(esp_wifi_set_config(WIFI_IF_AP, &ap));
    // The station may have been configured; keep it trying in the background.
    if (have_ssid()) esp_wifi_connect();

    s_ap_active = true;
    nr_portal_start();
    esp_event_post(NR_EVENT, NR_EVT_WIFI_CHANGED, NULL, 0, 0);   // UI shows the portal banner
    ESP_LOGI(TAG, "config hotspot up: %s (open) -> http://192.168.4.1", ssid);
    return ESP_OK;
}

void nr_wifi_stop_ap(void)
{
    if (!s_ap_active) return;
    nr_portal_stop();
    s_ap_active = false;
    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_event_post(NR_EVENT, NR_EVT_WIFI_CHANGED, NULL, 0, 0);
    ESP_LOGI(TAG, "config hotspot down");
}

bool nr_wifi_ap_active(void) { return s_ap_active; }
