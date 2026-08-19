#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t vibe_bridge_discovery_init(void);
esp_err_t vibe_bridge_discovery_resolve(void);
void vibe_bridge_discovery_use_fallback(void);
const char *vibe_bridge_discovery_host(void);
uint16_t vibe_bridge_discovery_port(void);
bool vibe_bridge_discovery_is_bonjour(void);
