// SPDX-License-Identifier: MIT
#include "nr_http.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <strings.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "esp_random.h"

#include "nr_common.h"
#include "net/nr_time.h"

static const char *TAG = "nr_http";

#define NR_HTTP_MAX_BODY (24 * 1024)   // JSON responses are small; guard RAM
#define NR_HTTP_AUTH_MAX 200           // "Bearer " + api key / session token + NUL

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
    bool overflow;
} body_acc_t;

void nr_http_result_free(nr_http_result_t *r)
{
    if (r && r->body) { free(r->body); r->body = NULL; }
    if (r) r->body_len = 0;
}

static esp_err_t on_event(esp_http_client_event_t *e)
{
    // Seed the wall clock from the server's Date header the moment any response
    // arrives, so the UI shows the time without waiting out a slow SNTP sync.
    if (e->event_id == HTTP_EVENT_ON_HEADER) {
        if (e->header_key && strcasecmp(e->header_key, "Date") == 0)
            nr_time_seed_from_http_date(e->header_value);
        return ESP_OK;
    }
    if (e->event_id != HTTP_EVENT_ON_DATA || !e->user_data) return ESP_OK;
    body_acc_t *a = e->user_data;
    if (a->overflow) return ESP_OK;
    if (a->len + e->data_len + 1 > NR_HTTP_MAX_BODY) { a->overflow = true; return ESP_OK; }
    if (a->len + e->data_len + 1 > a->cap) {
        size_t ncap = a->cap ? a->cap * 2 : 1024;
        while (ncap < a->len + e->data_len + 1) ncap *= 2;
        char *nb = realloc(a->buf, ncap);
        if (!nb) { a->overflow = true; return ESP_OK; }
        a->buf = nb; a->cap = ncap;
    }
    memcpy(a->buf + a->len, e->data, e->data_len);
    a->len += e->data_len;
    a->buf[a->len] = '\0';
    return ESP_OK;
}

static void configure_tls(esp_http_client_config_t *cfg, const char *url, bool insecure)
{
    if (strncmp(url, "https://", 8) == 0) {
        if (insecure) {
            // No CA bundle => esp-tls uses MBEDTLS_SSL_VERIFY_NONE (no verification).
            // Deliberately do NOT set skip_cert_common_name_check: in esp-tls that
            // flag also clears SNI (mbedtls_ssl_set_hostname(NULL)), and SNI-strict
            // frontends — e.g. an ECDSA vhost behind a reverse proxy — reject a
            // no-SNI ClientHello with a fatal handshake_failure alert (-0x7780).
            cfg->crt_bundle_attach = NULL;
        } else {
            cfg->crt_bundle_attach = esp_crt_bundle_attach;  // Mozilla root store
        }
    }
}

