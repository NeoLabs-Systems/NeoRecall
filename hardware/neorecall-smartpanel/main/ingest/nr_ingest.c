// SPDX-License-Identifier: MIT
#include "nr_ingest.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_random.h"
#include "cJSON.h"

#include "config/nr_config.h"
#include "net/nr_time.h"
#include "net/nr_http.h"
#include "net/nr_wifi.h"
#include "ingest/nr_spool.h"
#include "util/nr_util.h"

static const char *TAG = "nr_ingest";

// Stream-first policy: this board has no durable storage worth relying on.
// Chunks live briefly in PSRAM, upload ASAP, and are abandoned with an honest
// capture gap if they cannot reach the backend in time. Forever-"pending" is
// treated as a bug, not a backlog state.
//
// Idle cadence when the backlog is empty. While actively draining we re-arm
// almost immediately so capture cannot outrun the pump.
#define PUMP_IDLE_MS              4000
#define PUMP_DRAIN_MS             250
#define MAX_UPLOADS_CYCLE         6
#define MAX_POLL_IDS              80
#define REUPLOAD_LIMIT            2
#define TRANSIENT_FAIL_LIMIT      5    // short-lived retries, then give up
#define PERMANENT_FAIL_LIMIT      2    // permanent 4xx → give up quickly
#define SESSION_DECLARE_FAIL_LIMIT 6   // unsynced session → drop local audio
#define MAX_CHUNK_HOLD_MS         90000   // abandon unuploaded audio after 90 s
#define MAX_AWAIT_RECEIPT_MS      (30 * 60 * 1000)  // meta-only: drop after 30 min
#define BACKOFF_BASE_MS           1500
#define BACKOFF_MAX_MS            20000

static TaskHandle_t s_task;
static SemaphoreHandle_t s_kick;
static SemaphoreHandle_t s_status_lock;
static nr_ingest_status_t s_status;
static bool s_device_registered;
static bool s_meta_fetched;
static int64_t s_last_heartbeat_ms;
static bool s_drain_next;                 // last cycle made progress with remaining work
static int s_cycle_backoff_ms = PUMP_IDLE_MS;
static uint32_t s_abandoned_total;

// Snapshot of config used for a whole cycle so it cannot change mid-request.
typedef struct {
    char base[NR_CFG_URL_MAX];
    char api_key[NR_CFG_SECRET_MAX];
    char username[NR_CFG_STR_MAX];
    char password[NR_CFG_SECRET_MAX];
    char device_id[NR_UUID_LEN];
    char device_client[NR_UUID_LEN];
    char device_name[NR_CFG_STR_MAX];
    bool tls_insecure;
} cyc_cfg_t;

// Bearer used for every request this cycle: either the API key, or a session
// token obtained by logging in with username+password. Cleared on a 401 so the
// next cycle re-authenticates.
static char s_login_token[160];
static char s_bearer[200];

// ---- status helpers --------------------------------------------------------

static void status_set_error(const char *msg, int http)
{
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    nr_strlcpy(s_status.last_error, msg ? msg : "", sizeof(s_status.last_error));
    if (http) s_status.last_http_status = http;
    xSemaphoreGive(s_status_lock);
}

static void status_note_receipt(void)
{
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    s_status.last_receipt_epoch_ms = nr_time_epoch_ms();
    s_status.last_error[0] = '\0';
    xSemaphoreGive(s_status_lock);
}

static void status_note_http(int status)
{
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    s_status.server_reachable = true;
    s_status.last_http_status = status;
    xSemaphoreGive(s_status_lock);
}

void nr_ingest_get_status(nr_ingest_status_t *out)
{
    nr_spool_stats_t st; nr_spool_stats(&st);
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    *out = s_status;
    out->abandoned_total = s_abandoned_total;
    xSemaphoreGive(s_status_lock);
    out->pending_upload = st.pending_upload;
    out->awaiting_receipt = st.awaiting_receipt;
    out->needs_attention = st.needs_attention;
    out->backlog_bytes = st.bytes_used;
    out->backlog_ram_bytes = st.bytes_in_ram;
    out->device_registered = s_device_registered;
    out->provisioned = nr_config_is_provisioned();
}

// ---- URL + request helpers -------------------------------------------------

static void api_url(const cyc_cfg_t *cfg, char *out, size_t n, const char *path)
{
    snprintf(out, n, "%s/api/v1%s", cfg->base, path);
}

// POST/PATCH a JSON object; returns parsed response (caller frees) or NULL.
// Fills *status with the HTTP status. body_obj is consumed (deleted) here.
static cJSON *api_send(const cyc_cfg_t *cfg, const char *method, const char *path,
                       cJSON *body_obj, int *status)
{
    char url[256]; api_url(cfg, url, sizeof(url), path);
    char *body = body_obj ? cJSON_PrintUnformatted(body_obj) : NULL;
    if (body_obj) cJSON_Delete(body_obj);

    nr_http_result_t res;
    esp_err_t err = nr_http_request(method, url, body ? "application/json" : NULL,
                                    body, body ? strlen(body) : 0,
                                    s_bearer[0] ? s_bearer : NULL,
                                    NULL, 0, cfg->tls_insecure, 25000, &res);
    free(body);
    if (status) *status = res.status;
    if (err != ESP_OK) { status_set_error("network error", 0); return NULL; }
    if (res.status == 401) s_login_token[0] = '\0';   // token died: re-login next cycle

    status_note_http(res.status);

    cJSON *parsed = (res.body && res.body_len) ? cJSON_Parse(res.body) : NULL;
    if (res.status >= 400) {
        const char *code = NULL;
        if (parsed) {
            cJSON *e = cJSON_GetObjectItem(parsed, "error");
            if (e) { cJSON *cc = cJSON_GetObjectItem(e, "code"); if (cJSON_IsString(cc)) code = cc->valuestring; }
        }
        char msg[96]; snprintf(msg, sizeof(msg), "HTTP %d %s", res.status, code ? code : "");
        status_set_error(msg, res.status);
    }
    nr_http_result_free(&res);
    return parsed;
}

// ---- authentication --------------------------------------------------------

