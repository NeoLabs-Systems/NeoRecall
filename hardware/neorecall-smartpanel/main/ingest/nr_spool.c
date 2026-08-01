// SPDX-License-Identifier: MIT
#include "nr_spool.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "cJSON.h"

#include "net/nr_time.h"
#include "util/nr_util.h"

static const char *TAG = "nr_spool";

typedef struct chunk_node {
    nr_chunk_meta_t meta;
    uint8_t *mem;            // PSRAM WAV bytes when meta.on_disk == false
    struct chunk_node *next;
} chunk_node_t;

typedef struct session_node {
    nr_session_rec_t rec;
    struct session_node *next;
} session_node_t;

typedef struct gap_node {
    nr_gap_rec_t rec;
    struct gap_node *next;
} gap_node_t;

static char s_dir[128];
static size_t s_mem_budget;
static uint64_t s_cap_bytes;
static chunk_node_t *s_chunks;
static session_node_t *s_sessions;
static gap_node_t *s_gaps;
static uint64_t s_bytes_ram;
static SemaphoreHandle_t s_lock;

#define LOCK()   xSemaphoreTakeRecursive(s_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGiveRecursive(s_lock)

// ---- path helpers ----------------------------------------------------------

static void path_for(char kind, const char *id, const char *ext, char *out, size_t n)
{
    snprintf(out, n, "%s/%c_%s.%s", s_dir, kind, id, ext);
}

static esp_err_t write_atomic(const char *path, const char *data, size_t len)
{
    char tmp[160];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) { ESP_LOGE(TAG, "open %s: errno %d", tmp, errno); return ESP_FAIL; }
    size_t wrote = fwrite(data, 1, len, f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (wrote != len) { remove(tmp); return ESP_FAIL; }
    if (rename(tmp, path) != 0) { remove(tmp); return ESP_FAIL; }
    return ESP_OK;
}

// ---- JSON (de)serialisation ------------------------------------------------

static char *chunk_to_json(const nr_chunk_meta_t *m)
{
    cJSON *j = cJSON_CreateObject();
    cJSON_AddStringToObject(j, "local_id", m->local_id);
    cJSON_AddStringToObject(j, "server_chunk_id", m->server_chunk_id);
    cJSON_AddStringToObject(j, "session_id", m->session_id);
    cJSON_AddStringToObject(j, "source_id", m->source_id);
    cJSON_AddNumberToObject(j, "sequence", m->sequence);
    cJSON_AddNumberToObject(j, "offset_ms", (double) m->monotonic_offset_ms);
    cJSON_AddNumberToObject(j, "duration_ms", m->duration_ms);
    cJSON_AddNumberToObject(j, "overlap_ms", m->overlap_ms);
    cJSON_AddStringToObject(j, "layout", m->channel_layout);
    cJSON_AddStringToObject(j, "sha256", m->sha256);
    cJSON_AddNumberToObject(j, "byte_size", m->byte_size);
    cJSON_AddBoolToObject(j, "is_final", m->is_final);
    cJSON_AddNumberToObject(j, "state", m->state);
    cJSON_AddNumberToObject(j, "reupload", m->reupload_attempts);
    cJSON_AddNumberToObject(j, "fail_count", m->fail_count);
    char *s = cJSON_PrintUnformatted(j);
    cJSON_Delete(j);
    return s;
}

