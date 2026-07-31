// SPDX-License-Identifier: MIT
#include "nr_ingest.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "cJSON.h"

#include "config/nr_config.h"
#include "net/nr_time.h"
#include "net/nr_http.h"
#include "net/nr_wifi.h"
#include "ingest/nr_spool.h"
#include "util/nr_util.h"

static const char *TAG = "nr_ingest";

#define PUMP_INTERVAL_MS   15000
#define MAX_UPLOADS_CYCLE  6
#define MAX_POLL_IDS       80
#define REUPLOAD_LIMIT     3

static TaskHandle_t s_task;
static SemaphoreHandle_t s_kick;
static SemaphoreHandle_t s_status_lock;
static nr_ingest_status_t s_status;
static bool s_device_registered;
static bool s_meta_fetched;
static int64_t s_last_heartbeat_ms;

// Snapshot of config used for a whole cycle so it cannot change mid-request.
typedef struct {
    char base[NR_CFG_URL_MAX];
    char api_key[NR_CFG_SECRET_MAX];
    char device_id[NR_UUID_LEN];
    char device_client[NR_UUID_LEN];
    char device_name[NR_CFG_STR_MAX];
    bool tls_insecure;
} cyc_cfg_t;

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

void nr_ingest_get_status(nr_ingest_status_t *out)
{
    nr_spool_stats_t st; nr_spool_stats(&st);
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    *out = s_status;
    xSemaphoreGive(s_status_lock);
    out->pending_upload = st.pending_upload;
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
                                    cfg->api_key[0] ? cfg->api_key : NULL,
                                    NULL, 0, cfg->tls_insecure, 20000, &res);
    free(body);
    if (status) *status = res.status;
    if (err != ESP_OK) { status_set_error("network error", 0); return NULL; }

    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    s_status.server_reachable = true;
    s_status.last_http_status = res.status;
    xSemaphoreGive(s_status_lock);

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

static bool ensure_device(const cyc_cfg_t *cfg)
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
    if (j) cJSON_Delete(j);
    if (status == 200 || status == 201) { s_device_registered = true; return true; }
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
}

// ---- session sync ----------------------------------------------------------

static void declare_session(const cyc_cfg_t *cfg, nr_session_rec_t *rec)
{
    char started[NR_ISO8601_LEN];
    nr_time_iso_from_epoch_ms(rec->start_epoch_ms, started);

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "id", rec->id);
    cJSON_AddStringToObject(body, "deviceId", cfg->device_id);
    cJSON_AddStringToObject(body, "clientUuid", rec->id);
    cJSON_AddStringToObject(body, "startedAt", started);
    cJSON_AddStringToObject(body, "timezone", rec->timezone[0] ? rec->timezone : "UTC");
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
    if (j) cJSON_Delete(j);
    if (status == 200 || status == 201) {
        rec->synced = true;
        nr_spool_put_session(rec);
        ESP_LOGI(TAG, "session %.8s declared", rec->id);
    }
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

typedef struct { const cyc_cfg_t *cfg; } sess_ctx_t;

