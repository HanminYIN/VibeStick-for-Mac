idf_component_register(
    SRCS "main.c" "vibe_ui.c" "vibe_board.c" "vibe_audio.c" "vibe_device_config.c" "vibe_discovery.c" "vibe_usb_pairing.c" "vibe_voice_interaction.c" "../generated/vibe_stick_cn_16.c" "../generated/vibe_stick_ui_10.c" "../generated/vibe_stick_ui_12.c" "../generated/vibe_stick_project_cn_10.c" "../generated/vibe_stick_ui_assets.c"
    INCLUDE_DIRS "../include" "../generated"
    REQUIRES esp_wifi esp_http_client esp_event esp_netif nvs_flash json driver esp_timer esp_lcd esp_codec_dev mdns esp_driver_usb_serial_jtag mbedtls
)