static bool chunk_from_json(const char *buf, nr_chunk_meta_t *m)
{
    cJSON *j = cJSON_Parse(buf);
    if (!j) return false;
    memset(m, 0, sizeof(*m));
    const cJSON *v;
#define STR(field, key) v = cJSON_GetObjectItem(j, key); if (cJSON_IsString(v)) nr_strlcpy(m->field, v->valuestring, sizeof(m->field))
#define NUM(field, key) v = cJSON_GetObjectItem(j, key); if (cJSON_IsNumber(v)) m->field = v->valuedouble
    STR(local_id, "local_id");
    STR(server_chunk_id, "server_chunk_id");
    STR(session_id, "session_id");
    STR(source_id, "source_id");
    NUM(sequence, "sequence");
    v = cJSON_GetObjectItem(j, "offset_ms"); if (cJSON_IsNumber(v)) m->monotonic_offset_ms = (int64_t) v->valuedouble;
    NUM(duration_ms, "duration_ms");
    NUM(overlap_ms, "overlap_ms");
    STR(channel_layout, "layout");
    STR(sha256, "sha256");
    NUM(byte_size, "byte_size");
    v = cJSON_GetObjectItem(j, "is_final"); m->is_final = cJSON_IsTrue(v);
    v = cJSON_GetObjectItem(j, "state"); if (cJSON_IsNumber(v)) m->state = (nr_chunk_state_t) v->valueint;
    NUM(reupload_attempts, "reupload");
    NUM(fail_count, "fail_count");
#undef STR
#undef NUM
    cJSON_Delete(j);
    m->on_disk = true;
    // A power loss mid-PUT leaves UPLOADING on disk. The PUT is idempotent, so
    // the only safe recovery is to retry from READY.
    if (m->state == NR_CHUNK_UPLOADING) m->state = NR_CHUNK_READY;
    m->next_attempt_mono_ms = 0;   // never durable; retry immediately after reboot
    return m->local_id[0] != '\0';
}

static char *session_to_json(const nr_session_rec_t *r)
{
    cJSON *j = cJSON_CreateObject();
    cJSON_AddStringToObject(j, "id", r->id);
    cJSON_AddStringToObject(j, "source_id", r->source_id);
    cJSON_AddStringToObject(j, "timezone", r->timezone);
    cJSON_AddNumberToObject(j, "start_epoch_ms", (double) r->start_epoch_ms);
    cJSON_AddNumberToObject(j, "start_mono_ms", (double) r->start_monotonic_ms);
    cJSON_AddNumberToObject(j, "sample_rate", r->sample_rate);
    cJSON_AddBoolToObject(j, "synced", r->synced);
    cJSON_AddBoolToObject(j, "ended", r->ended);
    cJSON_AddBoolToObject(j, "close_synced", r->close_synced);
    cJSON_AddBoolToObject(j, "interrupted", r->interrupted);
    cJSON_AddNumberToObject(j, "final_sequence", r->final_sequence);
    char *s = cJSON_PrintUnformatted(j);
    cJSON_Delete(j);
    return s;
}

static bool session_from_json(const char *buf, nr_session_rec_t *r)
{
    cJSON *j = cJSON_Parse(buf);
    if (!j) return false;
    memset(r, 0, sizeof(*r));
    r->final_sequence = -1;
    const cJSON *v;
    v = cJSON_GetObjectItem(j, "id"); if (cJSON_IsString(v)) nr_strlcpy(r->id, v->valuestring, sizeof(r->id));
    v = cJSON_GetObjectItem(j, "source_id"); if (cJSON_IsString(v)) nr_strlcpy(r->source_id, v->valuestring, sizeof(r->source_id));
    v = cJSON_GetObjectItem(j, "timezone"); if (cJSON_IsString(v)) nr_strlcpy(r->timezone, v->valuestring, sizeof(r->timezone));
    v = cJSON_GetObjectItem(j, "start_epoch_ms"); if (cJSON_IsNumber(v)) r->start_epoch_ms = (int64_t) v->valuedouble;
    v = cJSON_GetObjectItem(j, "start_mono_ms"); if (cJSON_IsNumber(v)) r->start_monotonic_ms = (int64_t) v->valuedouble;
    v = cJSON_GetObjectItem(j, "sample_rate"); if (cJSON_IsNumber(v)) r->sample_rate = v->valueint;
    r->synced = cJSON_IsTrue(cJSON_GetObjectItem(j, "synced"));
    r->ended = cJSON_IsTrue(cJSON_GetObjectItem(j, "ended"));
    r->close_synced = cJSON_IsTrue(cJSON_GetObjectItem(j, "close_synced"));
    r->interrupted = cJSON_IsTrue(cJSON_GetObjectItem(j, "interrupted"));
    v = cJSON_GetObjectItem(j, "final_sequence"); if (cJSON_IsNumber(v)) r->final_sequence = v->valueint;
    cJSON_Delete(j);
    return r->id[0] != '\0';
}