// Log in with username+password (unauthenticated) and cache the session token.
static bool do_login(const cyc_cfg_t *cfg)
{
    char url[256]; api_url(cfg, url, sizeof(url), "/auth/login");
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "account", cfg->username);
    cJSON_AddStringToObject(body, "password", cfg->password);
    char *bs = cJSON_PrintUnformatted(body);
    cJSON_Delete(body);

    nr_http_result_t res;
    esp_err_t err = nr_http_request("POST", url, "application/json", bs, strlen(bs),
                                    NULL, NULL, 0, cfg->tls_insecure, 20000, &res);
    free(bs);

    bool ok = false;
    if (err == ESP_OK && res.status == 200 && res.body) {
        cJSON *j = cJSON_Parse(res.body);
        cJSON *sess = j ? cJSON_GetObjectItem(j, "session") : NULL;
        cJSON *tok = sess ? cJSON_GetObjectItem(sess, "token") : NULL;
        if (cJSON_IsString(tok) && tok->valuestring[0]) {
            nr_strlcpy(s_login_token, tok->valuestring, sizeof(s_login_token));
            ok = true;
            ESP_LOGI(TAG, "logged in as %s", cfg->username);
        }
        if (j) cJSON_Delete(j);
    } else if (err == ESP_OK) {
        const char *msg = "Login fehlgeschlagen";
        if (res.status == 401) {
            // Distinguish 2FA from bad password when the body says so.
            if (res.body && strstr(res.body, "TWO_FACTOR"))
                msg = "Login: 2FA aktiv – bitte API-Key nutzen";
            else
                msg = "Login: falsche Zugangsdaten";
        }
        status_set_error(msg, res.status);
    } else {
        status_set_error("Login: Netzwerkfehler", 0);
    }
    nr_http_result_free(&res);
    return ok;
}

// Prefer a long-lived API key (device-friendly, works with 2FA accounts). Fall
// back to username+password session tokens for interactive setup.
static bool resolve_bearer(const cyc_cfg_t *cfg)
{
    if (cfg->api_key[0]) {
        nr_strlcpy(s_bearer, cfg->api_key, sizeof(s_bearer));
        return true;
    }
    if (!(cfg->username[0] && cfg->password[0])) { s_bearer[0] = '\0'; return false; }
    if (!s_login_token[0] && !do_login(cfg)) { s_bearer[0] = '\0'; return false; }
    nr_strlcpy(s_bearer, s_login_token, sizeof(s_bearer));
    return s_bearer[0] != '\0';
}

// ---- infrastructure: meta, device, heartbeat ------------------------------

static void ensure_meta(const cyc_cfg_t *cfg)
{
    if (s_meta_fetched) return;
    int status = 0;
    cJSON *j = api_send(cfg, "GET", "/meta", NULL, &status);
    if (j && status == 200) {
        cJSON *lim = cJSON_GetObjectItem(j, "limits");
        if (lim) {
            uint32_t tgt = 0, ovl = 0, mn = 0, mx = 0, up = 0;
            cJSON *v;
            v = cJSON_GetObjectItem(lim, "chunkTargetMs"); if (cJSON_IsNumber(v)) tgt = v->valueint;
            v = cJSON_GetObjectItem(lim, "chunkOverlapMs"); if (cJSON_IsNumber(v)) ovl = v->valueint;
            v = cJSON_GetObjectItem(lim, "chunkMinMs"); if (cJSON_IsNumber(v)) mn = v->valueint;
            v = cJSON_GetObjectItem(lim, "chunkMaxMs"); if (cJSON_IsNumber(v)) mx = v->valueint;
            v = cJSON_GetObjectItem(lim, "maxUploadBytes"); if (cJSON_IsNumber(v)) up = (uint32_t) v->valuedouble;
            nr_config_set_server_limits(tgt, ovl, mn, mx, up);
            ESP_LOGI(TAG, "server limits: target=%u overlap=%u min=%u max=%u", tgt, ovl, mn, mx);
        }
        s_meta_fetched = true;
    }
    if (j) cJSON_Delete(j);
}

static bool ensure_device(cyc_cfg_t *cfg)
{
    if (s_device_registered) return true;
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "id", cfg->device_id);
    cJSON_AddStringToObject(body, "clientUuid", cfg->device_client);
    cJSON_AddStringToObject(body, "name", cfg->device_name[0] ? cfg->device_name : "NeoRecall Panel");
    cJSON_AddStringToObject(body, "platform", "esp32-s3");
    cJSON_AddStringToObject(body, "kind", "wearable");
    cJSON *caps = cJSON_AddObjectToObject(body, "capabilities");
    cJSON_AddBoolToObject(caps, "microphone", true);
    cJSON_AddStringToObject(caps, "firmware", NR_FIRMWARE_VERSION);
    int status = 0;
    cJSON *j = api_send(cfg, "POST", "/devices", body, &status);
    if (status == 200 || status == 201) {
        // The server may return an existing device id for this clientUuid.
        // Session creates must use that id or every upload stays blocked.
        cJSON *id = j ? cJSON_GetObjectItem(j, "id") : NULL;
        if (cJSON_IsString(id) && id->valuestring[0] &&
            strcmp(id->valuestring, cfg->device_id) != 0) {
            nr_strlcpy(cfg->device_id, id->valuestring, sizeof(cfg->device_id));
            nr_config_set_device_id(id->valuestring);
            ESP_LOGW(TAG, "reconciled device_id to server value %.8s…", id->valuestring);
        }
        s_device_registered = true;
        if (j) cJSON_Delete(j);
        return true;
    }
    if (j) cJSON_Delete(j);
    return false;
}

static void heartbeat(const cyc_cfg_t *cfg)
{
    int64_t now = nr_time_monotonic_ms();
    if (s_last_heartbeat_ms && now - s_last_heartbeat_ms < 300000) return;  // every 5 min
    char path[96]; snprintf(path, sizeof(path), "/devices/%s/heartbeat", cfg->device_id);
    char iso[NR_ISO8601_LEN]; nr_time_now_iso(iso);
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "clientSentAt", iso);
    int status = 0;
    cJSON *j = api_send(cfg, "POST", path, body, &status);
    if (j) cJSON_Delete(j);
    if (status == 200) s_last_heartbeat_ms = now;
    else if (status == 404) {
        // Device vanished server-side (revoke / DB rebuild): re-register next cycle.
        s_device_registered = false;
        status_set_error("Gerät unbekannt – registriere neu", 404);
    }
}

// ---- abandon (stream give-up) ----------------------------------------------