static bool sync_session_cb(const nr_session_rec_t *rec_in, void *ctx)
{
    sess_ctx_t *c = ctx;
    nr_session_rec_t rec = *rec_in;

    // Back-compute the true wall-clock start once NTP has landed.
    if (rec.start_epoch_ms == 0 && nr_time_is_valid()) {
        rec.start_epoch_ms = nr_time_epoch_ms() - (nr_time_monotonic_ms() - rec.start_monotonic_ms);
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
    if (cJSON_IsString(cid) && cid->valuestring[0]) nr_strlcpy(m.server_chunk_id, cid->valuestring, sizeof(m.server_chunk_id));

    bool terminal = (!strcmp(state, "transcribed") || !strcmp(state, "silent"));
    bool proven = cJSON_GetObjectItem(receipt, "persistedAt") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "persistedAt")) &&
                  cJSON_GetObjectItem(receipt, "serverAudioDeletedAt") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "serverAudioDeletedAt")) &&
                  cJSON_GetObjectItem(receipt, "transcriptSha256") && !cJSON_IsNull(cJSON_GetObjectItem(receipt, "transcriptSha256"));

    if (terminal && proven) {
        m.state = NR_CHUNK_TERMINAL;
        nr_spool_update_chunk(&m);
        if (m.server_chunk_id[0]) release_chunk(cfg, m.server_chunk_id);
        nr_spool_delete_chunk(local_id);      // reliability invariant satisfied
        status_note_receipt();
        return true;
    }
    if (!strcmp(state, "reupload_required")) {
        m.reupload_attempts++;
        m.state = (m.reupload_attempts >= REUPLOAD_LIMIT) ? NR_CHUNK_NEEDS_ATTENTION : NR_CHUNK_READY;
        nr_spool_update_chunk(&m);
        return false;
    }
    // uploaded / persisted_cleanup_pending / other non-terminal
    m.state = NR_CHUNK_UPLOADED;
    nr_spool_update_chunk(&m);
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

static void poll_uploaded(const cyc_cfg_t *cfg)
{
    poll_ctx_t *p = calloc(1, sizeof(*p));
    if (!p) return;
    nr_spool_for_each_chunk(collect_uploaded_cb, p);
    if (p->count == 0) { free(p); return; }

    cJSON *body = cJSON_CreateObject();
    cJSON *arr = cJSON_AddArrayToObject(body, "chunkIds");
    for (int i = 0; i < p->count; i++) cJSON_AddItemToArray(arr, cJSON_CreateString(p->server_ids[i]));

    int status = 0;
    cJSON *j = api_send(cfg, "POST", "/ingest/chunks/status", body, &status);
    if (j && status == 200) {
        cJSON *receipts = cJSON_GetObjectItem(j, "receipts");
        cJSON *r;
        cJSON_ArrayForEach(r, receipts) {
            cJSON *cid = cJSON_GetObjectItem(r, "chunkId");
            if (!cJSON_IsString(cid)) continue;
            for (int i = 0; i < p->count; i++) {
                if (strcmp(p->server_ids[i], cid->valuestring) == 0) { accept_receipt(cfg, p->local_ids[i], r); break; }
            }
        }
    }
    if (j) cJSON_Delete(j);
    free(p);
}

// ---- upload ready ----------------------------------------------------------

static void upload_chunk(const cyc_cfg_t *cfg, const nr_chunk_meta_t *cm)
{
    nr_session_rec_t sess;
    if (!nr_spool_get_session(cm->session_id, &sess) || !sess.synced || sess.start_epoch_ms == 0) return;

    const uint8_t *mem = NULL; size_t len = 0; char path[192];
    if (!nr_spool_borrow_wav(cm->local_id, &mem, &len, path, sizeof(path))) return;

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

    nr_http_result_t res;
    esp_err_t err = nr_http_put_wav_multipart(url, cfg->api_key[0] ? cfg->api_key : NULL,
                                              hdrs, sizeof(hdrs) / sizeof(hdrs[0]),
                                              mem, mem ? NULL : path, len, filename,
                                              cfg->tls_insecure, 30000, &res);
    if (err != ESP_OK) {
        if (nr_spool_get_chunk(cm->local_id, &m)) { m.state = NR_CHUNK_FAILED; nr_spool_update_chunk(&m); }
        status_set_error("upload failed", 0);
        return;
    }
    xSemaphoreTake(s_status_lock, portMAX_DELAY);
    s_status.server_reachable = true;
    s_status.last_http_status = res.status;
    xSemaphoreGive(s_status_lock);

    if (res.status == 401) {
        if (nr_spool_get_chunk(cm->local_id, &m)) { m.state = NR_CHUNK_READY; nr_spool_update_chunk(&m); }
        status_set_error("auth rejected (check API key)", 401);
    } else if (res.status >= 200 && res.status < 300 && res.body) {
        cJSON *j = cJSON_Parse(res.body);
        cJSON *receipt = j ? cJSON_GetObjectItem(j, "receipt") : NULL;
        if (receipt) accept_receipt(cfg, cm->local_id, receipt);
        else if (nr_spool_get_chunk(cm->local_id, &m)) { m.state = NR_CHUNK_UPLOADED; nr_spool_update_chunk(&m); }
        if (j) cJSON_Delete(j);
    } else {
        if (nr_spool_get_chunk(cm->local_id, &m)) { m.state = NR_CHUNK_FAILED; nr_spool_update_chunk(&m); }
        char msg[64]; snprintf(msg, sizeof(msg), "upload HTTP %d", res.status);
        status_set_error(msg, res.status);
    }
    nr_http_result_free(&res);
}