static char *gap_to_json(const nr_gap_rec_t *r)
{
    cJSON *j = cJSON_CreateObject();
    cJSON_AddStringToObject(j, "id", r->id);
    cJSON_AddStringToObject(j, "session_id", r->session_id);
    cJSON_AddStringToObject(j, "source_id", r->source_id);
    cJSON_AddNumberToObject(j, "start_offset_ms", (double) r->start_offset_ms);
    cJSON_AddNumberToObject(j, "end_offset_ms", (double) r->end_offset_ms);
    cJSON_AddNumberToObject(j, "start_sequence", r->start_sequence);
    cJSON_AddNumberToObject(j, "end_sequence", r->end_sequence);
    cJSON_AddNumberToObject(j, "reason", r->reason);
    cJSON_AddBoolToObject(j, "synced", r->synced);
    char *s = cJSON_PrintUnformatted(j);
    cJSON_Delete(j);
    return s;
}

static bool gap_from_json(const char *buf, nr_gap_rec_t *r)
{
    cJSON *j = cJSON_Parse(buf);
    if (!j) return false;
    memset(r, 0, sizeof(*r));
    r->start_sequence = -1; r->end_sequence = -1;
    const cJSON *v;
    v = cJSON_GetObjectItem(j, "id"); if (cJSON_IsString(v)) nr_strlcpy(r->id, v->valuestring, sizeof(r->id));
    v = cJSON_GetObjectItem(j, "session_id"); if (cJSON_IsString(v)) nr_strlcpy(r->session_id, v->valuestring, sizeof(r->session_id));
    v = cJSON_GetObjectItem(j, "source_id"); if (cJSON_IsString(v)) nr_strlcpy(r->source_id, v->valuestring, sizeof(r->source_id));
    v = cJSON_GetObjectItem(j, "start_offset_ms"); if (cJSON_IsNumber(v)) r->start_offset_ms = (int64_t) v->valuedouble;
    v = cJSON_GetObjectItem(j, "end_offset_ms"); if (cJSON_IsNumber(v)) r->end_offset_ms = (int64_t) v->valuedouble;
    v = cJSON_GetObjectItem(j, "start_sequence"); if (cJSON_IsNumber(v)) r->start_sequence = v->valueint;
    v = cJSON_GetObjectItem(j, "end_sequence"); if (cJSON_IsNumber(v)) r->end_sequence = v->valueint;
    v = cJSON_GetObjectItem(j, "reason"); if (cJSON_IsNumber(v)) r->reason = (nr_gap_reason_t) v->valueint;
    r->synced = cJSON_IsTrue(cJSON_GetObjectItem(j, "synced"));
    cJSON_Delete(j);
    return r->id[0] != '\0';
}

// ---- internal helpers (lock held) ------------------------------------------

static chunk_node_t *find_chunk(const char *id)
{
    for (chunk_node_t *n = s_chunks; n; n = n->next)
        if (strcmp(n->meta.local_id, id) == 0) return n;
    return NULL;
}

static esp_err_t spill_chunk_locked(chunk_node_t *n)
{
    if (n->meta.on_disk) return ESP_OK;
    char wav[160], js[160];
    path_for('c', n->meta.local_id, "wav", wav, sizeof(wav));
    path_for('c', n->meta.local_id, "js", js, sizeof(js));
    esp_err_t err = write_atomic(wav, (const char *) n->mem, n->meta.byte_size);
    if (err != ESP_OK) return err;
    char *sidecar = chunk_to_json(&n->meta);
    if (!sidecar) { remove(wav); return ESP_ERR_NO_MEM; }
    err = write_atomic(js, sidecar, strlen(sidecar));
    free(sidecar);
    if (err != ESP_OK) { remove(wav); return err; }
    free(n->mem);
    n->mem = NULL;
    n->meta.on_disk = true;
    s_bytes_ram -= n->meta.byte_size;
    ESP_LOGI(TAG, "spilled chunk %.8s (%u B) to flash", n->meta.local_id, n->meta.byte_size);
    return ESP_OK;
}

