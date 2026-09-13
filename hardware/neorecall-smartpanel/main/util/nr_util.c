// SPDX-License-Identifier: MIT
#include "nr_util.h"

#include <string.h>
#include <stdio.h>

#include "esp_random.h"
#include "mbedtls/sha256.h"

void nr_uuid_v4(char out[NR_UUID_LEN])
{
    uint8_t b[16];
    esp_fill_random(b, sizeof(b));
    b[6] = (uint8_t) ((b[6] & 0x0F) | 0x40);  // version 4
    b[8] = (uint8_t) ((b[8] & 0x3F) | 0x80);  // variant 1
    static const char *hex = "0123456789abcdef";
    char *p = out;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) *p++ = '-';
        *p++ = hex[b[i] >> 4];
        *p++ = hex[b[i] & 0x0F];
    }
    *p = '\0';
}

static void to_hex(const uint8_t *digest, size_t n, char *out)
{
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = hex[digest[i] >> 4];
        out[i * 2 + 1] = hex[digest[i] & 0x0F];
    }
    out[n * 2] = '\0';
}

void nr_sha256_hex(const void *data, size_t len, char out[65])
{
    uint8_t digest[32];
    mbedtls_sha256((const unsigned char *) data, len, digest, 0 /* SHA-256, not 224 */);
    to_hex(digest, 32, out);
}

struct nr_sha256_ctx {
    mbedtls_sha256_context md;
};

nr_sha256_ctx *nr_sha256_begin(void)
{
    nr_sha256_ctx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    mbedtls_sha256_init(&ctx->md);
    if (mbedtls_sha256_starts(&ctx->md, 0) != 0) {
        mbedtls_sha256_free(&ctx->md);
        free(ctx);
        return NULL;
    }
    return ctx;
}

void nr_sha256_update(nr_sha256_ctx *ctx, const void *data, size_t len)
{
    if (ctx && len) mbedtls_sha256_update(&ctx->md, (const unsigned char *) data, len);
}

void nr_sha256_finish_hex(nr_sha256_ctx *ctx, char out[65])
{
    if (!ctx) { out[0] = '\0'; return; }
    uint8_t digest[32];
    mbedtls_sha256_finish(&ctx->md, digest);
    mbedtls_sha256_free(&ctx->md);
    free(ctx);
    to_hex(digest, 32, out);
}

bool nr_strlcpy(char *dst, const char *src, size_t size)
{
    if (!dst || size == 0) return false;
    if (!src) src = "";
    size_t n = strlen(src);
    size_t copy = n < size - 1 ? n : size - 1;
    memcpy(dst, src, copy);
    dst[copy] = '\0';
    return copy == n;
}

bool nr_strlcat(char *dst, const char *src, size_t size)
{
    if (!dst || size == 0) return false;
    if (!src) src = "";
    size_t used = strlen(dst);
    if (used >= size) {
        dst[size - 1] = '\0';
        return false;
    }
    return nr_strlcpy(dst + used, src, size - used);
}

size_t nr_html_escape(char *dst, size_t size, const char *src)
{
    if (!dst || size == 0) return 0;
    dst[0] = '\0';
    if (!src) src = "";
    size_t used = 0;
    for (const unsigned char *p = (const unsigned char *) src; *p; p++) {
        const char *rep = NULL;
        char one[2] = { (char) *p, 0 };
        switch (*p) {
            case '&':  rep = "&amp;"; break;
            case '<':  rep = "&lt;"; break;
            case '>':  rep = "&gt;"; break;
            case '"':  rep = "&quot;"; break;
            case '\'': rep = "&#39;"; break;
            default:   rep = one; break;
        }
        size_t n = strlen(rep);
        if (used + n + 1 > size) {
            dst[used] = '\0';
            return used;
        }
        memcpy(dst + used, rep, n);
        used += n;
    }
    dst[used] = '\0';
    return used;
}

size_t nr_json_escape(char *dst, size_t size, const char *src)
{
    if (!dst || size == 0) return 0;
    dst[0] = '\0';
    if (!src) src = "";
    size_t used = 0;
    for (const unsigned char *p = (const unsigned char *) src; *p; p++) {
        char buf[8];
        const char *rep;
        if (*p == '"' || *p == '\\') {
            buf[0] = '\\'; buf[1] = (char) *p; buf[2] = 0;
            rep = buf;
        } else if (*p < 0x20) {
            snprintf(buf, sizeof(buf), "\\u%04x", *p);
            rep = buf;
        } else {
            buf[0] = (char) *p; buf[1] = 0;
            rep = buf;
        }
        size_t n = strlen(rep);
        if (used + n + 1 > size) {
            dst[used] = '\0';
            return used;
        }
        memcpy(dst + used, rep, n);
        used += n;
    }
    dst[used] = '\0';
    return used;
}