// Drop a local chunk that cannot be delivered. Always record a sequence-covered
// gap so later chunks on the same session are not blocked by "missing"
// sequences once the session reaches the server. The gap sits locally until the
// session is declared, then syncs.
static void abandon_chunk(const nr_chunk_meta_t *cm, nr_gap_reason_t reason, const char *why)
{
    if (!cm) return;
    nr_session_rec_t sess;
    if (nr_spool_get_session(cm->session_id, &sess) || cm->session_id[0]) {
        nr_gap_rec_t g = {0};
        nr_uuid_v4(g.id);
        nr_strlcpy(g.session_id, cm->session_id, sizeof(g.session_id));
        nr_strlcpy(g.source_id, cm->source_id, sizeof(g.source_id));
        g.start_offset_ms = cm->monotonic_offset_ms;
        g.end_offset_ms = cm->monotonic_offset_ms + (cm->duration_ms ? cm->duration_ms : 1);
        if (g.end_offset_ms <= g.start_offset_ms) g.end_offset_ms = g.start_offset_ms + 1;
        g.start_sequence = (int32_t) cm->sequence;
        g.end_sequence = (int32_t) cm->sequence;
        g.reason = reason;
        nr_spool_put_gap(&g);
    }
    nr_spool_delete_chunk(cm->local_id);
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    s_abandoned_total++;
    xSemaphoreGive(s_status_lock);
    char msg[96];
    snprintf(msg, sizeof(msg), "Audio verworfen: %s", why ? why : "upload failed");
    status_set_error(msg, 0);
    ESP_LOGW(TAG, "abandoned chunk %.8s seq %u (%s)", cm->local_id, cm->sequence, why ? why : "?");
}

// ---- session sync ----------------------------------------------------------

static void declare_session(cyc_cfg_t *cfg, nr_session_rec_t *rec)
{
    char started[NR_ISO8601_LEN];
    nr_time_iso_from_epoch_ms(rec->start_epoch_ms, started);

    // Empty or exotic timezone names fail the server's IANA check and would
    // pin every chunk of the session as permanently pending. Fall back to UTC.
    const char *tz = (rec->timezone[0] && strchr(rec->timezone, '/')) ||
                     (rec->timezone[0] && strcmp(rec->timezone, "UTC") == 0)
                     ? rec->timezone : "UTC";
    if (strcmp(tz, rec->timezone) != 0) {
        nr_strlcpy(rec->timezone, tz, sizeof(rec->timezone));
        nr_spool_put_session(rec);
    }

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "id", rec->id);
    cJSON_AddStringToObject(body, "deviceId", cfg->device_id);
    cJSON_AddStringToObject(body, "clientUuid", rec->id);
    cJSON_AddStringToObject(body, "startedAt", started);
    cJSON_AddStringToObject(body, "timezone", tz);
    cJSON_AddStringToObject(body, "consentAttestedAt", started);
    cJSON *sources = cJSON_AddArrayToObject(body, "sources");
    cJSON *src = cJSON_CreateObject();
    cJSON_AddStringToObject(src, "id", rec->source_id);
    cJSON_AddStringToObject(src, "clientUuid", rec->source_id);
    cJSON_AddStringToObject(src, "kind", "microphone");
    cJSON_AddStringToObject(src, "channelLayout", "mono");
    cJSON_AddNumberToObject(src, "sampleRate", rec->sample_rate ? rec->sample_rate : 16000);
    cJSON_AddStringToObject(src, "sampleFormat", "pcm_s16le");
    cJSON *meta = cJSON_AddObjectToObject(src, "metadata");
    cJSON_AddNumberToObject(meta, "actualSampleRate", rec->sample_rate ? rec->sample_rate : 16000);
    cJSON_AddStringToObject(meta, "platform", "esp32-s3");
    cJSON_AddStringToObject(meta, "firmware", NR_FIRMWARE_VERSION);
    cJSON_AddItemToArray(sources, src);

    int status = 0;
    cJSON *j = api_send(cfg, "POST", "/ingest/sessions", body, &status);
    if (status == 200 || status == 201) {
        rec->synced = true;
        rec->declare_fail_count = 0;
        nr_spool_put_session(rec);
        ESP_LOGI(TAG, "session %.8s declared", rec->id);
        if (j) cJSON_Delete(j);
        return;
    }
    // Invalid timezone (or similar validation) must not pin the session forever.
    bool validation = (status == 400);
    if (j) {
        cJSON *e = cJSON_GetObjectItem(j, "error");
        cJSON *code = e ? cJSON_GetObjectItem(e, "code") : NULL;
        if (cJSON_IsString(code) && strstr(code->valuestring, "VALID")) validation = true;
        cJSON_Delete(j);
    }
    if (validation && strcmp(tz, "UTC") != 0) {
        ESP_LOGW(TAG, "session %.8s declare failed (%d); retrying with timezone=UTC", rec->id, status);
        nr_strlcpy(rec->timezone, "UTC", sizeof(rec->timezone));
        nr_spool_put_session(rec);
        // Rebuild and re-POST with UTC once (avoids infinite recursion via a flag).
        body = cJSON_CreateObject();
        cJSON_AddStringToObject(body, "id", rec->id);
        cJSON_AddStringToObject(body, "deviceId", cfg->device_id);
        cJSON_AddStringToObject(body, "clientUuid", rec->id);
        cJSON_AddStringToObject(body, "startedAt", started);
        cJSON_AddStringToObject(body, "timezone", "UTC");
        cJSON_AddStringToObject(body, "consentAttestedAt", started);
        sources = cJSON_AddArrayToObject(body, "sources");
        src = cJSON_CreateObject();
        cJSON_AddStringToObject(src, "id", rec->source_id);
        cJSON_AddStringToObject(src, "clientUuid", rec->source_id);
        cJSON_AddStringToObject(src, "kind", "microphone");
        cJSON_AddStringToObject(src, "channelLayout", "mono");
        cJSON_AddNumberToObject(src, "sampleRate", rec->sample_rate ? rec->sample_rate : 16000);
        cJSON_AddStringToObject(src, "sampleFormat", "pcm_s16le");
        meta = cJSON_AddObjectToObject(src, "metadata");
        cJSON_AddNumberToObject(meta, "actualSampleRate", rec->sample_rate ? rec->sample_rate : 16000);
        cJSON_AddStringToObject(meta, "platform", "esp32-s3");
        cJSON_AddStringToObject(meta, "firmware", NR_FIRMWARE_VERSION);
        cJSON_AddItemToArray(sources, src);
        status = 0;
        j = api_send(cfg, "POST", "/ingest/sessions", body, &status);
        if (j) cJSON_Delete(j);
        if (status == 200 || status == 201) {
            rec->synced = true;
            rec->declare_fail_count = 0;
            nr_spool_put_session(rec);
            ESP_LOGI(TAG, "session %.8s declared (UTC fallback)", rec->id);
            return;
        }
    }
    if (status == 404) {
        // Device missing: clear registration so ensure_device re-runs.
        s_device_registered = false;
        status_set_error("Session: Gerät fehlt – re-register", 404);
    }
    if (rec->declare_fail_count < 255) rec->declare_fail_count++;
    nr_spool_put_session(rec);
    ESP_LOGW(TAG, "session %.8s declare fail #%u (HTTP %d)", rec->id, rec->declare_fail_count, status);
}

