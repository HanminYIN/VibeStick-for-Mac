#include "vibe_network_diagnostics.h"

#include <stdio.h>
#include <string.h>

#if defined(ESP_PLATFORM)
#include "freertos/FreeRTOS.h"
#include "freertos/portmacro.h"

static portMUX_TYPE s_diagnostics_lock = portMUX_INITIALIZER_UNLOCKED;
#define DIAGNOSTICS_LOCK() portENTER_CRITICAL(&s_diagnostics_lock)
#define DIAGNOSTICS_UNLOCK() portEXIT_CRITICAL(&s_diagnostics_lock)
#else
#define DIAGNOSTICS_LOCK() ((void)0)
#define DIAGNOSTICS_UNLOCK() ((void)0)
#endif

static vibe_network_diagnostics_snapshot_t s_snapshot;

_Static_assert(
    sizeof(vibe_network_diagnostics_snapshot_t) <= 192,
    "network diagnostics snapshot must remain bounded"
);

static void copy_string(char *target, size_t target_size, const char *value)
{
    if (!target || target_size == 0) return;
    snprintf(target, target_size, "%s", value ? value : "");
}

void vibe_network_diagnostics_reset(void)
{
    DIAGNOSTICS_LOCK();
    memset(&s_snapshot, 0, sizeof(s_snapshot));
    DIAGNOSTICS_UNLOCK();
}

void vibe_network_diagnostics_set_wifi_connected(bool connected)
{
    DIAGNOSTICS_LOCK();
    s_snapshot.wifi_connected = connected;
    DIAGNOSTICS_UNLOCK();
}

void vibe_network_diagnostics_set_target(
    const char *host,
    uint16_t port,
    vibe_network_target_source_t source
)
{
    DIAGNOSTICS_LOCK();
    copy_string(s_snapshot.target_host, sizeof(s_snapshot.target_host), host);
    s_snapshot.target_port = port;
    s_snapshot.target_source = source;
    DIAGNOSTICS_UNLOCK();
}

void vibe_network_diagnostics_note_discovery_result(int32_t error)
{
    DIAGNOSTICS_LOCK();
    s_snapshot.discovery_attempts++;
    s_snapshot.last_discovery_error = error;
    DIAGNOSTICS_UNLOCK();
}

void vibe_network_diagnostics_note_http_result(
    const char *host,
    uint16_t port,
    vibe_network_target_source_t source,
    int32_t error,
    int32_t status
)
{
    DIAGNOSTICS_LOCK();
    s_snapshot.http_attempts++;
    copy_string(
        s_snapshot.last_request_host,
        sizeof(s_snapshot.last_request_host),
        host
    );
    s_snapshot.last_request_port = port;
    s_snapshot.last_request_source = source;
    s_snapshot.last_http_error = error;
    s_snapshot.last_http_status = status;
    if (error == 0 && status >= 200 && status < 300) {
        s_snapshot.http_successes++;
    }
    DIAGNOSTICS_UNLOCK();
}

void vibe_network_diagnostics_snapshot(vibe_network_diagnostics_snapshot_t *snapshot)
{
    if (!snapshot) return;
    DIAGNOSTICS_LOCK();
    *snapshot = s_snapshot;
    DIAGNOSTICS_UNLOCK();
}

static const char *target_source_name(vibe_network_target_source_t source)
{
    if (source == VIBE_NETWORK_TARGET_FALLBACK) return "fallback";
    if (source == VIBE_NETWORK_TARGET_BONJOUR) return "bonjour";
    return "unknown";
}

bool vibe_network_diagnostics_format_response(
    char *response,
    size_t response_size,
    bool paired
)
{
    if (!response || response_size == 0) return false;

    vibe_network_diagnostics_snapshot_t snapshot;
    vibe_network_diagnostics_snapshot(&snapshot);
    int length = snprintf(
        response,
        response_size,
        "{\"command\":\"network_diagnostics\",\"ok\":true,\"network\":{"
        "\"wifi_connected\":%s,\"paired\":%s,"
        "\"current_target_source\":\"%s\","
        "\"current_target_host\":\"%s\",\"current_target_port\":%u,"
        "\"discovery_attempts\":%lu,\"last_discovery_error\":%ld,"
        "\"http_attempts\":%lu,\"http_successes\":%lu,"
        "\"last_request_target_source\":\"%s\","
        "\"last_request_target_host\":\"%s\","
        "\"last_request_target_port\":%u,"
        "\"last_http_error\":%ld,\"last_http_status\":%ld}}",
        snapshot.wifi_connected ? "true" : "false",
        paired ? "true" : "false",
        target_source_name(snapshot.target_source),
        snapshot.target_host,
        (unsigned)snapshot.target_port,
        (unsigned long)snapshot.discovery_attempts,
        (long)snapshot.last_discovery_error,
        (unsigned long)snapshot.http_attempts,
        (unsigned long)snapshot.http_successes,
        target_source_name(snapshot.last_request_source),
        snapshot.last_request_host,
        (unsigned)snapshot.last_request_port,
        (long)snapshot.last_http_error,
        (long)snapshot.last_http_status
    );
    return length > 0 && (size_t)length < response_size;
}
