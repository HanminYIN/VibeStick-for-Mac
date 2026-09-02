#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    VIBE_NETWORK_TARGET_UNKNOWN = 0,
    VIBE_NETWORK_TARGET_FALLBACK = 1,
    VIBE_NETWORK_TARGET_BONJOUR = 2,
} vibe_network_target_source_t;

typedef struct {
    bool wifi_connected;
    char target_host[64];
    uint16_t target_port;
    vibe_network_target_source_t target_source;
    uint32_t discovery_attempts;
    int32_t last_discovery_error;
    uint32_t http_attempts;
    uint32_t http_successes;
    char last_request_host[64];
    uint16_t last_request_port;
    vibe_network_target_source_t last_request_source;
    int32_t last_http_error;
    int32_t last_http_status;
} vibe_network_diagnostics_snapshot_t;

void vibe_network_diagnostics_reset(void);
void vibe_network_diagnostics_set_wifi_connected(bool connected);
void vibe_network_diagnostics_set_target(
    const char *host,
    uint16_t port,
    vibe_network_target_source_t source
);
void vibe_network_diagnostics_note_discovery_result(int32_t error);
void vibe_network_diagnostics_note_http_result(
    const char *host,
    uint16_t port,
    vibe_network_target_source_t source,
    int32_t error,
    int32_t status
);
void vibe_network_diagnostics_snapshot(vibe_network_diagnostics_snapshot_t *snapshot);
bool vibe_network_diagnostics_format_response(
    char *response,
    size_t response_size,
    bool paired
);
