// SPDX-License-Identifier: MIT
#include "nr_recorder.h"

#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_heap_caps.h"

#include "board/nr_mic.h"
#include "config/nr_config.h"
#include "net/nr_time.h"
#include "ingest/nr_spool.h"
#include "ingest/nr_ingest.h"
#include "util/nr_util.h"

static const char *TAG = "nr_rec";

#define SAMPLE_RATE      16000
#define BYTES_PER_MS     (SAMPLE_RATE * 2 / 1000)   // 32
#define SAMPLES_PER_MS   (SAMPLE_RATE / 1000)       // 16
#define WAV_HEADER       44
#define READ_SAMPLES     1600                       // 100 ms per read
#define MIC_ERR_LIMIT    10                         // consecutive read failures -> recover

typedef struct {
    // session
    nr_session_rec_t session;
    // accumulation buffer: [0..44) WAV header, [44..) PCM
    uint8_t *buf;
    size_t cap_bytes;
    size_t fill_samples;          // int16 samples currently in the PCM region
    // timeline
    int64_t offset_ms;            // session-relative position of the next chunk
    bool first_in_run;            // reported overlap is 0 for the first chunk of a run
    uint32_t target_ms;
    uint32_t overlap_ms;
    uint32_t sequence;
    // discontinuity (pause / fault) bookkeeping
    bool discont_active;
    nr_gap_reason_t discont_reason;
    int64_t discont_start_offset;
    int64_t discont_start_mono;
    // ui
    float level;
    volatile bool want_paused;
    nr_capture_state_t state;
} rec_t;

static rec_t s_rec;
static SemaphoreHandle_t s_lock;
static TaskHandle_t s_task;

// ---- WAV header ------------------------------------------------------------

