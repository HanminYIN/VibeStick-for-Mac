#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef enum {
    VIBE_DOUBLE_REFRESH_QUOTA = 0,
    VIBE_DOUBLE_SHOW_STATUS,
    VIBE_DOUBLE_HOME,
    VIBE_DOUBLE_TOGGLE_MUTE,
} vibe_double_press_action_t;

typedef enum {
    VIBE_SIDE_NEXT_PAGE = 0,
    VIBE_SIDE_NONE,
} vibe_side_press_action_t;

typedef struct {
    char device_id[32];
    char pairing_token[64];
    char pairing_id[40];
    char bridge_id[40];
    char fallback_host[64];
    uint16_t bridge_port;
    bool paired;
    uint32_t revision;
    bool module_codex;
    bool module_claude;
    bool module_connection;
    bool project_visible;
    char project_name[40];
    vibe_double_press_action_t front_double;
    vibe_side_press_action_t side_single;
} vibe_device_config_t;

esp_err_t vibe_device_config_init(void);
const vibe_device_config_t *vibe_device_config_get(void);
bool vibe_device_config_module_enabled(const char *module);
esp_err_t vibe_device_config_apply_pairing_json(const char *json);
esp_err_t vibe_device_config_apply_configuration_json(const char *json, bool *changed);