static void close_session(const cyc_cfg_t *cfg, nr_session_rec_t *rec)
{
    char ended[NR_ISO8601_LEN];
    int64_t end_epoch = rec->start_epoch_ms;  // best available; refined below if clock valid
    if (nr_time_is_valid()) end_epoch = nr_time_epoch_ms();
    nr_time_iso_from_epoch_ms(end_epoch, ended);

    char path[96]; snprintf(path, sizeof(path), "/ingest/sessions/%s", rec->id);
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "endedAt", ended);
    cJSON_AddStringToObject(body, "status", rec->interrupted ? "interrupted" : "ended");
    if (rec->final_sequence >= 0) {
        cJSON *sources = cJSON_AddArrayToObject(body, "sources");
        cJSON *s = cJSON_CreateObject();
        cJSON_AddStringToObject(s, "id", rec->source_id);
        cJSON_AddNumberToObject(s, "finalSequence", rec->final_sequence);
        cJSON_AddItemToArray(sources, s);
    }
    int status = 0;
    cJSON *j = api_send(cfg, "PATCH", path, body, &status);
    if (j) cJSON_Delete(j);
    if (status == 200) {
        rec->close_synced = true;
        nr_spool_put_session(rec);
        ESP_LOGI(TAG, "session %.8s closed (%s, final=%d)", rec->id,
                 rec->interrupted ? "interrupted" : "ended", (int) rec->final_sequence);
    }
}

typedef struct { cyc_cfg_t *cfg; } sess_ctx_t;

static bool sync_session_cb(const nr_session_rec_t *rec_in, void *ctx)
{
    sess_ctx_t *c = ctx;
    nr_session_rec_t rec = *rec_in;

    // Back-compute the true wall-clock start once NTP (or HTTP Date) has landed.
    if (rec.start_epoch_ms == 0 && nr_time_is_valid()) {
        rec.start_epoch_ms = nr_time_epoch_ms() - (nr_time_monotonic_ms() - rec.start_monotonic_ms);
        if (rec.start_epoch_ms < 0) rec.start_epoch_ms = nr_time_epoch_ms();
        nr_spool_put_session(&rec);
    }
    if (rec.start_epoch_ms == 0) return true;  // cannot declare without a real start time yet

    if (!rec.synced) declare_session(c->cfg, &rec);
    if (rec.synced && rec.ended && !rec.close_synced) close_session(c->cfg, &rec);
    return true;
}

// ---- gap sync --------------------------------------------------------------

static bool sync_gap_cb(const nr_gap_rec_t *g, void *ctx)
{
    sess_ctx_t *c = ctx;
    if (g->synced) return true;
    nr_session_rec_t sess;
    if (!nr_spool_get_session(g->session_id, &sess) || !sess.synced) return true;

    char path[96]; snprintf(path, sizeof(path), "/ingest/sessions/%s/gaps", g->session_id);
    cJSON *body = cJSON_CreateObject();
    cJSON *arr = cJSON_AddArrayToObject(body, "gaps");
    cJSON *gj = cJSON_CreateObject();
    cJSON_AddStringToObject(gj, "id", g->id);
    cJSON_AddStringToObject(gj, "sourceId", g->source_id);
    cJSON_AddNumberToObject(gj, "startOffsetMs", (double) g->start_offset_ms);
    cJSON_AddNumberToObject(gj, "endOffsetMs", (double) g->end_offset_ms);
    if (g->start_sequence >= 0 && g->end_sequence >= 0) {
        cJSON_AddNumberToObject(gj, "startSequence", g->start_sequence);
        cJSON_AddNumberToObject(gj, "endSequence", g->end_sequence);
    }
    cJSON_AddStringToObject(gj, "reason", nr_gap_reason_str(g->reason));
    cJSON_AddItemToArray(arr, gj);

    int status = 0;
    cJSON *j = api_send(c->cfg, "POST", path, body, &status);
    if (j) cJSON_Delete(j);
    if (status == 204 || status == 200) {
        nr_spool_delete_gap(g->id);
        ESP_LOGI(TAG, "gap %.8s synced (%s)", g->id, nr_gap_reason_str(g->reason));
    }
    return true;
}

// ---- receipt acceptance ----------------------------------------------------

static void release_chunk(const cyc_cfg_t *cfg, const char *server_chunk_id)
{
    cJSON *body = cJSON_CreateObject();
    cJSON *arr = cJSON_AddArrayToObject(body, "chunkIds");
    cJSON_AddItemToArray(arr, cJSON_CreateString(server_chunk_id));
    int status = 0;
    cJSON *j = api_send(cfg, "POST", "/ingest/chunks/released", body, &status);
    if (j) cJSON_Delete(j);
}

