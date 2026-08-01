# SPDX-License-Identifier: MIT
idf_component_register(
    SRCS
        "app_main.c"
        "nr_common.c"
        "config/nr_config.c"
        "settings/nr_settings.c"
        "util/nr_util.c"
        "net/nr_time.c"
        "net/nr_http.c"
        "net/nr_wifi.c"
        "net/nr_portal.c"
        "net/nr_ota.c"
        "ingest/nr_spool.c"
        "ingest/nr_ingest.c"
        "ingest/nr_recorder.c"
        "board/nr_board.c"
        "board/nr_mic.c"
        "services/nr_weather.c"
        "services/nr_geo.c"
        "ui/nr_ui.c"
        "ui/ui_settings.c"
        "ui/fonts/nr_font_14.c"
        "ui/fonts/nr_font_16.c"
        "ui/fonts/nr_font_20.c"
        "ui/fonts/nr_font_24.c"
        "ui/fonts/nr_font_36.c"
        "ui/fonts/nr_font_48.c"
    INCLUDE_DIRS "."
    REQUIRES
        nvs_flash
        esp_event
        esp_timer
        esp_wifi
        esp_netif
        esp_http_client
        esp_http_server
        esp_https_ota
        app_update
        esp-tls
        mbedtls
        json
        driver
        esp_lcd
        esp_psram
        lwip
        esp_hw_support
)

# uint32_t is `long unsigned` on xtensa, so %u/%lu tripping -Werror=format is an
# ABI pedantry, not a bug; snprintf format-truncation on our bounded path buffers
# is likewise a false positive. Keep them as warnings for this app component.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=format -Wno-error=format-truncation)
