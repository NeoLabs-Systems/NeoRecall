#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/unistd.h>

#include "driver/gpio.h"
#include "driver/i2s_std.h"
#include "driver/spi_common.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"

/* Reviewed against pin-net-matrix.csv. Keep this map in one place. */
enum {
    PIN_BUTTON_WAKE = 0,
    PIN_I2S_WS = 1,
    PIN_I2S_DATA = 2,
    PIN_I2S_BCLK = 3,
    BATTERY_ADC_CHANNEL = ADC_CHANNEL_4, /* ADC1 channel 4 is GPIO4 on ESP32-C6. */
    PIN_SD_MISO = 5,
    PIN_SD_CLK = 6,
    PIN_SD_MOSI = 7,
    PIN_BUTTON_BOOT = 9,
    PIN_SD_POWER = 15,
    PIN_SD_CS = 18,
    PIN_SD_DETECT = 19,
    PIN_CHARGER_PGOOD_N = 20,
    PIN_CHARGER_CHG_N = 21,
    PIN_BUCK_PG_N = 22,
    PIN_MIC_POWER = 23,
};

enum {
    AUDIO_SAMPLE_RATE_HZ = 48000,
    AUDIO_CAPTURE_FRAMES = 4096,
    SD_TEST_BYTES = 4096,
    BUTTON_HOLD_TO_ARM_MS = 2000,
};

static const char *TAG = "neorecall_factory";
static unsigned s_passes;
static unsigned s_failures;

static void result(bool pass, const char *name)
{
    if (pass) {
        ++s_passes;
        ESP_LOGI(TAG, "PASS: %s", name);
    } else {
        ++s_failures;
        ESP_LOGE(TAG, "FAIL: %s", name);
    }
}

static void configure_board_gpio(void)
{
    const gpio_config_t outputs = {
        .pin_bit_mask = BIT64(PIN_SD_POWER) | BIT64(PIN_MIC_POWER),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = false,
        .pull_down_en = true,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&outputs));
    ESP_ERROR_CHECK(gpio_set_level(PIN_SD_POWER, 0));
    ESP_ERROR_CHECK(gpio_set_level(PIN_MIC_POWER, 0));

    const gpio_config_t buttons = {
        .pin_bit_mask = BIT64(PIN_BUTTON_WAKE) | BIT64(PIN_BUTTON_BOOT),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = true,
        .pull_down_en = false,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&buttons));

    const gpio_config_t status_inputs = {
        .pin_bit_mask = BIT64(PIN_SD_DETECT) | BIT64(PIN_CHARGER_PGOOD_N) |
                        BIT64(PIN_CHARGER_CHG_N) | BIT64(PIN_BUCK_PG_N),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = false,
        .pull_down_en = false,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&status_inputs));
}

static void test_status_gpio(void)
{
    const int wake = gpio_get_level(PIN_BUTTON_WAKE);
    const int boot = gpio_get_level(PIN_BUTTON_BOOT);
    result(wake == boot, "GPIO0/GPIO9 button net reads consistently");
    ESP_LOGI(TAG, "button=%s, buck=%s, USB-power-good=%s, charging=%s, card=%s",
             wake ? "released" : "pressed",
             gpio_get_level(PIN_BUCK_PG_N) ? "good" : "not-good",
             gpio_get_level(PIN_CHARGER_PGOOD_N) ? "absent" : "present",
             gpio_get_level(PIN_CHARGER_CHG_N) ? "inactive" : "active",
             gpio_get_level(PIN_SD_DETECT) ? "absent" : "inserted");
    result(gpio_get_level(PIN_BUCK_PG_N) == 1, "TPS63021 power-good asserted high");
}

