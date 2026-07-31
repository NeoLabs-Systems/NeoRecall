// SPDX-License-Identifier: MIT
#include "nr_board.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c.h"
#include "driver/ledc.h"
#include "esp_log.h"

#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_lcd_panel_io_additions.h"   // 3-wire SPI over IO expander
#include "esp_io_expander_tca9554.h"
#include "esp_lcd_st7701.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_lvgl_port.h"

#include "board/board_config.h"

static const char *TAG = "nr_board";

// Set to 0 to fall back to the esp_lcd_st7701 built-in init sequence if the
// panel-specific one below ever misbehaves on a hardware revision.
#define NR_ST7701_USE_VENDOR_INIT 1
// The AP3032 backlight boost is active-low on this board.
#define NR_BL_ACTIVE_LOW 1
#define NR_BL_LEDC_TIMER  LEDC_TIMER_1
#define NR_BL_LEDC_CH     LEDC_CHANNEL_4
#define NR_BL_LEDC_RES    LEDC_TIMER_10_BIT
#define NR_BL_MAX_DUTY    1023

static esp_io_expander_handle_t s_expander;
static esp_lcd_panel_handle_t s_panel;
static uint8_t s_backlight = 90;

// --- ST7701 panel-specific init (verified ESPHome/Waveshare sequence) --------
#if NR_ST7701_USE_VENDOR_INIT
static const st7701_lcd_init_cmd_t s_st7701_init[] = {
    {0x01, (uint8_t[]){0x00}, 0, 10},                                   // SW reset
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x10}, 5, 0},            // CMD2 BK0
    {0xC0, (uint8_t[]){0x3B, 0x00}, 2, 0},                              // LNSET (480 lines)
    {0xC1, (uint8_t[]){0x0D, 0x02}, 2, 0},                              // PORCTRL
    {0xC2, (uint8_t[]){0x31, 0x05}, 2, 0},                              // INVSET
    {0xB0, (uint8_t[]){0x00, 0x11, 0x18, 0x0E, 0x11, 0x06, 0x07, 0x08, 0x07, 0x22, 0x04, 0x12, 0x0F, 0xAA, 0x31, 0x18}, 16, 0}, // + gamma
    {0xB1, (uint8_t[]){0x00, 0x11, 0x19, 0x0E, 0x12, 0x07, 0x08, 0x08, 0x08, 0x22, 0x04, 0x11, 0x11, 0xA9, 0x32, 0x18}, 16, 0}, // - gamma
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x11}, 5, 0},            // CMD2 BK1
    {0xB0, (uint8_t[]){0x60}, 1, 0}, {0xB1, (uint8_t[]){0x32}, 1, 0},
    {0xB2, (uint8_t[]){0x07}, 1, 0}, {0xB3, (uint8_t[]){0x80}, 1, 0},
    {0xB5, (uint8_t[]){0x49}, 1, 0}, {0xB7, (uint8_t[]){0x85}, 1, 0},
    {0xB8, (uint8_t[]){0x21}, 1, 0}, {0xC1, (uint8_t[]){0x78}, 1, 0},
    {0xC2, (uint8_t[]){0x78}, 1, 0}, {0xE0, (uint8_t[]){0x00, 0x1B, 0x02}, 3, 0},
    {0xE1, (uint8_t[]){0x08, 0xA0, 0x00, 0x00, 0x07, 0xA0, 0x00, 0x00, 0x00, 0x44, 0x44}, 11, 0},
    {0xE2, (uint8_t[]){0x11, 0x11, 0x44, 0x44, 0xED, 0xA0, 0x00, 0x00, 0xEC, 0xA0, 0x00, 0x00}, 12, 0},
    {0xE3, (uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0}, {0xE4, (uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE5, (uint8_t[]){0x0A, 0xE9, 0xD8, 0xA0, 0x0C, 0xEB, 0xD8, 0xA0, 0x0E, 0xED, 0xD8, 0xA0, 0x10, 0xEF, 0xD8, 0xA0}, 16, 0},
    {0xE6, (uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0}, {0xE7, (uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE8, (uint8_t[]){0x09, 0xE8, 0xD8, 0xA0, 0x0B, 0xEA, 0xD8, 0xA0, 0x0D, 0xEC, 0xD8, 0xA0, 0x0F, 0xEE, 0xD8, 0xA0}, 16, 0},
    {0xEB, (uint8_t[]){0x02, 0x00, 0xE4, 0xE4, 0x88, 0x00, 0x40}, 7, 0}, {0xEC, (uint8_t[]){0x3C, 0x00}, 2, 0},
    {0xED, (uint8_t[]){0xAB, 0x89, 0x76, 0x54, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x20, 0x45, 0x67, 0x98, 0xBA}, 16, 0},
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x13}, 5, 0},            // CMD2 BK3
    {0xE5, (uint8_t[]){0xE4}, 1, 0},
    {0xFF, (uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x10}, 5, 0},            // back to BK0
    {0xCD, (uint8_t[]){0x08}, 1, 0},                                    // RGB pixel packing
};
#endif

// ---- I2C -------------------------------------------------------------------

static esp_err_t i2c_init(void)
{
    i2c_config_t cfg = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = BRD_I2C_SDA,
        .scl_io_num = BRD_I2C_SCL,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master.clk_speed = BRD_I2C_HZ,
    };
    NR_RETURN_ON_ERR(i2c_param_config(BRD_I2C_PORT, &cfg));
    return i2c_driver_install(BRD_I2C_PORT, I2C_MODE_MASTER, 0, 0, 0);
}

