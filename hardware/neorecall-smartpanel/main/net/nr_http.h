// SPDX-License-Identifier: MIT
// Thin, robust wrapper over esp_http_client used by every network module.
// Handles TLS (verified via the bundled Mozilla root store, or explicitly
// insecure for self-hosted/self-signed backends), body accumulation, and a
// streaming multipart PUT that never buffers a whole audio chunk twice.
#pragma once

#include "nr_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { const char *key; const char *value; } nr_http_header_t;

typedef struct {
    int status;        // HTTP status code, or -1 on transport failure
    char *body;        // malloc'd, null-terminated (caller frees); may be NULL
    size_t body_len;
} nr_http_result_t;

void nr_http_result_free(nr_http_result_t *r);

// Generic request. method is "GET"/"POST"/"PATCH"/... . body/body_len is an
// optional request body (JSON); content_type/bearer are optional. extra headers
// is an optional array of nheaders {key,value}. Returns ESP_OK when a response
// (any status) was received; the HTTP status is in out->status.
esp_err_t nr_http_request(const char *method, const char *url,
                          const char *content_type,
                          const void *body, size_t body_len,
                          const char *bearer,
                          const nr_http_header_t *headers, size_t nheaders,
                          bool tls_insecure, int timeout_ms,
                          nr_http_result_t *out);

// Convenience GET returning the body (used by weather/geolocation).
esp_err_t nr_http_get(const char *url, bool tls_insecure, int timeout_ms, nr_http_result_t *out);

// Stream a NeoRecall audio chunk as a multipart/form-data PUT. Exactly one of
// mem / file_path supplies the WAV bytes (wav_len total). The multipart envelope
// is generated internally; `headers` carries the ingest metadata headers.
esp_err_t nr_http_put_wav_multipart(const char *url, const char *bearer,
                                    const nr_http_header_t *headers, size_t nheaders,
                                    const uint8_t *mem, const char *file_path, size_t wav_len,
                                    const char *filename,
                                    bool tls_insecure, int timeout_ms,
                                    nr_http_result_t *out);

#ifdef __cplusplus
}
#endif