// Apply a receipt object to the local chunk. Returns true if it became terminal.
static bool accept_receipt(const cyc_cfg_t *cfg, const char *local_id, const cJSON *receipt)
{
    nr_chunk_meta_t m;
    if (!nr_spool_get_chunk(local_id, &m)) return false;

    const cJSON *st = cJSON_GetObjectItem(receipt, "state");
    const char *state = cJSON_IsString(st) ? st->valuestring : "";
    const cJSON *cid = cJSON_GetObjectItem(receipt, "chunkId");
    if (cJSON_IsString(cid) && cid->valuestring[0])
        nr_strlcpy(m.server_chunk_id, cid->valuestring, sizeof(m.server_chunk_id));

    bool terminal = (!strcmp(state, "transcribed") || !strcmp(state, "silent"));
    bool proven = cJSON_GetObjectItem(receipt, "persistedAt") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "persistedAt")) &&
                  cJSON_GetObjectItem(receipt, "serverAudioDeletedAt") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "serverAudioDeletedAt")) &&
                  cJSON_GetObjectItem(receipt, "transcriptSha256") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "transcriptSha256"));

    if (terminal && proven) {
        m.state = NR_CHUNK_TERMINAL;
        m.fail_count = 0;
        m.next_attempt_mono_ms = 0;
        nr_spool_update_chunk(&m);
        if (m.server_chunk_id[0]) release_chunk(cfg, m.server_chunk_id);
        nr_spool_delete_chunk(local_id);      // reliability invariant satisfied
        status_note_receipt();
        ESP_LOGI(TAG, "chunk %.8s terminal (%s) — released", local_id, state);
        return true;
    }
    if (!strcmp(state, "reupload_required")) {
        m.reupload_attempts++;
        // No local payload left → cannot re-upload on this board; honest gap.
        if (!m.has_payload || m.reupload_attempts >= REUPLOAD_LIMIT) {
            abandon_chunk(&m, NR_GAP_CAPTURE_ERROR, "reupload not possible");
            return false;
        }
        m.fail_count = 0;
        m.next_attempt_mono_ms = 0;
        m.state = NR_CHUNK_READY;
        m.server_chunk_id[0] = '\0';
        nr_spool_update_chunk(&m);
        ESP_LOGW(TAG, "chunk %.8s reupload_required (attempt %u)", local_id, m.reupload_attempts);
        return false;
    }
    // uploaded / persisted_cleanup_pending / other non-terminal
    if (!m.server_chunk_id[0]) {
        // Receipt without a chunkId cannot be polled — re-upload next cycle if
        // we still hold the bytes; otherwise give up.
        if (!m.has_payload) {
            abandon_chunk(&m, NR_GAP_CAPTURE_ERROR, "upload receipt incomplete");
            return false;
        }
        m.state = NR_CHUNK_READY;
        m.next_attempt_mono_ms = 0;
        nr_spool_update_chunk(&m);
        return false;
    }
    bool first_upload = (m.state != NR_CHUNK_UPLOADED);
    m.state = NR_CHUNK_UPLOADED;
    m.fail_count = 0;
    m.next_attempt_mono_ms = 0;
    if (first_upload || m.uploaded_monotonic_ms == 0)
        m.uploaded_monotonic_ms = nr_time_monotonic_ms();
    nr_spool_update_chunk(&m);
    // Stream-first: free the WAV as soon as the server accepted it. Meta stays
    // for terminal-receipt polling. Power-loss already risked RAM-only audio.
    if (m.has_payload) nr_spool_release_payload(local_id);
    return false;
}

// ---- poll uploaded ---------------------------------------------------------

typedef struct {
    char server_ids[MAX_POLL_IDS][NR_UUID_LEN];
    char local_ids[MAX_POLL_IDS][NR_UUID_LEN];
    int count;
} poll_ctx_t;

static bool collect_uploaded_cb(const nr_chunk_meta_t *m, void *ctx)
{
    poll_ctx_t *p = ctx;
    if (m->state == NR_CHUNK_UPLOADED && m->server_chunk_id[0] && p->count < MAX_POLL_IDS) {
        nr_strlcpy(p->server_ids[p->count], m->server_chunk_id, NR_UUID_LEN);
        nr_strlcpy(p->local_ids[p->count], m->local_id, NR_UUID_LEN);
        p->count++;
    }
    return p->count < MAX_POLL_IDS;
}

// UPLOADED without a server id is unpollable — push back to READY so the pump
// re-PUTs (idempotent) and obtains a proper receipt.
static bool repair_orphan_uploaded_cb(const nr_chunk_meta_t *m, void *ctx)
{
    (void) ctx;
    if (m->state == NR_CHUNK_UPLOADED && !m->server_chunk_id[0]) {
        nr_chunk_meta_t fixed = *m;
        fixed.state = NR_CHUNK_READY;
        fixed.next_attempt_mono_ms = 0;
        nr_spool_update_chunk(&fixed);
        ESP_LOGW(TAG, "chunk %.8s was UPLOADED without server id — re-queued", m->local_id);
    }
    return true;
}

static int poll_uploaded(const cyc_cfg_t *cfg)
{
    nr_spool_for_each_chunk(repair_orphan_uploaded_cb, NULL);

    poll_ctx_t *p = calloc(1, sizeof(*p));
    if (!p) return 0;
    nr_spool_for_each_chunk(collect_uploaded_cb, p);
    if (p->count == 0) { free(p); return 0; }

    cJSON *body = cJSON_CreateObject();
    cJSON *arr = cJSON_AddArrayToObject(body, "chunkIds");
    for (int i = 0; i < p->count; i++) cJSON_AddItemToArray(arr, cJSON_CreateString(p->server_ids[i]));

    int status = 0;
    int released = 0;
    cJSON *j = api_send(cfg, "POST", "/ingest/chunks/status", body, &status);
    if (j && status == 200) {
        cJSON *receipts = cJSON_GetObjectItem(j, "receipts");
        cJSON *r;
        cJSON_ArrayForEach(r, receipts) {
            cJSON *cid = cJSON_GetObjectItem(r, "chunkId");
            if (!cJSON_IsString(cid)) continue;
            for (int i = 0; i < p->count; i++) {
                if (strcmp(p->server_ids[i], cid->valuestring) == 0) {
                    if (accept_receipt(cfg, p->local_ids[i], r)) released++;
                    break;
                }
            }
        }
    }
    if (j) cJSON_Delete(j);
    free(p);
    return released;
}

// ---- upload ready ----------------------------------------------------------

static uint32_t backoff_ms_for(uint8_t fail_count)
{
    if (fail_count == 0) return 0;
    // 2s, 4s, 8s, … capped, with a little jitter so multi-chunk bursts don't sync.
    uint32_t shift = fail_count > 6 ? 6 : fail_count;
    uint32_t base = BACKOFF_BASE_MS << (shift - 1);
    if (base > BACKOFF_MAX_MS) base = BACKOFF_MAX_MS;
    uint32_t jitter = esp_random() % (base / 4 + 1);
    return base + jitter;
}

static void schedule_retry(nr_chunk_meta_t *m, bool permanent)
{
    m->fail_count = (uint8_t) (m->fail_count < 255 ? m->fail_count + 1 : 255);
    uint8_t limit = permanent ? PERMANENT_FAIL_LIMIT : TRANSIENT_FAIL_LIMIT;
    if (m->fail_count >= limit) {
        // No durable store: give up instead of parking "pending" forever.
        abandon_chunk(m, permanent ? NR_GAP_CAPTURE_ERROR : NR_GAP_STORAGE_FULL,
                      permanent ? "upload rejected" : "upload retries exhausted");
        return;
    }
    m->state = NR_CHUNK_FAILED;
    m->next_attempt_mono_ms = nr_time_monotonic_ms() + backoff_ms_for(m->fail_count);
    nr_spool_update_chunk(m);
}