// Reclaim RAM by spilling the oldest memory-backed chunks until under budget.
static void relieve_memory_locked(void)
{
    while (s_bytes_ram > s_mem_budget) {
        chunk_node_t *oldest = NULL;
        for (chunk_node_t *n = s_chunks; n; n = n->next) {
            if (n->meta.on_disk) continue;
            // Never move a chunk whose bytes are currently borrowed for upload.
            if (n->meta.state == NR_CHUNK_UPLOADING) continue;
            if (!oldest || n->meta.created_monotonic_ms < oldest->meta.created_monotonic_ms) oldest = n;
        }
        if (!oldest) break;
        if (spill_chunk_locked(oldest) != ESP_OK) break;  // disk full: stop, cap-enforcer handles it
    }
}

static void free_chunk_files_locked(chunk_node_t *n)
{
    if (n->meta.on_disk) {
        char wav[160], js[160];
        path_for('c', n->meta.local_id, "wav", wav, sizeof(wav));
        path_for('c', n->meta.local_id, "js", js, sizeof(js));
        remove(wav);
        remove(js);
    } else if (n->mem) {
        free(n->mem);
        s_bytes_ram -= n->meta.byte_size;
    }
}

static void unlink_chunk_node_locked(const char *id)
{
    chunk_node_t **pp = &s_chunks;
    while (*pp) {
        if (strcmp((*pp)->meta.local_id, id) == 0) {
            chunk_node_t *dead = *pp;
            *pp = dead->next;
            free_chunk_files_locked(dead);
            free(dead);
            return;
        }
        pp = &(*pp)->next;
    }
}

// ---- init / recovery -------------------------------------------------------

esp_err_t nr_spool_init(const char *dir, size_t mem_budget_bytes, uint64_t cap_bytes)
{
    if (!s_lock) s_lock = xSemaphoreCreateRecursiveMutex();
    if (!s_lock) return ESP_ERR_NO_MEM;
    nr_strlcpy(s_dir, dir, sizeof(s_dir));
    s_mem_budget = mem_budget_bytes;
    s_cap_bytes = cap_bytes;
    mkdir(s_dir, 0775);

    DIR *d = opendir(s_dir);
    if (!d) { ESP_LOGE(TAG, "cannot open spool dir %s", s_dir); return ESP_FAIL; }

    struct dirent *ent;
    // First pass: drop stray temp files.
    while ((ent = readdir(d))) {
        size_t len = strlen(ent->d_name);
        if (len > 4 && strcmp(ent->d_name + len - 4, ".tmp") == 0) {
            char p[160]; snprintf(p, sizeof(p), "%s/%s", s_dir, ent->d_name); remove(p);
        }
    }
    rewinddir(d);

    LOCK();
    while ((ent = readdir(d))) {
        const char *name = ent->d_name;
        char path[160]; snprintf(path, sizeof(path), "%s/%s", s_dir, name);
        size_t len = strlen(name);
        bool is_js = len > 3 && strcmp(name + len - 3, ".js") == 0;
        if (!is_js) continue;

        FILE *f = fopen(path, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz <= 0 || sz > 8192) { fclose(f); continue; }
        char *buf = malloc(sz + 1);
        if (!buf) { fclose(f); continue; }
        size_t rd = fread(buf, 1, sz, f); buf[rd] = '\0';
        fclose(f);

        if (name[0] == 'c' && name[1] == '_') {
            nr_chunk_meta_t m;
            if (chunk_from_json(buf, &m)) {
                char wav[160]; path_for('c', m.local_id, "wav", wav, sizeof(wav));
                struct stat st;
                if (stat(wav, &st) == 0 && (uint32_t) st.st_size == m.byte_size) {
                    chunk_node_t *n = calloc(1, sizeof(*n));
                    if (n) { n->meta = m; n->meta.created_monotonic_ms = 0; n->next = s_chunks; s_chunks = n; }
                } else {
                    remove(path);  // sidecar without matching wav: incomplete
                }
            }
        } else if (name[0] == 's' && name[1] == '_') {
            nr_session_rec_t r;
            if (session_from_json(buf, &r)) {
                session_node_t *n = calloc(1, sizeof(*n));
                if (n) { n->rec = r; n->next = s_sessions; s_sessions = n; }
            }
        } else if (name[0] == 'g' && name[1] == '_') {
            nr_gap_rec_t r;
            if (gap_from_json(buf, &r)) {
                gap_node_t *n = calloc(1, sizeof(*n));
                if (n) { n->rec = r; n->next = s_gaps; s_gaps = n; }
            }
        }
        free(buf);
    }
    // Second pass: delete orphan .wav files with no sidecar (index built above).
    rewinddir(d);
    while ((ent = readdir(d))) {
        const char *name = ent->d_name;
        size_t len = strlen(name);
        if (!(len > 6 && name[0] == 'c' && name[1] == '_' && strcmp(name + len - 4, ".wav") == 0)) continue;
        char id[NR_UUID_LEN] = {0};
        size_t idlen = len - 6; // strip "c_" and ".wav"
        if (idlen >= sizeof(id)) continue;
        memcpy(id, name + 2, idlen); id[idlen] = '\0';
        if (!find_chunk(id)) { char p[160]; snprintf(p, sizeof(p), "%s/%s", s_dir, name); remove(p); }
    }
    UNLOCK();
    closedir(d);

    uint32_t nc = 0; for (chunk_node_t *n = s_chunks; n; n = n->next) nc++;
    ESP_LOGI(TAG, "spool ready at %s (recovered %u disk chunks)", s_dir, nc);
    return ESP_OK;
}

