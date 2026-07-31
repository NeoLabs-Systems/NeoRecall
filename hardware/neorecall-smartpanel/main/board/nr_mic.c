// SPDX-License-Identifier: MIT
// Microphone capture for the ESP32-S3-Touch-LCD-4B: two analog MEMS mics feed an
// ES7210 4-channel ADC (I2C 0x40), whose I2S output (MIC1=L, MIC2=R on SDOUT1)
// arrives on the ESP32 I2S RX line. We configure the ES7210 with the exact
// register sequence from Espressif's driver, run I2S as master at 16 kHz, and
// downmix the two mic channels to the mono stream NeoRecall ingests.
#include "nr_mic.h"

#include <string.h>

#include "driver/i2c.h"
#include "driver/i2s_std.h"
#include "esp_log.h"

#include "board/board_config.h"

static const char *TAG = "nr_mic";

#define ES7210_MIC_GAIN 0x0A   // PGA gain code (~+30 dB); tune for the room
#define STEREO_SCRATCH  512    // frames per I2S read

static i2s_chan_handle_t s_rx;
static bool s_running;
static int16_t s_scratch[STEREO_SCRATCH * 2];

// ---- ES7210 over I2C -------------------------------------------------------

static esp_err_t es_w(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = { reg, val };
    return i2c_master_write_to_device(BRD_I2C_PORT, BRD_ADDR_ES7210, b, 2, pdMS_TO_TICKS(100));
}

static esp_err_t es_r(uint8_t reg, uint8_t *val)
{
    return i2c_master_write_read_device(BRD_I2C_PORT, BRD_ADDR_ES7210, &reg, 1, val, 1, pdMS_TO_TICKS(100));
}

static esp_err_t es7210_configure(void)
{
    // Reset
    esp_err_t e = es_w(0x00, 0xFF);
    if (e != ESP_OK) { ESP_LOGE(TAG, "ES7210 not responding: %s", esp_err_to_name(e)); return e; }
    es_w(0x00, 0x32);
    es_w(0x09, 0x30);            // power-up timing
    es_w(0x0A, 0x30);
    es_w(0x23, 0x2A);            // ADC12 HPF
    es_w(0x22, 0x0A);
    es_w(0x21, 0x2A);            // ADC34 HPF
    es_w(0x20, 0x0A);

    // I2S secondary (slave) mode: clear bit0 of mode-config reg 0x08.
    uint8_t mode = 0;
    if (es_r(0x08, &mode) == ESP_OK) es_w(0x08, mode & ~0x01);

    es_w(0x11, 0x60);            // SDP1: 16-bit
    es_w(0x12, 0x00);            // SDP2: non-TDM (MIC1/2 -> SDOUT1)
    es_w(0x40, 0xC3);            // analog power / VMID
    es_w(0x41, 0x70);            // MIC1-2 bias
    es_w(0x42, 0x70);            // MIC3-4 bias
    es_w(0x43, 0x10 | ES7210_MIC_GAIN);   // per-mic PGA enable + gain
    es_w(0x44, 0x10 | ES7210_MIC_GAIN);
    es_w(0x45, 0x10 | ES7210_MIC_GAIN);
    es_w(0x46, 0x10 | ES7210_MIC_GAIN);
    es_w(0x47, 0x08);            // power on MIC1..4
    es_w(0x48, 0x08);
    es_w(0x49, 0x08);
    es_w(0x4A, 0x08);
    // Clocking for MCLK 4.096 MHz / LRCK 16 kHz
    es_w(0x07, 0x20);            // OSR
    es_w(0x02, 0xC1);            // adc_div | doubler<<6 | dll<<7
    es_w(0x04, 0x01);            // LRCK high byte
    es_w(0x05, 0x00);            // LRCK low byte
    es_w(0x06, 0x04);            // power down DLL
    es_w(0x4B, 0x0F);            // bias/ADC/PGA on
    es_w(0x4C, 0x0F);
    es_w(0x00, 0x71);            // enable
    es_w(0x00, 0x41);
    ESP_LOGI(TAG, "ES7210 configured (16 kHz, MIC1+MIC2)");
    return ESP_OK;
}

// ---- public API ------------------------------------------------------------

esp_err_t nr_mic_start(uint32_t sample_rate)
{
    if (s_running) return ESP_OK;

    if (!s_rx) {
        i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
        chan_cfg.dma_desc_num = 8;
        chan_cfg.dma_frame_num = 1000;    // ~500 ms of headroom across chunk writes
        chan_cfg.auto_clear = true;
        esp_err_t err = i2s_new_channel(&chan_cfg, NULL, &s_rx);
        if (err != ESP_OK) { ESP_LOGE(TAG, "i2s_new_channel: %s", esp_err_to_name(err)); return err; }

        i2s_std_config_t std = {
            .clk_cfg = {
                .sample_rate_hz = sample_rate,
                .clk_src = I2S_CLK_SRC_DEFAULT,
                .mclk_multiple = I2S_MCLK_MULTIPLE_256,
            },
            .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
            .gpio_cfg = {
                .mclk = BRD_I2S_MCLK,
                .bclk = BRD_I2S_BCLK,
                .ws   = BRD_I2S_WS,
                .dout = I2S_GPIO_UNUSED,
                .din  = BRD_I2S_DIN,
                .invert_flags = { 0 },
            },
        };
        err = i2s_channel_init_std_mode(s_rx, &std);
        if (err != ESP_OK) { ESP_LOGE(TAG, "i2s init std: %s", esp_err_to_name(err)); return err; }
    }

    esp_err_t err = i2s_channel_enable(s_rx);   // MCLK starts running here
    if (err != ESP_OK) { ESP_LOGE(TAG, "i2s enable: %s", esp_err_to_name(err)); return err; }

    if (es7210_configure() != ESP_OK) {
        i2s_channel_disable(s_rx);
        return ESP_FAIL;
    }
    s_running = true;
    return ESP_OK;
}

esp_err_t nr_mic_read(int16_t *dst, size_t max_samples, size_t *out_samples, uint32_t timeout_ms)
{
    *out_samples = 0;
    if (!s_running || !s_rx) return ESP_ERR_INVALID_STATE;

    size_t want = max_samples < STEREO_SCRATCH ? max_samples : STEREO_SCRATCH;
    size_t bytes_read = 0;
    esp_err_t err = i2s_channel_read(s_rx, s_scratch, want * 2 * sizeof(int16_t),
                                     &bytes_read, pdMS_TO_TICKS(timeout_ms));
    if (err == ESP_ERR_TIMEOUT) return ESP_OK;   // caller treats 0 samples as a benign timeout
    if (err != ESP_OK) return err;

    size_t frames = bytes_read / (2 * sizeof(int16_t));
    for (size_t i = 0; i < frames; i++) {
        int32_t l = s_scratch[i * 2];
        int32_t r = s_scratch[i * 2 + 1];
        dst[i] = (int16_t) ((l + r) / 2);        // downmix MIC1+MIC2 -> mono
    }
    *out_samples = frames;
    return ESP_OK;
}

void nr_mic_stop(void)
{
    if (s_rx && s_running) i2s_channel_disable(s_rx);
    s_running = false;
}