// Returns true when the server accepted the PUT (receipt path taken).
static bool upload_chunk(cyc_cfg_t *cfg, const nr_chunk_meta_t *cm)
{
    nr_session_rec_t sess;
    if (!nr_spool_get_session(cm->session_id, &sess) || !sess.synced || sess.start_epoch_ms == 0)
        return false;

    const uint8_t *mem = NULL; size_t len = 0; char path[192];
    if (!nr_spool_borrow_wav(cm->local_id, &mem, &len, path, sizeof(path))) {
        ESP_LOGW(TAG, "chunk %.8s missing WAV bytes — abandoning", cm->local_id);
        abandon_chunk(cm, NR_GAP_CAPTURE_ERROR, "audio bytes lost");
        return false;
    }

    char device_started[NR_ISO8601_LEN];
    nr_time_iso_from_epoch_ms(sess.start_epoch_ms + cm->monotonic_offset_ms, device_started);

    char s_dur[16], s_ovl[16], s_off[24], s_seq_url[16];
    snprintf(s_dur, sizeof(s_dur), "%u", cm->duration_ms);
    snprintf(s_ovl, sizeof(s_ovl), "%u", cm->overlap_ms);
    snprintf(s_off, sizeof(s_off), "%lld", (long long) cm->monotonic_offset_ms);
    snprintf(s_seq_url, sizeof(s_seq_url), "%u", cm->sequence);

    nr_http_header_t hdrs[] = {
        { "Idempotency-Key", cm->local_id },
        { "X-Chunk-Sha256", cm->sha256 },
        { "X-Chunk-Duration-Ms", s_dur },
        { "X-Chunk-Overlap-Ms", s_ovl },
        { "X-Channel-Layout", cm->channel_layout[0] ? cm->channel_layout : "mono" },
        { "X-Monotonic-Offset-Ms", s_off },
        { "X-Device-Started-At", device_started },
        { "X-Audio-Container", "wav" },
        { "X-Audio-Codec", "pcm_s16le" },
        { "X-Final-Chunk", cm->is_final ? "true" : "false" },
    };

    char url[256];
    snprintf(url, sizeof(url), "%s/api/v1/ingest/sessions/%s/sources/%s/chunks/%s",
             cfg->base, cm->session_id, cm->source_id, s_seq_url);
    char filename[NR_UUID_LEN + 5];
    snprintf(filename, sizeof(filename), "%s.wav", cm->local_id);

    // Mark uploading first so a crash mid-PUT recovers via idempotent retry.
    nr_chunk_meta_t m = *cm;
    m.state = NR_CHUNK_UPLOADING;
    nr_spool_update_chunk(&m);

    // Timeout scales with payload size inside nr_http_put_wav_multipart; pass 0
    // to take the auto budget (floor 60 s).
    nr_http_result_t res;
    esp_err_t err = nr_http_put_wav_multipart(url, s_bearer[0] ? s_bearer : NULL,
                                              hdrs, sizeof(hdrs) / sizeof(hdrs[0]),
                                              mem, mem ? NULL : path, len, filename,
                                              cfg->tls_insecure, 0, &res);
    if (err != ESP_OK) {
        if (nr_spool_get_chunk(cm->local_id, &m)) {
            schedule_retry(&m, false);
        }
        status_set_error("upload network error", 0);
        ESP_LOGW(TAG, "chunk %.8s seq %u transport fail", cm->local_id, cm->sequence);
        return false;
    }
    status_note_http(res.status);

    bool accepted = false;
    if (res.status == 401) {
        s_login_token[0] = '\0';   // token expired: re-login next cycle, then retry
        if (nr_spool_get_chunk(cm->local_id, &m)) {
            m.state = NR_CHUNK_READY;
            m.next_attempt_mono_ms = 0;
            nr_spool_update_chunk(&m);
        }
        status_set_error("Auth abgelehnt (Zugangsdaten prüfen)", 401);
    } else if (res.status >= 200 && res.status < 300 && res.body) {
        cJSON *j = cJSON_Parse(res.body);
        cJSON *receipt = j ? cJSON_GetObjectItem(j, "receipt") : NULL;
        if (receipt) {
            accept_receipt(cfg, cm->local_id, receipt);
            accepted = true;
            ESP_LOGI(TAG, "chunk %.8s seq %u uploaded (HTTP %d)", cm->local_id, cm->sequence, res.status);
        } else if (nr_spool_get_chunk(cm->local_id, &m)) {
            // 2xx without a receipt is unexpected; keep bytes and retry.
            schedule_retry(&m, false);
            status_set_error("upload: missing receipt", res.status);
        }
        if (j) cJSON_Delete(j);
    } else if (res.status == 404) {
        // Session/source gone or never declared: re-declare next cycle.
        if (nr_spool_get_session(cm->session_id, &sess)) {
            sess.synced = false;
            nr_spool_put_session(&sess);
        }
        if (nr_spool_get_chunk(cm->local_id, &m)) {
            m.state = NR_CHUNK_READY;
            m.next_attempt_mono_ms = nr_time_monotonic_ms() + 3000;
            nr_spool_update_chunk(&m);
        }
        status_set_error("upload HTTP 404 (session)", 404);
    } else if (res.status == 409 || res.status == 422 || res.status == 400) {
        // Permanent-ish validation / conflict: limited retries then park.
        if (nr_spool_get_chunk(cm->local_id, &m)) schedule_retry(&m, true);
        char msg[64]; snprintf(msg, sizeof(msg), "upload HTTP %d", res.status);
        status_set_error(msg, res.status);
        ESP_LOGW(TAG, "chunk %.8s seq %u permanent-ish HTTP %d", cm->local_id, cm->sequence, res.status);
    } else {
        // 408 / 429 / 5xx / other: transient.
        if (nr_spool_get_chunk(cm->local_id, &m)) schedule_retry(&m, false);
        char msg[64]; snprintf(msg, sizeof(msg), "upload HTTP %d", res.status);
        status_set_error(msg, res.status);
        ESP_LOGW(TAG, "chunk %.8s seq %u transient HTTP %d", cm->local_id, cm->sequence, res.status);
    }
    nr_http_result_free(&res);
    return accepted;
}