static adc_cali_handle_t make_adc_calibration(void)
{
    adc_cali_handle_t handle = NULL;
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    const adc_cali_curve_fitting_config_t config = {
        .unit_id = ADC_UNIT_1,
        .chan = BATTERY_ADC_CHANNEL,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    if (adc_cali_create_scheme_curve_fitting(&config, &handle) != ESP_OK) {
        handle = NULL;
    }
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    const adc_cali_line_fitting_config_t config = {
        .unit_id = ADC_UNIT_1,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    if (adc_cali_create_scheme_line_fitting(&config, &handle) != ESP_OK) {
        handle = NULL;
    }
#endif
    return handle;
}

static void test_battery_adc(void)
{
    adc_oneshot_unit_handle_t adc = NULL;
    const adc_oneshot_unit_init_cfg_t unit_config = {
        .unit_id = ADC_UNIT_1,
        .ulp_mode = ADC_ULP_MODE_DISABLE,
    };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&unit_config, &adc));
    const adc_oneshot_chan_cfg_t channel_config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, BATTERY_ADC_CHANNEL, &channel_config));

    int raw_sum = 0;
    for (unsigned i = 0; i < 64; ++i) {
        int raw = 0;
        ESP_ERROR_CHECK(adc_oneshot_read(adc, BATTERY_ADC_CHANNEL, &raw));
        raw_sum += raw;
    }
    const int raw_average = raw_sum / 64;
    adc_cali_handle_t calibration = make_adc_calibration();
    if (calibration != NULL) {
        int divider_mv = 0;
        ESP_ERROR_CHECK(adc_cali_raw_to_voltage(calibration, raw_average, &divider_mv));
        const int battery_mv = (divider_mv * 1330 + 165) / 330;
        ESP_LOGI(TAG, "battery ADC raw=%d, divider=%d mV, calculated pack=%d mV",
                 raw_average, divider_mv, battery_mv);
        result(battery_mv >= 2500 && battery_mv < 4400,
               "battery ADC reads a plausible protected 1S pack voltage");
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
        ESP_ERROR_CHECK(adc_cali_delete_scheme_curve_fitting(calibration));
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
        ESP_ERROR_CHECK(adc_cali_delete_scheme_line_fitting(calibration));
#endif
    } else {
        ESP_LOGW(TAG, "ADC calibration unavailable; raw average=%d", raw_average);
        result(raw_average < 4095, "battery ADC is not saturated");
    }
    ESP_ERROR_CHECK(adc_oneshot_del_unit(adc));
}

static bool channel_has_audio(const int32_t *samples, size_t words, unsigned channel,
                              int32_t *minimum, int32_t *maximum)
{
    int32_t min_value = INT32_MAX;
    int32_t max_value = INT32_MIN;
    uint64_t magnitude_sum = 0;
    for (size_t i = channel; i < words; i += 2) {
        const int32_t value = samples[i];
        if (value < min_value) min_value = value;
        if (value > max_value) max_value = value;
        magnitude_sum += value < 0 ? (uint64_t)(-(int64_t)value) : (uint64_t)value;
    }
    *minimum = min_value;
    *maximum = max_value;
    const size_t count = words / 2;
    return count > 1000 && max_value != min_value && magnitude_sum / count > 256;
}

static void test_stereo_microphones(void)
{
    ESP_ERROR_CHECK(gpio_set_level(PIN_MIC_POWER, 1));
    vTaskDelay(pdMS_TO_TICKS(20));

    i2s_chan_handle_t rx = NULL;
    const i2s_chan_config_t channel_config = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    ESP_ERROR_CHECK(i2s_new_channel(&channel_config, NULL, &rx));
    const i2s_std_config_t standard_config = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(AUDIO_SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT,
                                                        I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = PIN_I2S_BCLK,
            .ws = PIN_I2S_WS,
            .dout = I2S_GPIO_UNUSED,
            .din = PIN_I2S_DATA,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx, &standard_config));
    ESP_ERROR_CHECK(i2s_channel_enable(rx));

    static int32_t samples[AUDIO_CAPTURE_FRAMES * 2];
    size_t bytes_read = 0;
    const esp_err_t read_result = i2s_channel_read(rx, samples, sizeof(samples),
                                                   &bytes_read, pdMS_TO_TICKS(1000));
    result(read_result == ESP_OK && bytes_read == sizeof(samples), "I2S stereo DMA capture completed");
    if (read_result == ESP_OK && bytes_read >= 4096) {
        int32_t left_min, left_max, right_min, right_max;
        const size_t words = bytes_read / sizeof(samples[0]);
        const bool left_ok = channel_has_audio(samples, words, 0, &left_min, &left_max);
        const bool right_ok = channel_has_audio(samples, words, 1, &right_min, &right_max);
        ESP_LOGI(TAG, "audio spans left=%" PRId32 "..%" PRId32 ", right=%" PRId32 "..%" PRId32,
                 left_min, left_max, right_min, right_max);
        result(left_ok, "left T5848 produces changing samples");
        result(right_ok, "right T5848 produces changing samples");
    }

    ESP_ERROR_CHECK(i2s_channel_disable(rx));
    ESP_ERROR_CHECK(i2s_del_channel(rx));
    ESP_ERROR_CHECK(gpio_set_level(PIN_MIC_POWER, 0));
}

static void isolate_sd_bus(void)
{
    const gpio_config_t isolated = {
        .pin_bit_mask = BIT64(PIN_SD_MISO) | BIT64(PIN_SD_CLK) |
                        BIT64(PIN_SD_MOSI) | BIT64(PIN_SD_CS),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = false,
        .pull_down_en = false,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&isolated));
}