// ---- backlight -------------------------------------------------------------

static void backlight_init(void)
{
    ledc_timer_config_t t = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = NR_BL_LEDC_RES,
        .timer_num = NR_BL_LEDC_TIMER,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&t);
    ledc_channel_config_t ch = {
        .gpio_num = BRD_LCD_BL,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = NR_BL_LEDC_CH,
        .timer_sel = NR_BL_LEDC_TIMER,
        .duty = 0,
        .hpoint = 0,
    };
    ledc_channel_config(&ch);
    nr_board_set_backlight(s_backlight);
}

void nr_board_set_backlight(uint8_t percent)
{
    if (percent > 100) percent = 100;
    s_backlight = percent;
    uint32_t duty = (uint32_t) percent * NR_BL_MAX_DUTY / 100;
#if NR_BL_ACTIVE_LOW
    duty = NR_BL_MAX_DUTY - duty;
#endif
    ledc_set_duty(LEDC_LOW_SPEED_MODE, NR_BL_LEDC_CH, duty);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, NR_BL_LEDC_CH);
}

uint8_t nr_board_get_backlight(void) { return s_backlight; }

// ---- display ---------------------------------------------------------------

static esp_err_t display_init(void)
{
    // TCA9554 expander (drives the ST7701 3-wire SPI + reset).
    NR_RETURN_ON_ERR(esp_io_expander_new_i2c_tca9554(
        BRD_I2C_PORT, ESP_IO_EXPANDER_I2C_TCA9554_ADDRESS_000, &s_expander));

    // Hardware-reset the panel through EXIO7.
    esp_io_expander_set_dir(s_expander, BIT(BRD_EXIO_LCD_RST), IO_EXPANDER_OUTPUT);
    esp_io_expander_set_level(s_expander, BIT(BRD_EXIO_LCD_RST), 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    esp_io_expander_set_level(s_expander, BIT(BRD_EXIO_LCD_RST), 1);
    vTaskDelay(pdMS_TO_TICKS(120));

    // 3-wire SPI command channel for the ST7701 init, bit-banged over EXIO0/1/2.
    spi_line_config_t line = {
        .cs_io_type = IO_TYPE_EXPANDER,
        .cs_expander_pin = BIT(BRD_EXIO_LCD_CS),
        .scl_io_type = IO_TYPE_EXPANDER,
        .scl_expander_pin = BIT(BRD_EXIO_LCD_SCL),
        .sda_io_type = IO_TYPE_EXPANDER,
        .sda_expander_pin = BIT(BRD_EXIO_LCD_SDA),
        .io_expander = s_expander,
    };
    esp_lcd_panel_io_3wire_spi_config_t io_cfg = ST7701_PANEL_IO_3WIRE_SPI_CONFIG(line, 0);
    esp_lcd_panel_io_handle_t io = NULL;
    NR_RETURN_ON_ERR(esp_lcd_new_panel_io_3wire_spi(&io_cfg, &io));

    static const int data_gpios[] = BRD_LCD_DATA_GPIOS;
    esp_lcd_rgb_panel_config_t rgb = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .psram_trans_align = 64,
        .data_width = 16,
        .bits_per_pixel = 16,
        .de_gpio_num = BRD_LCD_DE,
        .pclk_gpio_num = BRD_LCD_PCLK,
        .vsync_gpio_num = BRD_LCD_VSYNC,
        .hsync_gpio_num = BRD_LCD_HSYNC,
        .disp_gpio_num = -1,
        .num_fbs = 2,                          // double-buffer for tear-free UI
        .bounce_buffer_size_px = 12 * BRD_LCD_H_RES,
        .timings = {
            .pclk_hz = BRD_LCD_PCLK_HZ,
            .h_res = BRD_LCD_H_RES,
            .v_res = BRD_LCD_V_RES,
            .hsync_pulse_width = BRD_LCD_HSYNC_PULSE,
            .hsync_back_porch = BRD_LCD_HSYNC_BACK,
            .hsync_front_porch = BRD_LCD_HSYNC_FRONT,
            .vsync_pulse_width = BRD_LCD_VSYNC_PULSE,
            .vsync_back_porch = BRD_LCD_VSYNC_BACK,
            .vsync_front_porch = BRD_LCD_VSYNC_FRONT,
            .flags = { .pclk_active_neg = false },
        },
        .flags = { .fb_in_psram = true },
    };
    memcpy((void *) rgb.data_gpio_nums, data_gpios, sizeof(data_gpios));

    st7701_vendor_config_t vendor = {
        .rgb_config = &rgb,
#if NR_ST7701_USE_VENDOR_INIT
        .init_cmds = s_st7701_init,
        .init_cmds_size = sizeof(s_st7701_init) / sizeof(s_st7701_init[0]),
#endif
        .flags = { .auto_del_panel_io = 0, .use_mipi_interface = 0 },
    };
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = -1,                  // reset handled via the expander above
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,   // flip to _BGR if colours swap
        .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    NR_RETURN_ON_ERR(esp_lcd_new_panel_st7701(io, &panel_cfg, &s_panel));
    NR_RETURN_ON_ERR(esp_lcd_panel_reset(s_panel));
    NR_RETURN_ON_ERR(esp_lcd_panel_init(s_panel));
    esp_lcd_panel_invert_color(s_panel, true);       // ESPHome invert_colors: true
    esp_lcd_panel_disp_on_off(s_panel, true);
    ESP_LOGI(TAG, "ST7701 panel up (%dx%d)", BRD_LCD_H_RES, BRD_LCD_V_RES);
    return ESP_OK;
}