typedef struct {
    cyc_cfg_t *cfg;
    int attempted;
    int accepted;
    bool more;
    int64_t now_mono;
} up_ctx_t;

static bool upload_ready_cb(const nr_chunk_meta_t *m, void *ctx)
{
    up_ctx_t *u = ctx;
    bool wants = m->state == NR_CHUNK_READY || m->state == NR_CHUNK_FAILED ||
                 m->state == NR_CHUNK_UPLOADING;  // UPLOADING => crash-recovered
    if (!wants) return true;

    // Honour per-chunk exponential backoff so a flaky link doesn't thrash.
    if (m->next_attempt_mono_ms > 0 && m->next_attempt_mono_ms > u->now_mono)
        return true;

    // Only spend a cycle slot on chunks whose session is already declared.
    // Unsynced sessions used to burn the whole MAX_UPLOADS_CYCLE budget and
    // leave the panel "N wartend" forever while declare was still blocked.
    nr_session_rec_t sess;
    if (!nr_spool_get_session(m->session_id, &sess) || !sess.synced || sess.start_epoch_ms == 0)
        return true;

    if (u->attempted >= MAX_UPLOADS_CYCLE) { u->more = true; return false; }

    if (upload_chunk(u->cfg, m)) u->accepted++;
    u->attempted++;
    return true;
}

// ---- session cleanup + stale reclaim ---------------------------------------

typedef struct { const char *sid; bool found; } has_chunk_ctx_t;
static bool has_chunk_cb(const nr_chunk_meta_t *m, void *ctx)
{
    has_chunk_ctx_t *h = ctx;
    if (strcmp(m->session_id, h->sid) == 0) { h->found = true; return false; }
    return true;
}

static bool cleanup_session_cb(const nr_session_rec_t *rec, void *ctx)
{
    (void) ctx;
    if (rec->ended && rec->close_synced) {
        has_chunk_ctx_t h = { .sid = rec->id, .found = false };
        nr_spool_for_each_chunk(has_chunk_cb, &h);
        if (!h.found) { nr_spool_delete_session(rec->id); ESP_LOGI(TAG, "session %.8s retired", rec->id); }
    }
    return true;
}

typedef struct {
    int64_t now_mono;
    int abandoned;
} reclaim_ctx_t;

// Drop anything that has outlived the stream hold window so the UI never shows
// "N wartend" for hours. Session-declare failures are treated the same way:
// without a server session the audio cannot leave the device.
static bool reclaim_stale_cb(const nr_chunk_meta_t *m, void *ctx)
{
    reclaim_ctx_t *r = ctx;
    int64_t created = m->created_monotonic_ms > 0 ? m->created_monotonic_ms : r->now_mono;
    int64_t age = r->now_mono - created;
    if (age < 0) age = 0;

    if (m->state == NR_CHUNK_NEEDS_ATTENTION) {
        abandon_chunk(m, NR_GAP_CAPTURE_ERROR, "needs attention");
        r->abandoned++;
        return true;
    }

    if (m->state == NR_CHUNK_UPLOADED) {
        int64_t up = m->uploaded_monotonic_ms > 0 ? m->uploaded_monotonic_ms : created;
        if (r->now_mono - up > MAX_AWAIT_RECEIPT_MS) {
            // Server never produced a terminal receipt. Meta-only; free the slot.
            // We already released the WAV after upload, so this is bookkeeping.
            if (m->server_chunk_id[0]) {
                // Best-effort release so the server can clean client_released_at.
                // (May no-op if not yet terminal.)
            }
            nr_spool_delete_chunk(m->local_id);
            r->abandoned++;
            ESP_LOGW(TAG, "chunk %.8s receipt timeout — dropped meta", m->local_id);
        }
        return true;
    }

    if (m->state == NR_CHUNK_TERMINAL) {
        nr_spool_delete_chunk(m->local_id);
        return true;
    }

    // READY / FAILED / UPLOADING / REUPLOAD: bounded hold.
    if (age > MAX_CHUNK_HOLD_MS) {
        abandon_chunk(m, NR_GAP_STORAGE_FULL, "stream hold timeout");
        r->abandoned++;
        return true;
    }

    nr_session_rec_t sess;
    if (!nr_spool_get_session(m->session_id, &sess)) {
        abandon_chunk(m, NR_GAP_CAPTURE_ERROR, "session missing");
        r->abandoned++;
        return true;
    }
    if (!sess.synced && sess.declare_fail_count >= SESSION_DECLARE_FAIL_LIMIT) {
        abandon_chunk(m, NR_GAP_CAPTURE_ERROR, "session declare failed");
        r->abandoned++;
        return true;
    }
    return true;
}

typedef struct { const char *sid; } gap_purge_ctx_t;
static bool purge_gaps_for_session_cb(const nr_gap_rec_t *g, void *ctx)
{
    gap_purge_ctx_t *p = ctx;
    if (strcmp(g->session_id, p->sid) == 0) nr_spool_delete_gap(g->id);
    return true;
}

typedef struct { int dropped; } dead_sess_ctx_t;
static bool drop_dead_session_cb(const nr_session_rec_t *rec, void *ctx)
{
    dead_sess_ctx_t *d = ctx;
    // Never delete the live (non-ended) session — the recorder owns it.
    if (!rec->ended) return true;
    if (rec->synced && rec->close_synced) return true;  // cleaned by cleanup_session_cb
    if (!rec->synced && rec->declare_fail_count < SESSION_DECLARE_FAIL_LIMIT) return true;
    has_chunk_ctx_t h = { .sid = rec->id, .found = false };
    nr_spool_for_each_chunk(has_chunk_cb, &h);
    if (!h.found) {
        // Session never reached the server: its gaps are undeliverable too.
        if (!rec->synced) {
            gap_purge_ctx_t gp = { .sid = rec->id };
            nr_spool_for_each_gap(purge_gaps_for_session_cb, &gp);
        }
        nr_spool_delete_session(rec->id);
        d->dropped++;
        ESP_LOGW(TAG, "dropped undeliverable session %.8s", rec->id);
    }
    return true;
}

// ---- one pump cycle --------------------------------------------------------

