// SPDX-License-Identifier: MIT
// Durable spool for the reliability invariant.
//
// Everything the panel captures is held here until the backend proves a
// terminal transcript receipt; only then is the audio released and freed.
//
// This board has NO SD card and only 16 MB of NOR flash, so writing ~1.9 MB/min
// of PCM to flash 24/7 would wear it out. The spool is therefore MEMORY-FIRST:
//   * Fresh chunks live in PSRAM (zero flash writes) and, in the common case of
//     a healthy network, are uploaded and freed straight from RAM.
//   * When PSRAM pressure builds (backend slow, or the link is down) the oldest
//     in-RAM chunks SPILL to a LittleFS file so RAM is reclaimed and the audio
//     survives a reboot. Spilling only happens during backlog, so steady-state
//     flash wear is negligible.
//   * Session and gap records are tiny and always persisted to flash.
//
// Accepted, documented trade-off: audio that is still MEMORY-backed when power
// is cut is lost and its span is declared as a truthful device_shutdown gap on
// the next boot — the platform makes the same honest choice for mobile clients
// (see docs/docs/architecture.md). Everything already spilled to flash, and all
// session/gap bookkeeping, survives.

#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NR_LAYOUT_MAX 24

typedef enum {
    NR_CHUNK_READY = 0,       // needs upload (PUT)
    NR_CHUNK_UPLOADING,       // PUT in flight (crash-safe: idempotent retry)
    NR_CHUNK_UPLOADED,        // server accepted; poll /chunks/status
    NR_CHUNK_TERMINAL,        // transcribed/silent + audio deleted server-side
    NR_CHUNK_REUPLOAD,        // server asked for the bytes again
    NR_CHUNK_NEEDS_ATTENTION, // repeatedly un-transcribable; parked
    NR_CHUNK_FAILED,          // transient upload error; will retry
} nr_chunk_state_t;

typedef struct {
    char local_id[NR_UUID_LEN];         // Idempotency-Key sent to the server
    char server_chunk_id[NR_UUID_LEN];  // receipt.chunkId (empty until uploaded)
    char session_id[NR_UUID_LEN];
    char source_id[NR_UUID_LEN];
    uint32_t sequence;
    int64_t  monotonic_offset_ms;       // position within the session timeline
    uint32_t duration_ms;
    uint32_t overlap_ms;
    char channel_layout[NR_LAYOUT_MAX]; // "mono"
    char sha256[65];
    uint32_t byte_size;                 // WAV size in bytes
    bool is_final;
    nr_chunk_state_t state;
    uint8_t reupload_attempts;
    uint8_t fail_count;                 // consecutive transient upload failures
    int64_t next_attempt_mono_ms;       // 0 = eligible now (not durable; rebuilt after reboot)
    bool on_disk;                       // true once spilled to LittleFS
    bool has_payload;                   // false after WAV freed post-upload (meta only)
    int64_t created_monotonic_ms;       // for age-ordered spill/drop
    int64_t uploaded_monotonic_ms;      // when state first became UPLOADED (0 if not)
} nr_chunk_meta_t;

typedef struct {
    char id[NR_UUID_LEN];
    char source_id[NR_UUID_LEN];
    char timezone[64];                  // IANA name for the session
    int64_t start_epoch_ms;             // 0 until the wall clock is known
    int64_t start_monotonic_ms;         // to back-compute start_epoch after NTP
    uint32_t sample_rate;               // 16000
    bool synced;                        // device + session declared on server
    bool ended;                         // capture finished; close should be sent
    bool close_synced;                  // PATCH close acknowledged
    bool interrupted;                   // close status: interrupted vs ended
    int32_t final_sequence;             // last sequence, -1 while open
    uint8_t declare_fail_count;         // consecutive POST /sessions failures
} nr_session_rec_t;

typedef struct {
    char id[NR_UUID_LEN];
    char session_id[NR_UUID_LEN];
    char source_id[NR_UUID_LEN];
    int64_t start_offset_ms;
    int64_t end_offset_ms;
    int32_t start_sequence;             // -1 when unknown
    int32_t end_sequence;               // -1 when unknown
    nr_gap_reason_t reason;
    bool synced;
} nr_gap_rec_t;

