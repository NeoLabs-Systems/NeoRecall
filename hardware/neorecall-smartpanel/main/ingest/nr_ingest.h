// SPDX-License-Identifier: MIT
// The upload pump: drives the durable spool to the NeoRecall backend using the
// exact /api/v1 ingest protocol the Flutter client uses. It registers the
// device, declares sessions, uploads WAV chunks with idempotency + SHA-256,
// polls for terminal receipts, releases audio only once the server proves the
// transcript is persisted and its copy deleted, and declares capture gaps.
//
// The pump is a single supervised task. It is safe to "kick" from any task to
// ask for an immediate cycle (e.g. when a new chunk lands or the link returns).
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool provisioned;
    bool device_registered;
    bool server_reachable;
    uint32_t pending_upload;
    uint32_t needs_attention;
    uint64_t backlog_bytes;
    uint64_t backlog_ram_bytes;
    int64_t last_receipt_epoch_ms;   // last terminal/accepted receipt
    int last_http_status;
    char last_error[96];
} nr_ingest_status_t;

// Start the pump task. Requires nr_spool_init + nr_config_init done first.
esp_err_t nr_ingest_init(void);

// Ask the pump to run a cycle as soon as possible.
void nr_ingest_kick(void);

// Snapshot pump status for the UI.
void nr_ingest_get_status(nr_ingest_status_t *out);

#ifdef __cplusplus
}
#endif