// ---- touch -----------------------------------------------------------------

static esp_lcd_touch_handle_t s_touch;

static esp_err_t touch_init(void)
{
    esp_lcd_panel_io_handle_t tp_io = NULL;
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_GT911_CONFIG();
    io_cfg.dev_addr = BRD_ADDR_GT911;
    NR_RETURN_ON_ERR(esp_lcd_new_panel_io_i2c((esp_lcd_i2c_bus_handle_t)(uint32_t) BRD_I2C_PORT, &io_cfg, &tp_io));

    esp_lcd_touch_config_t cfg = {
        .x_max = BRD_LCD_H_RES,
        .y_max = BRD_LCD_V_RES,
        .rst_gpio_num = -1,      // GT911 RST is on the expander; rely on its flashed config
        .int_gpio_num = -1,      // polled over I2C
        .flags = { .swap_xy = 0, .mirror_x = 0, .mirror_y = 0 },
    };
    esp_err_t err = esp_lcd_touch_new_i2c_gt911(tp_io, &cfg, &s_touch);
    if (err != ESP_OK) ESP_LOGW(TAG, "GT911 init failed (%s); touch disabled", esp_err_to_name(err));
    return err;
}

// ---- LVGL ------------------------------------------------------------------

static esp_err_t lvgl_init(void)
{
    lvgl_port_cfg_t cfg = ESP_LVGL_PORT_INIT_CONFIG();
    cfg.task_priority = 4;
    cfg.task_stack = 8192;
    cfg.task_affinity = 0;           // pin UI to core 0, capture runs on core 1
    NR_RETURN_ON_ERR(lvgl_port_init(&cfg));

    lvgl_port_display_cfg_t disp_cfg = {
        .panel_handle = s_panel,
        .buffer_size = BRD_LCD_H_RES * BRD_LCD_V_RES,
        .double_buffer = true,
        .hres = BRD_LCD_H_RES,
        .vres = BRD_LCD_V_RES,
        .monochrome = false,
        .rotation = { .swap_xy = false, .mirror_x = false, .mirror_y = false },
        .flags = { .buff_spiram = true },
    };
    lvgl_port_display_rgb_cfg_t rgb_cfg = {
        .flags = { .bb_mode = true, .avoid_tearing = true },
    };
    lv_display_t *disp = lvgl_port_add_disp_rgb(&disp_cfg, &rgb_cfg);
    if (!disp) return ESP_FAIL;

    if (s_touch) {
        lvgl_port_touch_cfg_t touch_cfg = { .disp = disp, .handle = s_touch };
        lvgl_port_add_touch(&touch_cfg);
    }
    return ESP_OK;
}

// ---- public ----------------------------------------------------------------

esp_err_t nr_board_init(void)
{
    NR_RETURN_ON_ERR(i2c_init());
    backlight_init();
    NR_RETURN_ON_ERR(display_init());
    touch_init();                    // non-fatal if touch is absent
    NR_RETURN_ON_ERR(lvgl_init());
    return ESP_OK;
}

bool nr_board_lock(int timeout_ms) { return lvgl_port_lock(timeout_ms < 0 ? 0 : timeout_ms); }
void nr_board_unlock(void) { lvgl_port_unlock(); }
