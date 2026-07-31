// SPDX-License-Identifier: MIT
// Small self-contained helpers: UUIDv4, SHA-256 hex, safe string copy.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

// Write a random RFC-4122 v4 UUID string (lower-case, hyphenated) into out.
// out must hold at least NR_UUID_LEN bytes.
void nr_uuid_v4(char out[NR_UUID_LEN]);

// Lower-case hex SHA-256 of a memory buffer. out must hold 65 bytes.
void nr_sha256_hex(const void *data, size_t len, char out[65]);

// Streaming SHA-256 so we can hash a spooled WAV without loading it whole.
typedef struct nr_sha256_ctx nr_sha256_ctx;
nr_sha256_ctx *nr_sha256_begin(void);
void nr_sha256_update(nr_sha256_ctx *ctx, const void *data, size_t len);
void nr_sha256_finish_hex(nr_sha256_ctx *ctx, char out[65]);   // frees ctx

// strlcpy-style bounded copy that always null-terminates. Returns true when the
// whole source fit. Safe when dst == NULL or size == 0.
bool nr_strlcpy(char *dst, const char *src, size_t size);

// Clamp helpers used throughout the UI/config validation.
static inline int nr_clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline uint8_t nr_clampu8(int v) { return (uint8_t) nr_clampi(v, 0, 255); }

#ifdef __cplusplus
}
#endif
