idf_component_register(
    SRCS "manufacturing_test.c"
    INCLUDE_DIRS "."
    REQUIRES esp_adc esp_driver_gpio esp_driver_i2s esp_driver_spi esp_hw_support fatfs sdmmc
)