typedef struct { const cyc_cfg_t *cfg; int uploaded; bool more; } up_ctx_t;

static bool upload_ready_cb(const nr_chunk_meta_t *m, void *ctx)
{
    up_ctx_t *u = ctx;
    bool wants = m->state == NR_CHUNK_READY || m->state == NR_CHUNK_FAILED ||
                 m->state == NR_CHUNK_UPLOADING;  // UPLOADING => crash-recovered
    if (!wants) return true;
    if (u->uploaded >= MAX_UPLOADS_CYCLE) { u->more = true; return false; }
    upload_chunk(u->cfg, m);
    u->uploaded++;
    return true;
}

// ---- session cleanup -------------------------------------------------------

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

// ---- one pump cycle --------------------------------------------------------

static void pump_once(void)
{
    if (!nr_net_is_online()) return;

    nr_config_t c; nr_config_get(&c);
    if (!(c.provisioned && c.wifi_ssid[0] && c.backend_url[0] && c.api_key[0])) return;

    cyc_cfg_t cfg = {0};
    nr_strlcpy(cfg.base, c.backend_url, sizeof(cfg.base));
    nr_strlcpy(cfg.api_key, c.api_key, sizeof(cfg.api_key));
    nr_strlcpy(cfg.device_id, c.device_id, sizeof(cfg.device_id));
    nr_strlcpy(cfg.device_client, c.device_client_uuid, sizeof(cfg.device_client));
    nr_strlcpy(cfg.device_name, c.device_name, sizeof(cfg.device_name));
    cfg.tls_insecure = c.tls_insecure;

    ensure_meta(&cfg);
    if (!ensure_device(&cfg)) return;   // no point declaring sessions without a device
    heartbeat(&cfg);

    sess_ctx_t sctx = { .cfg = &cfg };
    nr_spool_for_each_session(sync_session_cb, &sctx);
    nr_spool_for_each_gap(sync_gap_cb, &sctx);

    poll_uploaded(&cfg);

    up_ctx_t uctx = { .cfg = &cfg, .uploaded = 0, .more = false };
    nr_spool_for_each_chunk(upload_ready_cb, &uctx);

    nr_spool_for_each_session(cleanup_session_cb, NULL);

    esp_event_post(NR_EVENT, NR_EVT_UPLOAD_CHANGED, NULL, 0, 0);

    if (uctx.more) nr_ingest_kick();   // large backlog: keep draining promptly
}

static void pump_task(void *arg)
{
    (void) arg;
    ESP_LOGI(TAG, "upload pump started");
    for (;;) {
        // Wait for a kick or the periodic interval, whichever comes first.
        xSemaphoreTake(s_kick, pdMS_TO_TICKS(PUMP_INTERVAL_MS));
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
    if (xTaskCreatePinnedToCore(pump_task, "nr_pump", 8192, NULL, 5, &s_task, tskNO_AFFINITY) != pdPASS)
        return ESP_FAIL;
    return ESP_OK;
}