const char *nr_spool_dir(void) { return s_dir; }

// ---- chunks ----------------------------------------------------------------

esp_err_t nr_spool_put_chunk(const nr_chunk_meta_t *meta, const void *wav, size_t wav_len)
{
    if (!meta || !wav || wav_len == 0) return ESP_ERR_INVALID_ARG;
    uint8_t *copy = heap_caps_malloc(wav_len, MALLOC_CAP_SPIRAM);
    if (!copy) copy = malloc(wav_len);            // fall back to internal RAM
    if (!copy) return ESP_ERR_NO_MEM;
    memcpy(copy, wav, wav_len);

    chunk_node_t *n = calloc(1, sizeof(*n));
    if (!n) { free(copy); return ESP_ERR_NO_MEM; }
    n->meta = *meta;
    n->meta.byte_size = (uint32_t) wav_len;
    n->meta.on_disk = false;
    n->meta.created_monotonic_ms = nr_time_monotonic_ms();
    n->mem = copy;

    LOCK();
    // append to tail so iteration is oldest-first
    chunk_node_t **pp = &s_chunks;
    while (*pp) pp = &(*pp)->next;
    *pp = n;
    s_bytes_ram += wav_len;
    relieve_memory_locked();
    UNLOCK();
    return ESP_OK;
}

bool nr_spool_get_chunk(const char *local_id, nr_chunk_meta_t *out)
{
    LOCK();
    chunk_node_t *n = find_chunk(local_id);
    if (n && out) *out = n->meta;
    bool found = n != NULL;
    UNLOCK();
    return found;
}

esp_err_t nr_spool_update_chunk(const nr_chunk_meta_t *meta)
{
    LOCK();
    chunk_node_t *n = find_chunk(meta->local_id);
    if (!n) { UNLOCK(); return ESP_ERR_NOT_FOUND; }
    uint8_t *mem = n->mem;
    bool was_disk = n->meta.on_disk;
    n->meta = *meta;
    n->meta.on_disk = was_disk;   // backing is owned by the spool, not the caller
    esp_err_t err = ESP_OK;
    if (was_disk) {
        char js[160]; path_for('c', n->meta.local_id, "js", js, sizeof(js));
        char *sidecar = chunk_to_json(&n->meta);
        if (sidecar) { err = write_atomic(js, sidecar, strlen(sidecar)); free(sidecar); }
        else err = ESP_ERR_NO_MEM;
    }
    (void) mem;
    UNLOCK();
    return err;
}