esp_err_t nr_http_request(const char *method, const char *url,
                          const char *content_type,
                          const void *body, size_t body_len,
                          const char *bearer,
                          const nr_http_header_t *headers, size_t nheaders,
                          bool tls_insecure, int timeout_ms,
                          nr_http_result_t *out)
{
    if (out) { out->status = -1; out->body = NULL; out->body_len = 0; }
    body_acc_t acc = {0};

    esp_http_client_config_t cfg = {
        .url = url,
        .timeout_ms = timeout_ms > 0 ? timeout_ms : 20000,
        .event_handler = on_event,
        .user_data = &acc,
        .buffer_size = 4096,
        .buffer_size_tx = 4096,
        .keep_alive_enable = false,
    };
    configure_tls(&cfg, url, tls_insecure);

    esp_http_client_handle_t c = esp_http_client_init(&cfg);
    if (!c) return ESP_FAIL;

    esp_http_client_method_t m = HTTP_METHOD_GET;
    if (!strcmp(method, "POST")) m = HTTP_METHOD_POST;
    else if (!strcmp(method, "PUT")) m = HTTP_METHOD_PUT;
    else if (!strcmp(method, "PATCH")) m = HTTP_METHOD_PATCH;
    else if (!strcmp(method, "DELETE")) m = HTTP_METHOD_DELETE;
    esp_http_client_set_method(c, m);

    esp_http_client_set_header(c, "Accept", "application/json");
    esp_http_client_set_header(c, "User-Agent", "NeoRecall-SmartPanel/" NR_FIRMWARE_VERSION);
    if (bearer) {
        char auth[NR_HTTP_AUTH_MAX];
        snprintf(auth, sizeof(auth), "Bearer %s", bearer);
        esp_http_client_set_header(c, "Authorization", auth);
    }
    if (content_type) esp_http_client_set_header(c, "Content-Type", content_type);
    for (size_t i = 0; i < nheaders; i++) esp_http_client_set_header(c, headers[i].key, headers[i].value);
    if (body && body_len) esp_http_client_set_post_field(c, (const char *) body, body_len);

    // One automatic retry for pure transport blips (DNS, handshake, reset). A
    // response that already carried a status code is never retried here.
    esp_err_t err = ESP_FAIL;
    for (int attempt = 0; attempt < 2; attempt++) {
        free(acc.buf); acc.buf = NULL; acc.len = 0; acc.cap = 0; acc.overflow = false;
        err = esp_http_client_perform(c);
        if (err == ESP_OK) break;
        ESP_LOGW(TAG, "%s %s attempt %d failed: %s", method, url, attempt + 1, esp_err_to_name(err));
        if (attempt == 0) vTaskDelay(pdMS_TO_TICKS(400 + (esp_random() % 400)));
    }

    if (err == ESP_OK) {
        if (out) {
            out->status = esp_http_client_get_status_code(c);
            out->body = acc.buf;              // hand ownership to caller
            out->body_len = acc.len;
            acc.buf = NULL;
        }
        if (acc.overflow) ESP_LOGW(TAG, "response body truncated for %s", url);
    } else {
        free(acc.buf);
    }
    esp_http_client_cleanup(c);
    return err;
}

esp_err_t nr_http_get(const char *url, bool tls_insecure, int timeout_ms, nr_http_result_t *out)
{
    return nr_http_request("GET", url, NULL, NULL, 0, NULL, NULL, 0, tls_insecure, timeout_ms, out);
}

// ---- streaming multipart WAV PUT ------------------------------------------

#define NR_BOUNDARY "----NeoRecallBoundary7f3a"

