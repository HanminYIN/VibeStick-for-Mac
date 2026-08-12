#include "vibe_device_config.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_check.h"
#include "esp_mac.h"
#include "esp_log.h"
#include "nvs.h"
#include "vibe_stick_config.h"

static const char *TAG = "vibe_config";
static const char *NAMESPACE = "vibe_m2";

static vibe_device_config_t s_config;

static void make_device_id(char *target, size_t target_len)
{
    uint8_t mac[6] = {0};
    if (esp_read_mac(mac, ESP_MAC_WIFI_STA) != ESP_OK) {
        strlcpy(target, "vs-unknown-device", target_len);
        return;
    }
    snprintf(target, target_len, "vs-%02x%02x%02x%02x%02x%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static void defaults(void)
{
    memset(&s_config, 0, sizeof(s_config));
    make_device_id(s_config.device_id, sizeof(s_config.device_id));
    strlcpy(s_config.pairing_token, VIBE_STICK_BRIDGE_TOKEN, sizeof(s_config.pairing_token));
    strlcpy(s_config.fallback_host, VIBE_STICK_BRIDGE_HOST, sizeof(s_config.fallback_host));
    s_config.bridge_port = VIBE_STICK_BRIDGE_PORT;
    s_config.paired = false;
    s_config.module_codex = true;
    s_config.module_claude = true;
    s_config.module_connection = true;
    s_config.project_visible = true;
    s_config.front_double = VIBE_DOUBLE_REFRESH_QUOTA;
    s_config.side_single = VIBE_SIDE_NEXT_PAGE;
}

static void nvs_get_string(nvs_handle_t handle, const char *key, char *target, size_t target_len)
{
    size_t required = target_len;
    if (nvs_get_str(handle, key, target, &required) != ESP_OK) {
        return;
    }
    target[target_len - 1] = '\0';
}

static esp_err_t persist_pairing(void)
{
    nvs_handle_t handle;
    ESP_RETURN_ON_ERROR(nvs_open(NAMESPACE, NVS_READWRITE, &handle), TAG, "open nvs");
    esp_err_t err = nvs_set_str(handle, "pair_token", s_config.pairing_token);
    if (err == ESP_OK) err = nvs_set_str(handle, "pair_id", s_config.pairing_id);
    if (err == ESP_OK) err = nvs_set_str(handle, "bridge_id", s_config.bridge_id);
    if (err == ESP_OK) err = nvs_set_str(handle, "fallback", s_config.fallback_host);
    if (err == ESP_OK) err = nvs_set_u16(handle, "bridge_port", s_config.bridge_port);
    if (err == ESP_OK) err = nvs_commit(handle);
    nvs_close(handle);
    return err;
}

static esp_err_t persist_configuration(void)
{
    nvs_handle_t handle;
    ESP_RETURN_ON_ERROR(nvs_open(NAMESPACE, NVS_READWRITE, &handle), TAG, "open nvs");
    esp_err_t err = nvs_set_u32(handle, "revision", s_config.revision);
    if (err == ESP_OK) err = nvs_set_u8(handle, "mod_claude", s_config.module_claude);
    if (err == ESP_OK) err = nvs_set_u8(handle, "project_vis", s_config.project_visible);
    if (err == ESP_OK) err = nvs_set_str(handle, "project", s_config.project_name);
    if (err == ESP_OK) err = nvs_set_u8(handle, "front_dbl", (uint8_t)s_config.front_double);
    if (err == ESP_OK) err = nvs_set_u8(handle, "side_one", (uint8_t)s_config.side_single);
    if (err == ESP_OK) err = nvs_commit(handle);
    nvs_close(handle);
    return err;
}

esp_err_t vibe_device_config_init(void)
{
    defaults();
    nvs_handle_t handle;
    esp_err_t err = nvs_open(NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(err, TAG, "open nvs");

    char stored_token[sizeof(s_config.pairing_token)] = "";
    char stored_pairing_id[sizeof(s_config.pairing_id)] = "";
    char stored_bridge_id[sizeof(s_config.bridge_id)] = "";
    nvs_get_string(handle, "pair_token", stored_token, sizeof(stored_token));
    nvs_get_string(handle, "pair_id", stored_pairing_id, sizeof(stored_pairing_id));
    nvs_get_string(handle, "bridge_id", stored_bridge_id, sizeof(stored_bridge_id));
    if (strlen(stored_token) >= 32 && strlen(stored_bridge_id) == 36) {
        strlcpy(s_config.pairing_token, stored_token, sizeof(s_config.pairing_token));
        strlcpy(s_config.pairing_id, stored_pairing_id, sizeof(s_config.pairing_id));
        strlcpy(s_config.bridge_id, stored_bridge_id, sizeof(s_config.bridge_id));
        nvs_get_string(handle, "fallback", s_config.fallback_host, sizeof(s_config.fallback_host));
        (void)nvs_get_u16(handle, "bridge_port", &s_config.bridge_port);
        s_config.paired = true;
    }

    uint8_t byte_value = 0;
    (void)nvs_get_u32(handle, "revision", &s_config.revision);
    if (nvs_get_u8(handle, "mod_claude", &byte_value) == ESP_OK) s_config.module_claude = byte_value != 0;
    if (nvs_get_u8(handle, "project_vis", &byte_value) == ESP_OK) s_config.project_visible = byte_value != 0;
    nvs_get_string(handle, "project", s_config.project_name, sizeof(s_config.project_name));
    if (nvs_get_u8(handle, "front_dbl", &byte_value) == ESP_OK && byte_value <= VIBE_DOUBLE_TOGGLE_MUTE) {
        s_config.front_double = (vibe_double_press_action_t)byte_value;
    }
    if (nvs_get_u8(handle, "side_one", &byte_value) == ESP_OK && byte_value <= VIBE_SIDE_NONE) {
        s_config.side_single = (vibe_side_press_action_t)byte_value;
    }
    nvs_close(handle);
    ESP_LOGI(TAG, "configuration loaded paired=%d revision=%lu", s_config.paired,
             (unsigned long)s_config.revision);
    return ESP_OK;
}

const vibe_device_config_t *vibe_device_config_get(void)
{
    return &s_config;
}

bool vibe_device_config_module_enabled(const char *module)
{
    if (!module) return false;
    if (strcmp(module, "codex") == 0) return s_config.module_codex;
    if (strcmp(module, "claude") == 0) return s_config.module_claude;
    if (strcmp(module, "connection") == 0) return s_config.module_connection;
    return false;
}

static bool valid_token(const char *value)
{
    size_t length = value ? strlen(value) : 0;
    if (length < 32 || length >= sizeof(s_config.pairing_token)) return false;
    for (size_t i = 0; i < length; ++i) {
        if (!(isalnum((unsigned char)value[i]) || value[i] == '-' || value[i] == '_')) return false;
    }
    return true;
}

static bool valid_uuid(const char *value)
{
    if (!value || strlen(value) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (value[i] != '-') return false;
        } else if (!isxdigit((unsigned char)value[i])) {
            return false;
        }
    }
    return true;
}

static bool valid_host(const char *value)
{
    size_t length = value ? strlen(value) : 0;
    if (length == 0 || length >= sizeof(s_config.fallback_host)) return false;
    for (size_t i = 0; i < length; ++i) {
        if (!(isalnum((unsigned char)value[i]) || value[i] == '.' || value[i] == '-')) return false;
    }
    return true;
}

esp_err_t vibe_device_config_apply_pairing_json(const char *json)
{
    cJSON *root = cJSON_Parse(json);
    ESP_RETURN_ON_FALSE(root != NULL, ESP_ERR_INVALID_ARG, TAG, "pair json");
    cJSON *schema = cJSON_GetObjectItemCaseSensitive(root, "schema_version");
    cJSON *pairing_id = cJSON_GetObjectItemCaseSensitive(root, "pairing_id");
    cJSON *device_id = cJSON_GetObjectItemCaseSensitive(root, "device_id");
    cJSON *token = cJSON_GetObjectItemCaseSensitive(root, "token");
    cJSON *bridge_id = cJSON_GetObjectItemCaseSensitive(root, "bridge_id");
    cJSON *host = cJSON_GetObjectItemCaseSensitive(root, "fallback_host");
    cJSON *port = cJSON_GetObjectItemCaseSensitive(root, "bridge_port");
    bool valid = cJSON_IsNumber(schema) && schema->valueint == 1 &&
                 cJSON_IsString(pairing_id) && valid_uuid(pairing_id->valuestring) &&
                 cJSON_IsString(device_id) && strcmp(device_id->valuestring, s_config.device_id) == 0 &&
                 cJSON_IsString(token) && valid_token(token->valuestring) &&
                 cJSON_IsString(bridge_id) && valid_uuid(bridge_id->valuestring) &&
                 cJSON_IsString(host) && valid_host(host->valuestring) &&
                 cJSON_IsNumber(port) && port->valueint > 0 && port->valueint <= 65535;
    if (!valid) {
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }

    vibe_device_config_t previous = s_config;
    strlcpy(s_config.pairing_token, token->valuestring, sizeof(s_config.pairing_token));
    strlcpy(s_config.pairing_id, pairing_id->valuestring, sizeof(s_config.pairing_id));
    strlcpy(s_config.bridge_id, bridge_id->valuestring, sizeof(s_config.bridge_id));
    strlcpy(s_config.fallback_host, host->valuestring, sizeof(s_config.fallback_host));
    s_config.bridge_port = (uint16_t)port->valueint;
    s_config.paired = true;
    cJSON_Delete(root);
    esp_err_t err = persist_pairing();
    if (err != ESP_OK) s_config = previous;
    return err;
}

static bool modules_from_json(cJSON *modules, bool *claude_enabled)
{
    if (!cJSON_IsArray(modules)) return false;
    bool codex = false;
    bool connection = false;
    bool claude = false;
    cJSON *item = NULL;
    cJSON_ArrayForEach(item, modules) {
        if (!cJSON_IsString(item)) continue;
        if (strcmp(item->valuestring, "codex") == 0) codex = true;
        if (strcmp(item->valuestring, "claude") == 0) claude = true;
        if (strcmp(item->valuestring, "connection") == 0) connection = true;
    }
    *claude_enabled = claude;
    return codex && connection;
}

esp_err_t vibe_device_config_apply_configuration_json(const char *json, bool *changed)
{
    if (changed) *changed = false;
    cJSON *root = cJSON_Parse(json);
    ESP_RETURN_ON_FALSE(root != NULL, ESP_ERR_INVALID_ARG, TAG, "config json");
    cJSON *schema = cJSON_GetObjectItemCaseSensitive(root, "schema_version");
    cJSON *revision = cJSON_GetObjectItemCaseSensitive(root, "revision");
    cJSON *modules = cJSON_GetObjectItemCaseSensitive(root, "modules");
    cJSON *project = cJSON_GetObjectItemCaseSensitive(root, "project");
    cJSON *buttons = cJSON_GetObjectItemCaseSensitive(root, "buttons");
    bool claude_enabled = false;
    bool valid = cJSON_IsNumber(schema) && schema->valueint == 1 &&
                 cJSON_IsNumber(revision) && revision->valuedouble >= 0 &&
                 modules_from_json(modules, &claude_enabled) &&
                 cJSON_IsObject(project) && cJSON_IsObject(buttons);
    if (!valid) {
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }
    uint32_t incoming_revision = (uint32_t)revision->valuedouble;
    if (incoming_revision <= s_config.revision) {
        cJSON_Delete(root);
        return ESP_OK;
    }

    cJSON *visible = cJSON_GetObjectItemCaseSensitive(project, "visible");
    cJSON *name = cJSON_GetObjectItemCaseSensitive(project, "name");
    cJSON *front = cJSON_GetObjectItemCaseSensitive(buttons, "front_double");
    cJSON *side = cJSON_GetObjectItemCaseSensitive(buttons, "side_single");
    if (!cJSON_IsBool(visible) || !cJSON_IsString(name) || strlen(name->valuestring) >= sizeof(s_config.project_name) ||
        !cJSON_IsString(front) || !cJSON_IsString(side)) {
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }

    vibe_double_press_action_t front_action = VIBE_DOUBLE_REFRESH_QUOTA;
    if (strcmp(front->valuestring, "show_status") == 0) front_action = VIBE_DOUBLE_SHOW_STATUS;
    else if (strcmp(front->valuestring, "home") == 0) front_action = VIBE_DOUBLE_HOME;
    else if (strcmp(front->valuestring, "toggle_mute") == 0) front_action = VIBE_DOUBLE_TOGGLE_MUTE;
    else if (strcmp(front->valuestring, "refresh_quota") != 0) {
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }
    vibe_side_press_action_t side_action = VIBE_SIDE_NEXT_PAGE;
    if (strcmp(side->valuestring, "none") == 0) side_action = VIBE_SIDE_NONE;
    else if (strcmp(side->valuestring, "next_page") != 0) {
        cJSON_Delete(root);
        return ESP_ERR_INVALID_ARG;
    }

    s_config.revision = incoming_revision;
    s_config.module_claude = claude_enabled;
    s_config.project_visible = cJSON_IsTrue(visible);
    strlcpy(s_config.project_name, name->valuestring, sizeof(s_config.project_name));
    s_config.front_double = front_action;
    s_config.side_single = side_action;
    cJSON_Delete(root);
    ESP_RETURN_ON_ERROR(persist_configuration(), TAG, "save config");
    if (changed) *changed = true;
    ESP_LOGI(TAG, "configuration applied revision=%lu", (unsigned long)s_config.revision);
    return ESP_OK;
}
