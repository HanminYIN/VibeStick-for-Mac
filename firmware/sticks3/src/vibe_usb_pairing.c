#include "vibe_usb_pairing.h"

#include <stdio.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/base64.h"
#include "vibe_device_config.h"
#include "vibe_discovery.h"
#include "vibe_stick_config.h"

static const char *TAG = "vibe_usb_pair";

#define USB_LINE_MAX 1024

static void send_response(const char *json)
{
    char response[512];
    int length = snprintf(response, sizeof(response), "VIBESTICK_RESPONSE %s\n", json);
    if (length <= 0 || length >= (int)sizeof(response)) return;
    (void)usb_serial_jtag_write_bytes(response, (size_t)length, pdMS_TO_TICKS(500));
    (void)usb_serial_jtag_wait_tx_done(pdMS_TO_TICKS(500));
}

static void send_identify(void)
{
    const vibe_device_config_t *config = vibe_device_config_get();
    char json[384];
    snprintf(json, sizeof(json),
             "{\"command\":\"identify\",\"ok\":true,\"identity\":{"
             "\"device_id\":\"%s\",\"model\":\"M5Stack StickS3\","
             "\"firmware_version\":\"%s\",\"protocol_version\":2,"
             "\"pairing_schema_version\":2,\"wifi_configured\":%s,"
             "\"pairing_id\":\"%s\"}}",
             config->device_id, FIRMWARE_VERSION,
             config->wifi_configured ? "true" : "false", config->pairing_id);
    send_response(json);
}

static void handle_pair(const char *encoded)
{
    unsigned char decoded[768];
    size_t decoded_len = 0;
    int result = mbedtls_base64_decode(
        decoded,
        sizeof(decoded) - 1,
        &decoded_len,
        (const unsigned char *)encoded,
        strlen(encoded)
    );
    if (result != 0 || decoded_len == 0 || decoded_len >= sizeof(decoded)) {
        send_response("{\"command\":\"pair\",\"ok\":false,\"error\":\"invalid payload\"}");
        return;
    }
    decoded[decoded_len] = '\0';
    bool wifi_changed = false;
    esp_err_t err = vibe_device_config_apply_pairing_json((const char *)decoded, &wifi_changed);
    memset(decoded, 0, sizeof(decoded));
    if (err != ESP_OK) {
        send_response("{\"command\":\"pair\",\"ok\":false,\"error\":\"configuration rejected\"}");
        return;
    }
    vibe_bridge_discovery_use_fallback();
    ESP_LOGI(TAG, "USB pairing updated for device=%s", vibe_device_config_get()->device_id);
    send_response(wifi_changed
        ? "{\"command\":\"pair\",\"ok\":true,\"restart_required\":true}"
        : "{\"command\":\"pair\",\"ok\":true,\"restart_required\":false}");
    if (wifi_changed) {
        vTaskDelay(pdMS_TO_TICKS(250));
        esp_restart();
    }
}

static void handle_line(char *line)
{
    while (*line == '\r' || *line == '\n' || *line == ' ') line++;
    size_t length = strlen(line);
    while (length > 0 && (line[length - 1] == '\r' || line[length - 1] == '\n' || line[length - 1] == ' ')) {
        line[--length] = '\0';
    }
    if (strcmp(line, "VIBESTICK IDENTIFY") == 0) {
        send_identify();
        return;
    }
    const char *prefix = "VIBESTICK PAIR ";
    if (strncmp(line, prefix, strlen(prefix)) == 0) {
        handle_pair(line + strlen(prefix));
    }
}

static void usb_pairing_task(void *argument)
{
    (void)argument;
    char line[USB_LINE_MAX];
    size_t used = 0;
    while (true) {
        uint8_t input[128];
        int count = usb_serial_jtag_read_bytes(input, sizeof(input), pdMS_TO_TICKS(250));
        if (count <= 0) continue;
        for (int index = 0; index < count; ++index) {
            char character = (char)input[index];
            if (character == '\n') {
                line[used] = '\0';
                handle_line(line);
                memset(line, 0, used);
                used = 0;
            } else if (character >= 0x20 && character <= 0x7e) {
                if (used < sizeof(line) - 1) {
                    line[used++] = character;
                } else {
                    memset(line, 0, sizeof(line));
                    used = 0;
                }
            }
        }
    }
}

esp_err_t vibe_usb_pairing_start(void)
{
    if (!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
        config.rx_buffer_size = 2048;
        config.tx_buffer_size = 1024;
        esp_err_t err = usb_serial_jtag_driver_install(&config);
        if (err != ESP_OK) return err;
    }
    BaseType_t result = xTaskCreate(usb_pairing_task, "usb_pairing", 4096, NULL, 3, NULL);
    return result == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}