esp_err_t nr_http_put_wav_multipart(const char *url, const char *bearer,
                                    const nr_http_header_t *headers, size_t nheaders,
                                    const uint8_t *mem, const char *file_path, size_t wav_len,
                                    const char *filename,
                                    bool tls_insecure, int timeout_ms,
                                    nr_http_result_t *out)
{
    if (out) { out->status = -1; out->body = NULL; out->body_len = 0; }
    if ((mem == NULL) == (file_path == NULL || file_path[0] == '\0')) return ESP_ERR_INVALID_ARG;

    char preamble[320];
    int pre = snprintf(preamble, sizeof(preamble),
        "--" NR_BOUNDARY "\r\n"
        "Content-Disposition: form-data; name=\"audio\"; filename=\"%s\"\r\n"
        "Content-Type: audio/wav\r\n\r\n", filename);
    static const char epilogue[] = "\r\n--" NR_BOUNDARY "--\r\n";
    int epi = (int) sizeof(epilogue) - 1;
    int content_len = pre + (int) wav_len + epi;

    // Scale timeout with payload size: ~1 MB of PCM on a weak link needs more
    // than a fixed 30 s budget. Floor at 60 s, then +1 s per 32 KiB.
    int auto_to = 60000 + (int) ((wav_len / 32768u) * 1000u);
    if (auto_to > 180000) auto_to = 180000;
    if (timeout_ms > 0 && timeout_ms > auto_to) auto_to = timeout_ms;

    body_acc_t acc = {0};
    esp_http_client_config_t cfg = {
        .url = url,
        .method = HTTP_METHOD_PUT,
        .timeout_ms = auto_to,
        .event_handler = on_event,
        .user_data = &acc,
        .buffer_size = 4096,
        .buffer_size_tx = 4096,
        .keep_alive_enable = false,
    };
    configure_tls(&cfg, url, tls_insecure);
    esp_http_client_handle_t c = esp_http_client_init(&cfg);
    if (!c) return ESP_FAIL;

    esp_http_client_set_header(c, "Content-Type", "multipart/form-data; boundary=" NR_BOUNDARY);
    esp_http_client_set_header(c, "Accept", "application/json");
    esp_http_client_set_header(c, "User-Agent", "NeoRecall-SmartPanel/" NR_FIRMWARE_VERSION);
    if (bearer) {
        char auth[NR_HTTP_AUTH_MAX];
        snprintf(auth, sizeof(auth), "Bearer %s", bearer);
        esp_http_client_set_header(c, "Authorization", auth);
    }
    for (size_t i = 0; i < nheaders; i++) esp_http_client_set_header(c, headers[i].key, headers[i].value);

    esp_err_t err = esp_http_client_open(c, content_len);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PUT open failed: %s", esp_err_to_name(err));
        esp_http_client_cleanup(c);
        free(acc.buf);
        return err;
    }

    FILE *f = NULL;
    uint8_t *iobuf = NULL;
    err = ESP_FAIL;

    if (esp_http_client_write(c, preamble, pre) != pre) {
        ESP_LOGW(TAG, "PUT preamble write short");
        goto done;
    }

    if (mem) {
        size_t off = 0;
        while (off < wav_len) {
            int chunk = (int) (wav_len - off > 4096 ? 4096 : wav_len - off);
            int w = esp_http_client_write(c, (const char *) mem + off, chunk);
            if (w <= 0) {
                ESP_LOGW(TAG, "PUT body write failed at %u/%u", (unsigned) off, (unsigned) wav_len);
                goto done;
            }
            off += w;
        }
    } else {
        f = fopen(file_path, "rb");
        if (!f) {
            ESP_LOGW(TAG, "PUT open file failed: %s", file_path);
            goto done;
        }
        iobuf = malloc(4096);
        if (!iobuf) goto done;
        size_t remaining = wav_len;
        while (remaining > 0) {
            size_t want = remaining > 4096 ? 4096 : remaining;
            size_t rd = fread(iobuf, 1, want, f);
            if (rd == 0) {
                ESP_LOGW(TAG, "PUT file read short (remaining %u)", (unsigned) remaining);
                goto done;
            }
            size_t off = 0;
            while (off < rd) {
                int w = esp_http_client_write(c, (const char *) iobuf + off, (int) (rd - off));
                if (w <= 0) {
                    ESP_LOGW(TAG, "PUT file body write failed");
                    goto done;
                }
                off += w;
            }
            remaining -= rd;
        }
    }

    if (esp_http_client_write(c, epilogue, epi) != epi) {
        ESP_LOGW(TAG, "PUT epilogue write short");
        goto done;
    }

    int hdrs = esp_http_client_fetch_headers(c);
    if (hdrs < 0) {
        ESP_LOGW(TAG, "PUT fetch_headers failed");
        goto done;
    }
    if (out) {
        out->status = esp_http_client_get_status_code(c);
        // Prefer the event-handler accumulator (handles chunked encodings). Fall
        // back to a manual read when the handler saw nothing.
        if (acc.buf && acc.len) {
            out->body = acc.buf;
            out->body_len = acc.len;
            acc.buf = NULL;
        } else {
            int clen = esp_http_client_get_content_length(c);
            size_t cap = (clen > 0 && clen < NR_HTTP_MAX_BODY) ? (size_t) clen + 1 : 4096;
            out->body = malloc(cap);
            if (out->body) {
                size_t total = 0;
                while (total + 1 < cap) {
                    int r = esp_http_client_read(c, out->body + total, (int) (cap - 1 - total));
                    if (r <= 0) break;
                    total += r;
                }
                out->body[total] = '\0';
                out->body_len = total;
            }
        }
    }
    err = ESP_OK;

done:
    if (f) fclose(f);
    free(iobuf);
    free(acc.buf);
    esp_http_client_close(c);
    esp_http_client_cleanup(c);
    return err;
}