void nr_spool_delete_chunk(const char *local_id)
{
    LOCK();
    unlink_chunk_node_locked(local_id);
    UNLOCK();
}

void nr_spool_wav_path(const char *local_id, char *out, size_t out_len)
{
    path_for('c', local_id, "wav", out, out_len);
}

bool nr_spool_borrow_wav(const char *local_id, const uint8_t **mem, size_t *len,
                         char *path, size_t path_len)
{
    LOCK();
    chunk_node_t *n = find_chunk(local_id);
    if (!n) { UNLOCK(); return false; }
    if (n->meta.on_disk) {
        if (mem) *mem = NULL;
        path_for('c', local_id, "wav", path, path_len);
    } else {
        if (mem) *mem = n->mem;
        if (path && path_len) path[0] = '\0';
    }
    if (len) *len = n->meta.byte_size;
    UNLOCK();
    return true;
}

void nr_spool_for_each_chunk(nr_chunk_iter_fn fn, void *ctx)
{
    LOCK();
    uint32_t count = 0;
    for (chunk_node_t *n = s_chunks; n; n = n->next) count++;
    nr_chunk_meta_t *snap = count ? malloc(count * sizeof(*snap)) : NULL;
    uint32_t i = 0;
    if (snap) for (chunk_node_t *n = s_chunks; n && i < count; n = n->next) snap[i++] = n->meta;
    UNLOCK();
    for (uint32_t k = 0; k < i; k++) if (!fn(&snap[k], ctx)) break;
    free(snap);
}

// ---- sessions --------------------------------------------------------------

esp_err_t nr_spool_put_session(const nr_session_rec_t *rec)
{
    char js[160]; path_for('s', rec->id, "js", js, sizeof(js));
    char *s = session_to_json(rec);
    if (!s) return ESP_ERR_NO_MEM;
    esp_err_t err = write_atomic(js, s, strlen(s));
    free(s);
    if (err != ESP_OK) return err;
    LOCK();
    session_node_t *n = s_sessions;
    while (n && strcmp(n->rec.id, rec->id) != 0) n = n->next;
    if (!n) { n = calloc(1, sizeof(*n)); if (n) { n->next = s_sessions; s_sessions = n; } }
    if (n) n->rec = *rec;
    UNLOCK();
    return n ? ESP_OK : ESP_ERR_NO_MEM;
}

bool nr_spool_get_session(const char *id, nr_session_rec_t *out)
{
    LOCK();
    session_node_t *n = s_sessions;
    while (n && strcmp(n->rec.id, id) != 0) n = n->next;
    if (n && out) *out = n->rec;
    bool found = n != NULL;
    UNLOCK();
    return found;
}

void nr_spool_delete_session(const char *id)
{
    char js[160]; path_for('s', id, "js", js, sizeof(js)); remove(js);
    LOCK();
    session_node_t **pp = &s_sessions;
    while (*pp) {
        if (strcmp((*pp)->rec.id, id) == 0) { session_node_t *d = *pp; *pp = d->next; free(d); break; }
        pp = &(*pp)->next;
    }
    UNLOCK();
}

void nr_spool_for_each_session(nr_session_iter_fn fn, void *ctx)
{
    LOCK();
    uint32_t count = 0;
    for (session_node_t *n = s_sessions; n; n = n->next) count++;
    nr_session_rec_t *snap = count ? malloc(count * sizeof(*snap)) : NULL;
    uint32_t i = 0;
    if (snap) for (session_node_t *n = s_sessions; n && i < count; n = n->next) snap[i++] = n->rec;
    UNLOCK();
    for (uint32_t k = 0; k < i; k++) if (!fn(&snap[k], ctx)) break;
    free(snap);
}

// ---- gaps ------------------------------------------------------------------