static void pump_once(void)
{
    // Even offline: enforce the hold window so PSRAM cannot fill with audio that
    // will never leave the device. Gaps for abandoned spans are queued and sync
    // once the link and session are available.
    reclaim_ctx_t rctx = { .now_mono = nr_time_monotonic_ms(), .abandoned = 0 };
    nr_spool_for_each_chunk(reclaim_stale_cb, &rctx);
    if (rctx.abandoned > 0) {
        esp_event_post(NR_EVENT, NR_EVT_UPLOAD_CHANGED, NULL, 0, 0);
    }

    if (!nr_net_is_online()) {
        s_drain_next = false;
        s_cycle_backoff_ms = PUMP_IDLE_MS;
        return;
    }

    nr_config_t c; nr_config_get(&c);
    bool has_auth = c.api_key[0] || (c.auth_user[0] && c.auth_pass[0]);
    if (!(c.provisioned && c.wifi_ssid[0] && c.backend_url[0] && has_auth)) {
        s_drain_next = false;
        return;
    }

    cyc_cfg_t cfg = {0};
    nr_strlcpy(cfg.base, c.backend_url, sizeof(cfg.base));
    nr_strlcpy(cfg.api_key, c.api_key, sizeof(cfg.api_key));
    nr_strlcpy(cfg.username, c.auth_user, sizeof(cfg.username));
    nr_strlcpy(cfg.password, c.auth_pass, sizeof(cfg.password));
    nr_strlcpy(cfg.device_id, c.device_id, sizeof(cfg.device_id));
    nr_strlcpy(cfg.device_client, c.device_client_uuid, sizeof(cfg.device_client));
    nr_strlcpy(cfg.device_name, c.device_name, sizeof(cfg.device_name));
    cfg.tls_insecure = c.tls_insecure;

    if (!resolve_bearer(&cfg)) {
        s_drain_next = false;
        s_cycle_backoff_ms = PUMP_IDLE_MS;
        return;  // logged out / login failed: retry next cycle
    }

    ensure_meta(&cfg);
    if (!ensure_device(&cfg)) {
        s_drain_next = false;
        s_cycle_backoff_ms = PUMP_IDLE_MS;
        return;   // no point declaring sessions without a device
    }
    heartbeat(&cfg);

    sess_ctx_t sctx = { .cfg = &cfg };
    nr_spool_for_each_session(sync_session_cb, &sctx);
    nr_spool_for_each_gap(sync_gap_cb, &sctx);

    // Reclaim again after session declare so freshly-failed sessions free audio.
    rctx.now_mono = nr_time_monotonic_ms();
    rctx.abandoned = 0;
    nr_spool_for_each_chunk(reclaim_stale_cb, &rctx);
    dead_sess_ctx_t dctx = { .dropped = 0 };
    nr_spool_for_each_session(drop_dead_session_cb, &dctx);

    int released = poll_uploaded(&cfg);

    up_ctx_t uctx = {
        .cfg = &cfg,
        .attempted = 0,
        .accepted = 0,
        .more = false,
        .now_mono = nr_time_monotonic_ms(),
    };
    nr_spool_for_each_chunk(upload_ready_cb, &uctx);

    // After a successful batch, poll once more so short-lived terminal receipts
    // free local audio without waiting a full idle interval.
    if (uctx.accepted > 0) released += poll_uploaded(&cfg);

    nr_spool_for_each_session(cleanup_session_cb, NULL);

    esp_event_post(NR_EVENT, NR_EVT_UPLOAD_CHANGED, NULL, 0, 0);

    bool made_progress = (uctx.accepted > 0) || (released > 0) || (rctx.abandoned > 0);
    if (made_progress && uctx.more) {
        s_drain_next = true;
        s_cycle_backoff_ms = PUMP_DRAIN_MS;
        nr_ingest_kick();
    } else if (made_progress || uctx.more) {
        // Keep draining while work remains (including awaiting-receipt polls).
        s_drain_next = uctx.more || (uctx.accepted > 0);
        s_cycle_backoff_ms = s_drain_next ? PUMP_DRAIN_MS : PUMP_IDLE_MS;
        if (s_drain_next) nr_ingest_kick();
    } else if (uctx.attempted > 0) {
        // Work attempted but nothing landed: ease off instead of tight-looping.
        s_drain_next = false;
        if (s_cycle_backoff_ms < BACKOFF_BASE_MS) s_cycle_backoff_ms = BACKOFF_BASE_MS;
        else s_cycle_backoff_ms = s_cycle_backoff_ms < BACKOFF_MAX_MS
                                     ? s_cycle_backoff_ms * 2 : BACKOFF_MAX_MS;
        if (s_cycle_backoff_ms > BACKOFF_MAX_MS) s_cycle_backoff_ms = BACKOFF_MAX_MS;
    } else {
        s_drain_next = false;
        s_cycle_backoff_ms = PUMP_IDLE_MS;
    }

    if (uctx.attempted || released || rctx.abandoned) {
        ESP_LOGI(TAG, "cycle: accepted=%d attempted=%d released=%d abandoned=%d more=%d backoff=%dms",
                 uctx.accepted, uctx.attempted, released, rctx.abandoned,
                 (int) uctx.more, s_cycle_backoff_ms);
    }
}

static void pump_task(void *arg)
{
    (void) arg;
    ESP_LOGI(TAG, "upload pump started");
    for (;;) {
        int wait_ms = s_drain_next ? PUMP_DRAIN_MS : s_cycle_backoff_ms;
        if (wait_ms < PUMP_DRAIN_MS) wait_ms = PUMP_DRAIN_MS;
        if (wait_ms > BACKOFF_MAX_MS) wait_ms = BACKOFF_MAX_MS;
        // Wait for a kick or the adaptive interval, whichever comes first.
        xSemaphoreTake(s_kick, pdMS_TO_TICKS(wait_ms));
        // Drain any coalesced kicks so a long cycle doesn't leave a stale give.
        while (xSemaphoreTake(s_kick, 0) == pdTRUE) { /* discard */ }
        pump_once();
    }
}

void nr_ingest_kick(void)
{
    if (s_kick) xSemaphoreGive(s_kick);
}

esp_err_t nr_ingest_init(void)
{
    s_kick = xSemaphoreCreateBinary();
    s_status_lock = xSemaphoreCreateMutex();
    if (!s_kick || !s_status_lock) return ESP_ERR_NO_MEM;
    // TLS + JSON + multipart needs a generous stack; 8 KiB was marginal and
    // silent stack overflows look exactly like "stuck pending forever".
    if (xTaskCreatePinnedToCore(pump_task, "nr_pump", 12288, NULL, 5, &s_task, tskNO_AFFINITY) != pdPASS)
        return ESP_FAIL;
    return ESP_OK;
}