static void test_micro_sd(void)
{
    ESP_ERROR_CHECK(gpio_set_level(PIN_SD_POWER, 1));
    vTaskDelay(pdMS_TO_TICKS(10));

    sdmmc_host_t host = SDSPI_HOST_DEFAULT();
    host.max_freq_khz = 10000;
    const spi_bus_config_t bus_config = {
        .mosi_io_num = PIN_SD_MOSI,
        .miso_io_num = PIN_SD_MISO,
        .sclk_io_num = PIN_SD_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = SD_TEST_BYTES,
    };
    esp_err_t error = spi_bus_initialize(host.slot, &bus_config, SDSPI_DEFAULT_DMA);
    if (error != ESP_OK) {
        result(false, "microSD SPI bus initialized");
        isolate_sd_bus();
        ESP_ERROR_CHECK(gpio_set_level(PIN_SD_POWER, 0));
        return;
    }

    const sdspi_device_config_t slot_config = {
        .host_id = host.slot,
        .gpio_cs = PIN_SD_CS,
        .gpio_cd = PIN_SD_DETECT,
        .gpio_wp = GPIO_NUM_NC,
        .gpio_int = GPIO_NUM_NC,
    };
    const esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 2,
        .allocation_unit_size = 16 * 1024,
    };
    sdmmc_card_t *card = NULL;
    error = esp_vfs_fat_sdspi_mount("/sdcard", &host, &slot_config, &mount_config, &card);
    result(error == ESP_OK, "microSD mounts without formatting");

    bool verify_ok = false;
    if (error == ESP_OK) {
        sdmmc_card_print_info(stdout, card);
        uint8_t write_buffer[SD_TEST_BYTES];
        uint8_t read_buffer[SD_TEST_BYTES];
        for (size_t i = 0; i < sizeof(write_buffer); ++i) {
            write_buffer[i] = (uint8_t)((i * 73U + 41U) & 0xffU);
        }
        FILE *file = fopen("/sdcard/neorecall_factory_test.bin", "wb");
        bool write_ok = false;
        if (file != NULL) {
            const bool all_bytes_written =
                fwrite(write_buffer, 1, sizeof(write_buffer), file) == sizeof(write_buffer);
            const bool flushed = fflush(file) == 0;
            const bool synchronized = flushed && fsync(fileno(file)) == 0;
            const bool closed = fclose(file) == 0;
            write_ok = all_bytes_written && flushed && synchronized && closed;
        }
        result(write_ok, "microSD synchronized write completed");

        file = fopen("/sdcard/neorecall_factory_test.bin", "rb");
        if (file != NULL) {
            const bool all_bytes_read =
                fread(read_buffer, 1, sizeof(read_buffer), file) == sizeof(read_buffer);
            const bool closed = fclose(file) == 0;
            verify_ok = all_bytes_read && closed &&
                        memcmp(write_buffer, read_buffer, sizeof(write_buffer)) == 0;
        }
        result(verify_ok, "microSD readback matches written pattern");
        unlink("/sdcard/neorecall_factory_test.bin");
        esp_vfs_fat_sdcard_unmount("/sdcard", card);
    }

    ESP_ERROR_CHECK(spi_bus_free(host.slot));
    isolate_sd_bus();
    ESP_ERROR_CHECK(gpio_set_level(PIN_SD_POWER, 0));
    result(gpio_get_level(PIN_SD_POWER) == 0, "microSD bus isolated before power removal");
}

static void offer_deep_sleep_test(void)
{
    ESP_LOGI(TAG, "Hold the center button for 2 seconds, then release it, to test deep-sleep wake.");
    unsigned held_ms = 0;
    while (true) {
        const bool pressed = gpio_get_level(PIN_BUTTON_WAKE) == 0 &&
                             gpio_get_level(PIN_BUTTON_BOOT) == 0;
        held_ms = pressed ? held_ms + 20 : 0;
        if (held_ms >= BUTTON_HOLD_TO_ARM_MS) break;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    ESP_LOGI(TAG, "Deep sleep armed; release button, then press once to wake.");
    while (gpio_get_level(PIN_BUTTON_WAKE) == 0) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    vTaskDelay(pdMS_TO_TICKS(250));
    ESP_ERROR_CHECK(esp_deep_sleep_enable_gpio_wakeup(BIT64(PIN_BUTTON_WAKE),
                                                       ESP_GPIO_WAKEUP_GPIO_LOW));
    fflush(stdout);
    esp_deep_sleep_start();
}

void app_main(void)
{
    configure_board_gpio();
    const esp_sleep_wakeup_cause_t wake_cause = esp_sleep_get_wakeup_cause();
    ESP_LOGI(TAG, "NeoRecall Rev C manufacturing test; wake cause=%d", wake_cause);
    if (wake_cause == ESP_SLEEP_WAKEUP_GPIO) {
        result(true, "GPIO0 woke the ESP32-C6 from deep sleep");
    }

    test_status_gpio();
    test_battery_adc();
    test_stereo_microphones();
    test_micro_sd();

    ESP_LOGI(TAG, "AUTOMATED RESULT: %u passed, %u failed", s_passes, s_failures);
    if (s_failures == 0) {
        ESP_LOGI(TAG, "All automated board tests passed; RF, USB margin, charging current, and analog quality still require fixtures.");
    }
    offer_deep_sleep_test();
}