esp_err_t nr_spool_put_gap(const nr_gap_rec_t *rec)
{
    char js[160]; path_for('g', rec->id, "js", js, sizeof(js));
    char *s = gap_to_json(rec);
    if (!s) return ESP_ERR_NO_MEM;
    esp_err_t err = write_atomic(js, s, strlen(s));
    free(s);
    if (err != ESP_OK) return err;
    LOCK();
    gap_node_t *n = s_gaps;
    while (n && strcmp(n->rec.id, rec->id) != 0) n = n->next;
    if (!n) { n = calloc(1, sizeof(*n)); if (n) { n->next = s_gaps; s_gaps = n; } }
    if (n) n->rec = *rec;
    UNLOCK();
    return n ? ESP_OK : ESP_ERR_NO_MEM;
}

void nr_spool_delete_gap(const char *id)
{
    char js[160]; path_for('g', id, "js", js, sizeof(js)); remove(js);
    LOCK();
    gap_node_t **pp = &s_gaps;
    while (*pp) {
        if (strcmp((*pp)->rec.id, id) == 0) { gap_node_t *d = *pp; *pp = d->next; free(d); break; }
        pp = &(*pp)->next;
    }
    UNLOCK();
}

void nr_spool_for_each_gap(nr_gap_iter_fn fn, void *ctx)
{
    LOCK();
    uint32_t count = 0;
    for (gap_node_t *n = s_gaps; n; n = n->next) count++;
    nr_gap_rec_t *snap = count ? malloc(count * sizeof(*snap)) : NULL;
    uint32_t i = 0;
    if (snap) for (gap_node_t *n = s_gaps; n && i < count; n = n->next) snap[i++] = n->rec;
    UNLOCK();
    for (uint32_t k = 0; k < i; k++) if (!fn(&snap[k], ctx)) break;
    free(snap);
}

// ---- stats / capacity ------------------------------------------------------

void nr_spool_stats(nr_spool_stats_t *out)
{
    memset(out, 0, sizeof(*out));
    LOCK();
    for (chunk_node_t *n = s_chunks; n; n = n->next) {
        out->chunk_count++;
        out->bytes_used += n->meta.byte_size;
        if (!n->meta.on_disk) out->bytes_in_ram += n->meta.byte_size;
        if (n->meta.state == NR_CHUNK_NEEDS_ATTENTION) out->needs_attention++;
        else if (n->meta.state != NR_CHUNK_UPLOADED && n->meta.state != NR_CHUNK_TERMINAL) out->pending_upload++;
    }
    out->cap_bytes = s_cap_bytes;
    UNLOCK();
}

bool nr_spool_enforce_cap(nr_spool_drop_t *dropped)
{
    bool did = false;
    LOCK();
    uint64_t total = 0;
    for (chunk_node_t *n = s_chunks; n; n = n->next) total += n->meta.byte_size;
    if (total > s_cap_bytes) {
        chunk_node_t *oldest = NULL;
        for (chunk_node_t *n = s_chunks; n; n = n->next) {
            if (n->meta.state == NR_CHUNK_TERMINAL) continue;
            if (n->meta.state == NR_CHUNK_UPLOADING) continue;   // in flight; don't free its bytes
            if (!oldest || n->meta.created_monotonic_ms < oldest->meta.created_monotonic_ms) oldest = n;
        }
        if (oldest) {
            if (dropped) {
                nr_strlcpy(dropped->session_id, oldest->meta.session_id, NR_UUID_LEN);
                nr_strlcpy(dropped->source_id, oldest->meta.source_id, NR_UUID_LEN);
                dropped->start_offset_ms = oldest->meta.monotonic_offset_ms;
                dropped->end_offset_ms = oldest->meta.monotonic_offset_ms + oldest->meta.duration_ms;
                dropped->sequence = (int32_t) oldest->meta.sequence;
            }
            ESP_LOGW(TAG, "cap exceeded (%llu>%llu): dropping oldest chunk seq %u",
                     (unsigned long long) total, (unsigned long long) s_cap_bytes, oldest->meta.sequence);
            char id[NR_UUID_LEN]; nr_strlcpy(id, oldest->meta.local_id, sizeof(id));
            unlink_chunk_node_locked(id);
            did = true;
        }
    }
    UNLOCK();
    return did;
}
