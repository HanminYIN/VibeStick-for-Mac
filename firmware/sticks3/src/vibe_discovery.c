#include "vibe_discovery.h"

#include <stdio.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "mdns.h"
#include "vibe_device_config.h"
#include "vibe_network_diagnostics.h"

static const char *TAG = "vibe_discovery";

static char s_host[64];
static uint16_t s_port;
static bool s_bonjour;
static bool s_initialized;

void vibe_bridge_discovery_use_fallback(void)
{
    const vibe_device_config_t *config = vibe_device_config_get();
    strlcpy(s_host, config->fallback_host, sizeof(s_host));
    s_port = config->bridge_port;
    s_bonjour = false;
    vibe_network_diagnostics_set_target(
        s_host,
        s_port,
        VIBE_NETWORK_TARGET_FALLBACK
    );
}

esp_err_t vibe_bridge_discovery_init(void)
{
    vibe_bridge_discovery_use_fallback();
    if (s_initialized) return ESP_OK;
    esp_err_t err = mdns_init();
    if (err == ESP_OK) s_initialized = true;
    return err;
}

static bool result_matches_bridge(const mdns_result_t *result, const char *bridge_id)
{
    for (size_t index = 0; index < result->txt_count; ++index) {
        const mdns_txt_item_t *item = &result->txt[index];
        if (item->key && item->value && strcmp(item->key, "bridge_id") == 0 &&
            strcmp(item->value, bridge_id) == 0) {
            return true;
        }
    }
    return false;
}

static bool copy_ipv4(const mdns_ip_addr_t *address)
{
    for (const mdns_ip_addr_t *item = address; item; item = item->next) {
        if (item->addr.type == ESP_IPADDR_TYPE_V4) {
            snprintf(s_host, sizeof(s_host), IPSTR, IP2STR(&item->addr.u_addr.ip4));
            return true;
        }
    }
    return false;
}

esp_err_t vibe_bridge_discovery_resolve(void)
{
    const vibe_device_config_t *config = vibe_device_config_get();
    if (!config->paired || config->bridge_id[0] == '\0') {
        vibe_bridge_discovery_use_fallback();
        vibe_network_diagnostics_note_discovery_result(ESP_ERR_INVALID_STATE);
        return ESP_ERR_INVALID_STATE;
    }
    if (!s_initialized) {
        esp_err_t init_err = vibe_bridge_discovery_init();
        if (init_err != ESP_OK) {
            ESP_LOGE(TAG, "mdns init: %s", esp_err_to_name(init_err));
            vibe_network_diagnostics_note_discovery_result(init_err);
            return init_err;
        }
    }

    mdns_result_t *results = NULL;
    esp_err_t err = mdns_query_ptr("_vibestick", "_tcp", 1500, 8, &results);
    if (err != ESP_OK || !results) {
        if (results) mdns_query_results_free(results);
        vibe_bridge_discovery_use_fallback();
        esp_err_t result = err == ESP_OK ? ESP_ERR_NOT_FOUND : err;
        vibe_network_diagnostics_note_discovery_result(result);
        return result;
    }

    bool found = false;
    for (mdns_result_t *result = results; result; result = result->next) {
        if (result_matches_bridge(result, config->bridge_id) && copy_ipv4(result->addr)) {
            s_port = result->port;
            s_bonjour = true;
            found = true;
            break;
        }
    }
    mdns_query_results_free(results);
    if (!found) {
        vibe_bridge_discovery_use_fallback();
        vibe_network_diagnostics_note_discovery_result(ESP_ERR_NOT_FOUND);
        return ESP_ERR_NOT_FOUND;
    }
    vibe_network_diagnostics_set_target(
        s_host,
        s_port,
        VIBE_NETWORK_TARGET_BONJOUR
    );
    vibe_network_diagnostics_note_discovery_result(ESP_OK);
    ESP_LOGI(TAG, "paired bridge discovered at %s:%u", s_host, (unsigned)s_port);
    return ESP_OK;
}

const char *vibe_bridge_discovery_host(void)
{
    return s_host;
}

uint16_t vibe_bridge_discovery_port(void)
{
    return s_port;
}

bool vibe_bridge_discovery_is_bonjour(void)
{
    return s_bonjour;
}