// Bring the spool up: create the directory, discard incomplete files, load
// disk-backed chunks/sessions/gaps into the RAM index.
//   mem_budget_bytes  soft cap on RAM held by memory-backed chunks; exceeding it
//                     spills the oldest to flash.
//   cap_bytes         hard cap on total retained audio; exceeding it drops the
//                     oldest non-terminal chunk (caller declares storage_full).
esp_err_t nr_spool_init(const char *dir, size_t mem_budget_bytes, uint64_t cap_bytes);

const char *nr_spool_dir(void);

// --- Chunks -----------------------------------------------------------------

// Persist a new chunk. wav points at a complete RIFF/WAVE buffer of wav_len
// bytes; the spool copies it into PSRAM (spilling older chunks first if needed).
esp_err_t nr_spool_put_chunk(const nr_chunk_meta_t *meta, const void *wav, size_t wav_len);

bool nr_spool_get_chunk(const char *local_id, nr_chunk_meta_t *out);
esp_err_t nr_spool_update_chunk(const nr_chunk_meta_t *meta);
void nr_spool_delete_chunk(const char *local_id);

// Access a chunk's WAV bytes for upload. For memory-backed chunks this returns a
// borrowed pointer valid until the next spool mutation on that chunk; for
// disk-backed chunks it returns NULL and fills path so the caller streams the
// file. Exactly one of (*mem) / path is produced. Returns false when the
// payload was already released (post-upload meta-only retention).
bool nr_spool_borrow_wav(const char *local_id, const uint8_t **mem, size_t *len,
                         char *path, size_t path_len);

// Free the WAV payload after a successful upload. Metadata is retained so the
// pump can still poll terminal receipts; a later reupload_required without
// bytes is treated as unrecoverable on this board (no durable storage).
esp_err_t nr_spool_release_payload(const char *local_id);

// Snapshot-iterate chunk metadata (ordered by created time). The callback runs
// WITHOUT the spool lock held, so it may call back into the spool safely.
// Return false from the callback to stop early.
typedef bool (*nr_chunk_iter_fn)(const nr_chunk_meta_t *meta, void *ctx);
void nr_spool_for_each_chunk(nr_chunk_iter_fn fn, void *ctx);

// --- Sessions ---------------------------------------------------------------

esp_err_t nr_spool_put_session(const nr_session_rec_t *rec);
bool nr_spool_get_session(const char *id, nr_session_rec_t *out);
void nr_spool_delete_session(const char *id);
typedef bool (*nr_session_iter_fn)(const nr_session_rec_t *rec, void *ctx);
void nr_spool_for_each_session(nr_session_iter_fn fn, void *ctx);

// --- Gaps -------------------------------------------------------------------

esp_err_t nr_spool_put_gap(const nr_gap_rec_t *rec);
void nr_spool_delete_gap(const char *id);
typedef bool (*nr_gap_iter_fn)(const nr_gap_rec_t *rec, void *ctx);
void nr_spool_for_each_gap(nr_gap_iter_fn fn, void *ctx);

// --- Stats / capacity -------------------------------------------------------

typedef struct {
    uint32_t chunk_count;
    uint32_t pending_upload;    // READY/FAILED/UPLOADING with payload still to send
    uint32_t awaiting_receipt;  // UPLOADED, polling for terminal
    uint32_t needs_attention;
    uint64_t bytes_used;        // sum of retained WAV payload sizes (RAM + disk)
    uint64_t bytes_in_ram;
    uint64_t cap_bytes;
} nr_spool_stats_t;

void nr_spool_stats(nr_spool_stats_t *out);

// Enforce the hard cap: if over, drop the oldest non-terminal chunk and return
// its timeline range so the recorder can declare a storage_full gap.
typedef struct {
    char session_id[NR_UUID_LEN];
    char source_id[NR_UUID_LEN];
    int64_t start_offset_ms;
    int64_t end_offset_ms;
    int32_t sequence;
} nr_spool_drop_t;
bool nr_spool_enforce_cap(nr_spool_drop_t *dropped);

#ifdef __cplusplus
}
#endif