static void put_u32(uint8_t *p, uint32_t v) { p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void put_u16(uint8_t *p, uint16_t v) { p[0]=v; p[1]=v>>8; }

static void wav_header(uint8_t *b, uint32_t pcm_bytes)
{
    memcpy(b, "RIFF", 4);
    put_u32(b + 4, 36 + pcm_bytes);
    memcpy(b + 8, "WAVE", 4);
    memcpy(b + 12, "fmt ", 4);
    put_u32(b + 16, 16);
    put_u16(b + 20, 1);                 // PCM
    put_u16(b + 22, 1);                 // mono
    put_u32(b + 24, SAMPLE_RATE);
    put_u32(b + 28, SAMPLE_RATE * 1 * 16 / 8);
    put_u16(b + 32, 1 * 16 / 8);        // block align
    put_u16(b + 34, 16);                // bits per sample
    memcpy(b + 36, "data", 4);
    put_u32(b + 40, pcm_bytes);
}

// ---- gaps ------------------------------------------------------------------

static void declare_gap(const rec_t *r, nr_gap_reason_t reason, int64_t start_off, int64_t end_off)
{
    if (end_off <= start_off) return;
    nr_gap_rec_t g = {0};
    nr_uuid_v4(g.id);
    nr_strlcpy(g.session_id, r->session.id, sizeof(g.session_id));
    nr_strlcpy(g.source_id, r->session.source_id, sizeof(g.source_id));
    g.start_offset_ms = start_off;
    g.end_offset_ms = end_off;
    g.start_sequence = -1;
    g.end_sequence = -1;
    g.reason = reason;
    nr_spool_put_gap(&g);
    ESP_LOGW(TAG, "gap %s [%lld..%lld]ms", nr_gap_reason_str(reason),
             (long long) start_off, (long long) end_off);
    nr_ingest_kick();
}

// ---- chunk emission --------------------------------------------------------

static void emit_chunk(rec_t *r, bool is_final)
{
    if (r->fill_samples == 0) return;
    uint32_t pcm_bytes = (uint32_t) r->fill_samples * 2;
    uint32_t duration_ms = (uint32_t) (r->fill_samples / SAMPLES_PER_MS);
    if (duration_ms == 0) return;
    uint32_t overlap = r->first_in_run ? 0 : r->overlap_ms;

    wav_header(r->buf, pcm_bytes);
    nr_chunk_meta_t m = {0};
    nr_uuid_v4(m.local_id);
    nr_strlcpy(m.session_id, r->session.id, sizeof(m.session_id));
    nr_strlcpy(m.source_id, r->session.source_id, sizeof(m.source_id));
    m.sequence = r->sequence;
    m.monotonic_offset_ms = r->offset_ms;
    m.duration_ms = duration_ms;
    m.overlap_ms = overlap;
    nr_strlcpy(m.channel_layout, "mono", sizeof(m.channel_layout));
    nr_sha256_hex(r->buf, WAV_HEADER + pcm_bytes, m.sha256);
    m.byte_size = WAV_HEADER + pcm_bytes;
    m.is_final = is_final;
    m.state = NR_CHUNK_READY;

    if (nr_spool_put_chunk(&m, r->buf, WAV_HEADER + pcm_bytes) == ESP_OK) {
        r->sequence++;
        r->session.final_sequence = (int32_t) m.sequence;
    } else {
        ESP_LOGE(TAG, "spool put failed; declaring capture_error gap");
        declare_gap(r, NR_GAP_STORAGE_FULL, r->offset_ms, r->offset_ms + duration_ms);
    }

    // Advance the timeline. Non-final chunks carry `overlap_ms` of audio forward.
    uint32_t advance = is_final ? duration_ms
                                : (duration_ms > r->overlap_ms ? duration_ms - r->overlap_ms : duration_ms);
    r->offset_ms += advance;

    if (!is_final && duration_ms > r->overlap_ms) {
        size_t carry = (size_t) r->overlap_ms * SAMPLES_PER_MS;
        if (carry > r->fill_samples) carry = r->fill_samples;
        memmove(r->buf + WAV_HEADER,
                r->buf + WAV_HEADER + (r->fill_samples - carry) * 2,
                carry * 2);
        r->fill_samples = carry;
        r->first_in_run = false;
    } else {
        r->fill_samples = 0;
        r->first_in_run = true;
    }

    nr_ingest_kick();

    // Enforce the hard storage cap; each dropped chunk becomes a truthful gap.
    nr_spool_drop_t drop;
    while (nr_spool_enforce_cap(&drop)) {
        declare_gap(r, NR_GAP_STORAGE_FULL, drop.start_offset_ms, drop.end_offset_ms);
    }
}

// ---- session lifecycle -----------------------------------------------------

static void open_new_session(rec_t *r)
{
    memset(&r->session, 0, sizeof(r->session));
    nr_uuid_v4(r->session.id);
    nr_uuid_v4(r->session.source_id);
    r->session.start_monotonic_ms = nr_time_monotonic_ms();
    r->session.start_epoch_ms = nr_time_is_valid() ? nr_time_epoch_ms() : 0;
    r->session.sample_rate = SAMPLE_RATE;
    r->session.final_sequence = -1;
    nr_config_t c; nr_config_get(&c);
    nr_strlcpy(r->session.timezone, c.tz_name[0] ? c.tz_name : "UTC", sizeof(r->session.timezone));
    r->offset_ms = 0;
    r->fill_samples = 0;
    r->first_in_run = true;
    r->sequence = 0;
    r->target_ms = c.chunk_target_ms ? c.chunk_target_ms : 30000;
    if (r->target_ms < 15000) r->target_ms = 15000;
    if (r->target_ms > 40000) r->target_ms = 40000;   // bound RAM for the buffer
    r->overlap_ms = c.chunk_overlap_ms;
    if (r->overlap_ms > r->target_ms / 4) r->overlap_ms = r->target_ms / 4;
    nr_spool_put_session(&r->session);
    ESP_LOGI(TAG, "opened session %.8s (target=%ums overlap=%ums)", r->session.id, r->target_ms, r->overlap_ms);
}

// Close any prior sessions left over from before a reboot as interrupted so the
// pump can finish uploading their surviving chunks and PATCH them closed.
typedef struct { int32_t max_seq; const char *sid; } maxseq_ctx_t;
static bool maxseq_cb(const nr_chunk_meta_t *m, void *ctx)
{
    maxseq_ctx_t *x = ctx;
    if (strcmp(m->session_id, x->sid) == 0 && (int32_t) m->sequence > x->max_seq) x->max_seq = (int32_t) m->sequence;
    return true;
}
static bool recover_session_cb(const nr_session_rec_t *rec, void *ctx)
{
    (void) ctx;
    if (rec->close_synced) return true;
    nr_session_rec_t s = *rec;
    maxseq_ctx_t x = { .max_seq = -1, .sid = s.id };
    nr_spool_for_each_chunk(maxseq_cb, &x);
    // An empty session that was never declared to the server (no chunks, not
    // synced) is just reboot churn — drop it instead of littering the backend.
    if (x.max_seq < 0 && !s.synced) {
        nr_spool_delete_session(s.id);
        return true;
    }
    s.ended = true;
    s.interrupted = true;
    if (x.max_seq >= 0) s.final_sequence = x.max_seq;
    nr_spool_put_session(&s);
    ESP_LOGI(TAG, "recovered prior session %.8s as interrupted (final=%d)", s.id, (int) s.final_sequence);
    return true;
}

// ---- capture task ----------------------------------------------------------

static void update_level(rec_t *r, const int16_t *s, size_t n)
{
    int32_t peak = 0;
    for (size_t i = 0; i < n; i++) { int32_t a = s[i] < 0 ? -s[i] : s[i]; if (a > peak) peak = a; }
    float lvl = peak / 32768.0f;
    // asymmetric smoothing: fast attack, slow release, for a lively-but-stable meter
    if (lvl > r->level) r->level = r->level * 0.4f + lvl * 0.6f;
    else r->level = r->level * 0.85f + lvl * 0.15f;
}

static void finish_partial_and_pause_or_error(rec_t *r, nr_gap_reason_t reason)
{
    // Preserve already-captured audio: flush whatever is buffered as a final
    // chunk so it still gets transcribed, then begin the discontinuity.
    if (r->fill_samples >= (size_t) 1000 * SAMPLES_PER_MS) emit_chunk(r, true);
    else { r->fill_samples = 0; r->first_in_run = true; }
    r->discont_active = true;
    r->discont_reason = reason;
    r->discont_start_offset = r->offset_ms;
    r->discont_start_mono = nr_time_monotonic_ms();
    nr_mic_stop();
}

static void end_discontinuity(rec_t *r)
{
    if (!r->discont_active) return;
    int64_t dur = nr_time_monotonic_ms() - r->discont_start_mono;
    if (dur > 0) {
        declare_gap(r, r->discont_reason, r->discont_start_offset, r->discont_start_offset + dur);
        r->offset_ms = r->discont_start_offset + dur;
    }
    r->discont_active = false;
    r->first_in_run = true;
    r->fill_samples = 0;
}

static void capture_task(void *arg)
{
    (void) arg;
    rec_t *r = &s_rec;
    int16_t *scratch = malloc(READ_SAMPLES * sizeof(int16_t));
    if (!scratch) { ESP_LOGE(TAG, "no RAM for capture scratch"); vTaskDelete(NULL); return; }

    int mic_errors = 0;
    bool mic_up = false;

    for (;;) {
        bool paused = r->want_paused;

        // --- paused: hold, accumulate a user_paused gap ---------------------
        if (paused) {
            if (r->state != NR_CAP_PAUSED) {
                xSemaphoreTake(s_lock, portMAX_DELAY);
                if (mic_up) { finish_partial_and_pause_or_error(r, NR_GAP_USER_PAUSED); mic_up = false; }
                else { r->discont_active = true; r->discont_reason = NR_GAP_USER_PAUSED;
                       r->discont_start_offset = r->offset_ms; r->discont_start_mono = nr_time_monotonic_ms(); }
                r->state = NR_CAP_PAUSED;
                r->level = 0;
                xSemaphoreGive(s_lock);
                esp_event_post(NR_EVENT, NR_EVT_RECORDING_CHANGED, NULL, 0, 0);
            }
            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }

        // --- (re)start mic if needed ---------------------------------------
        if (!mic_up) {
            if (nr_mic_start(SAMPLE_RATE) == ESP_OK) {
                mic_up = true;
                mic_errors = 0;
                xSemaphoreTake(s_lock, portMAX_DELAY);
                end_discontinuity(r);           // closes a pause or fault span
                r->state = NR_CAP_RECORDING;
                xSemaphoreGive(s_lock);
                esp_event_post(NR_EVENT, NR_EVT_RECORDING_CHANGED, NULL, 0, 0);
            } else {
                if (r->state != NR_CAP_ERROR) {
                    xSemaphoreTake(s_lock, portMAX_DELAY);
                    if (!r->discont_active) { r->discont_active = true; r->discont_reason = NR_GAP_CAPTURE_ERROR;
                        r->discont_start_offset = r->offset_ms; r->discont_start_mono = nr_time_monotonic_ms(); }
                    r->state = NR_CAP_ERROR;
                    xSemaphoreGive(s_lock);
                    esp_event_post(NR_EVENT, NR_EVT_RECORDING_CHANGED, NULL, 0, 0);
                }
                vTaskDelay(pdMS_TO_TICKS(1000));
                continue;
            }
        }

        // --- read a block ---------------------------------------------------
        size_t got = 0;
        esp_err_t err = nr_mic_read(scratch, READ_SAMPLES, &got, 300);
        if (err != ESP_OK) {
            if (++mic_errors >= MIC_ERR_LIMIT) {
                ESP_LOGE(TAG, "microphone fault; recovering");
                xSemaphoreTake(s_lock, portMAX_DELAY);
                finish_partial_and_pause_or_error(r, NR_GAP_CAPTURE_ERROR);
                r->state = NR_CAP_ERROR;
                xSemaphoreGive(s_lock);
                mic_up = false;
                esp_event_post(NR_EVENT, NR_EVT_RECORDING_CHANGED, NULL, 0, 0);
            }
            continue;
        }
        mic_errors = 0;
        if (got == 0) continue;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        update_level(r, scratch, got);
        // append, guarding the buffer
        size_t room = (r->cap_bytes - WAV_HEADER) / 2 - r->fill_samples;
        size_t take = got < room ? got : room;
        memcpy(r->buf + WAV_HEADER + r->fill_samples * 2, scratch, take * 2);
        r->fill_samples += take;
        // emit when we have a full target's worth
        if ((r->fill_samples / SAMPLES_PER_MS) >= r->target_ms) emit_chunk(r, false);
        xSemaphoreGive(s_lock);
    }
}

// ---- public API ------------------------------------------------------------

esp_err_t nr_recorder_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;

    // Close out any sessions that survived a reboot before opening a fresh one.
    nr_spool_for_each_session(recover_session_cb, NULL);

    nr_config_t c; nr_config_get(&c);
    uint32_t target = c.chunk_target_ms ? c.chunk_target_ms : 30000;
    if (target > 40000) target = 40000;
    s_rec.cap_bytes = WAV_HEADER + (size_t) (target + 5000) * BYTES_PER_MS;
    s_rec.buf = heap_caps_malloc(s_rec.cap_bytes, MALLOC_CAP_SPIRAM);
    if (!s_rec.buf) s_rec.buf = malloc(s_rec.cap_bytes);
    if (!s_rec.buf) { ESP_LOGE(TAG, "no RAM for capture buffer (%u B)", (unsigned) s_rec.cap_bytes); return ESP_ERR_NO_MEM; }

    open_new_session(&s_rec);
    s_rec.want_paused = !c.recording_enabled;
    s_rec.state = s_rec.want_paused ? NR_CAP_PAUSED : NR_CAP_IDLE;

    if (xTaskCreatePinnedToCore(capture_task, "nr_capture", 6144, NULL, 6, &s_task, 1) != pdPASS)
        return ESP_FAIL;
    return ESP_OK;
}

void nr_recorder_set_paused(bool paused)
{
    s_rec.want_paused = paused;
}

void nr_recorder_get_status(nr_recorder_status_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    out->state = s_rec.state;
    out->level = s_rec.level;
    out->session_started_epoch_ms = s_rec.session.start_epoch_ms;
    out->elapsed_ms = nr_time_monotonic_ms() - s_rec.session.start_monotonic_ms;
    out->sequence = s_rec.sequence;
    xSemaphoreGive(s_lock);
}
