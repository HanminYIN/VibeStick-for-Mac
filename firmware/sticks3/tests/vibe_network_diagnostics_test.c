#include "vibe_network_diagnostics.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void test_connected_device_without_http_attempts_is_visible(void)
{
    vibe_network_diagnostics_reset();
    vibe_network_diagnostics_set_wifi_connected(true);
    vibe_network_diagnostics_set_target(
        "192.168.31.173",
        8765,
        VIBE_NETWORK_TARGET_FALLBACK
    );

    vibe_network_diagnostics_snapshot_t snapshot;
    vibe_network_diagnostics_snapshot(&snapshot);

    assert(snapshot.wifi_connected);
    assert(strcmp(snapshot.target_host, "192.168.31.173") == 0);
    assert(snapshot.target_port == 8765);
    assert(snapshot.target_source == VIBE_NETWORK_TARGET_FALLBACK);
    assert(snapshot.http_attempts == 0);
    assert(snapshot.http_successes == 0);
}

static void test_discovery_and_http_failures_are_distinguishable(void)
{
    vibe_network_diagnostics_reset();
    vibe_network_diagnostics_set_wifi_connected(true);
    vibe_network_diagnostics_set_target(
        "192.168.31.173",
        8765,
        VIBE_NETWORK_TARGET_FALLBACK
    );
    vibe_network_diagnostics_note_discovery_result(-7);
    vibe_network_diagnostics_note_http_result(
        "192.168.31.173",
        8765,
        VIBE_NETWORK_TARGET_FALLBACK,
        -11,
        0
    );

    vibe_network_diagnostics_snapshot_t snapshot;
    vibe_network_diagnostics_snapshot(&snapshot);

    assert(snapshot.discovery_attempts == 1);
    assert(snapshot.last_discovery_error == -7);
    assert(snapshot.http_attempts == 1);
    assert(snapshot.http_successes == 0);
    assert(snapshot.last_http_error == -11);
    assert(snapshot.last_http_status == 0);
    assert(strcmp(snapshot.last_request_host, "192.168.31.173") == 0);
    assert(snapshot.last_request_port == 8765);
    assert(snapshot.last_request_source == VIBE_NETWORK_TARGET_FALLBACK);

    vibe_network_diagnostics_set_target(
        "192.168.31.174",
        8765,
        VIBE_NETWORK_TARGET_BONJOUR
    );
    vibe_network_diagnostics_note_discovery_result(0);
    vibe_network_diagnostics_note_http_result(
        "192.168.31.174",
        8765,
        VIBE_NETWORK_TARGET_BONJOUR,
        0,
        200
    );
    vibe_network_diagnostics_set_target(
        "192.168.31.173",
        8765,
        VIBE_NETWORK_TARGET_FALLBACK
    );
    vibe_network_diagnostics_snapshot(&snapshot);

    assert(snapshot.target_source == VIBE_NETWORK_TARGET_FALLBACK);
    assert(snapshot.discovery_attempts == 2);
    assert(snapshot.last_discovery_error == 0);
    assert(snapshot.http_attempts == 2);
    assert(snapshot.http_successes == 1);
    assert(snapshot.last_http_error == 0);
    assert(snapshot.last_http_status == 200);
    assert(strcmp(snapshot.last_request_host, "192.168.31.174") == 0);
    assert(snapshot.last_request_port == 8765);
    assert(snapshot.last_request_source == VIBE_NETWORK_TARGET_BONJOUR);
}

static void test_usb_response_is_bounded_and_contains_only_contract_fields(void)
{
    vibe_network_diagnostics_reset();
    vibe_network_diagnostics_set_wifi_connected(true);
    vibe_network_diagnostics_set_target(
        "192.168.31.173",
        8765,
        VIBE_NETWORK_TARGET_FALLBACK
    );
    vibe_network_diagnostics_note_http_result(
        "192.168.31.174",
        8765,
        VIBE_NETWORK_TARGET_BONJOUR,
        28674,
        500
    );

    char response[768];
    assert(vibe_network_diagnostics_format_response(
        response,
        sizeof(response),
        true
    ));
    const char *expected =
        "{\"command\":\"network_diagnostics\",\"ok\":true,\"network\":{"
        "\"wifi_connected\":true,\"paired\":true,"
        "\"current_target_source\":\"fallback\","
        "\"current_target_host\":\"192.168.31.173\","
        "\"current_target_port\":8765,"
        "\"discovery_attempts\":0,\"last_discovery_error\":0,"
        "\"http_attempts\":1,\"http_successes\":0,"
        "\"last_request_target_source\":\"bonjour\","
        "\"last_request_target_host\":\"192.168.31.174\","
        "\"last_request_target_port\":8765,"
        "\"last_http_error\":28674,\"last_http_status\":500}}";
    assert(strcmp(response, expected) == 0);

    char too_small[32];
    assert(!vibe_network_diagnostics_format_response(
        too_small,
        sizeof(too_small),
        true
    ));
}

int main(void)
{
    assert(sizeof(vibe_network_diagnostics_snapshot_t) <= 192);
    test_connected_device_without_http_attempts_is_visible();
    test_discovery_and_http_failures_are_distinguishable();
    test_usb_response_is_bounded_and_contains_only_contract_fields();
    printf(
        "vibe_network_diagnostics_test: ok (snapshot=%zu bytes)\n",
        sizeof(vibe_network_diagnostics_snapshot_t)
    );
    return 0;
}
