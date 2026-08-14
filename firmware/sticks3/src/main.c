#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vibe_audio.h"
#include "vibe_board.h"
#include "vibe_device_config.h"
#include "vibe_discovery.h"
#include "vibe_stick_config.h"
#include "vibe_usb_pairing.h"
#include "vibe_ui.h"
#include "vibe_voice_interaction.h"
#include "button_gpio.h"
#include "cJSON.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_st7789.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "vibe_stick_ui_assets.h"
#include "iot_button.h"
#include "lvgl.h"
#include "nvs_flash.h"

#define LCD_HOST SPI2_HOST
#define LCD_H_RES 135
#define LCD_V_RES 240
#define LCD_X_GAP 52
#define LCD_Y_GAP 40
#define LCD_PIXEL_CLOCK_HZ (20 * 1000 * 1000)
#define LCD_BACKLIGHT_PWM_HZ 5000
#define LCD_BACKLIGHT_PWM_MAX 255
#define LCD_BACKLIGHT_DEFAULT 150
#define LVGL_DRAW_BUF_LINES 24
#define LVGL_TICK_PERIOD_MS 10
#define LVGL_TASK_STACK_BYTES 8192
#define LVGL_TASK_STACK_WARN_BYTES 1536
#define VIBE_HTTP_HEADER_BUFFER_BYTES 2048
#define PIN_BUTTON_FRONT 11
#define PIN_BUTTON_SIDE 12
#define PIN_LCD_MOSI 39
#define PIN_LCD_SCK 40
#define PIN_LCD_DC 45
#define PIN_LCD_CS 41
#define PIN_LCD_RST 21
#define PIN_LCD_BL 38

static const char *TAG = "vibe_stick";

typedef enum {
    VIBE_STICK_EVENT_POLL_STATE,
    VIBE_STICK_EVENT_SHORT_PRESS,
    VIBE_STICK_EVENT_DOUBLE_CLICK,
    VIBE_STICK_EVENT_LONG_START,
    VIBE_STICK_EVENT_LONG_STOP,
    VIBE_STICK_EVENT_PROVIDER_NEXT,
} agent_event_type_t;

typedef struct {
    agent_event_type_t type;
} agent_event_t;

typedef enum {
    PROVIDER_CODEX = 0,
    PROVIDER_CLAUDE = 1,
    PROVIDER_COUNT,
} agent_provider_t;

typedef struct {
    agent_provider_t id;
    const char *key;
    const char *display_name;
    const lv_image_dsc_t *icon;
    lv_color_t accent_color;
    bool enabled;
    bool implemented;
} agent_provider_config_t;

typedef struct {
    char time[8];
    bool wifi;
    bool ble;
    int battery;
    bool battery_charging;
    bool usb_powered;
    char codex_status[24];
    char project[40];
    int quota_5h;
    int quota_7d;
    bool quota_5h_valid;
    bool quota_7d_valid;
    char quota_updated_at[8];
    bool quota_stale;
    char alert_event_id[56];
    char alert_type[24];
    char alert_message[80];
} agent_state_t;

typedef struct {
    char status[24];
    char project[40];
    int quota_5h;
    int quota_7d;
    bool quota_5h_valid;
    bool quota_7d_valid;
    char quota_updated_at[8];
    bool quota_stale;
    char quota_5h_label[16];
    char quota_7d_label[16];
    int quota_window_count;
} provider_display_state_t;

typedef struct {
    char *data;
    int capacity;
    int used;
} http_response_capture_t;

static QueueHandle_t s_event_queue;
static SemaphoreHandle_t s_lvgl_lock;
static bool s_wifi_connected;
static bool s_recording_overlay_visible;
static bool s_long_press_active;
static char s_last_alert_event_id[56];
static char s_last_alert_type[24];
static bool s_alert_sound_baseline_ready;
static bool s_alert_muted;
static char s_recording_session_id[40];
static char s_recording_response[VIBE_STICK_RECORDING_RESPONSE_CAPACITY];
#if VIBE_STICK_ENABLE_M3B_VOICE
static vibe_voice_interaction_t s_voice_interaction;
#endif

static lv_display_t *s_display;
static vibe_ui_t *s_ui;

static agent_state_t s_state = {
    .time = "--:--",
    .wifi = false,
    .ble = false,
    .battery = 0,
    .battery_charging = false,
    .usb_powered = false,
    .codex_status = "OFFLINE",
    .project = "vibestick",
    .quota_5h = 0,
    .quota_7d = 0,
    .quota_5h_valid = false,
    .quota_7d_valid = false,
    .quota_updated_at = "",
    .quota_stale = false,
    .alert_event_id = "",
    .alert_type = "NONE",
    .alert_message = "",
};

static provider_display_state_t s_provider_states[PROVIDER_COUNT] = {
    [PROVIDER_CODEX] = {
        .status = "OFFLINE",
        .project = "vibestick",
        .quota_5h = 0,
        .quota_7d = 0,
        .quota_5h_valid = false,
        .quota_7d_valid = false,
        .quota_updated_at = "",
        .quota_stale = false,
        .quota_5h_label = "5H",
        .quota_7d_label = "7D",
        .quota_window_count = 2,
    },
    [PROVIDER_CLAUDE] = {
        .status = "OFFLINE",
        .project = "vibestick",
        .quota_5h = 0,
        .quota_7d = 0,
        .quota_5h_valid = false,
        .quota_7d_valid = false,
        .quota_updated_at = "",
        .quota_stale = false,
        .quota_5h_label = "5H",
        .quota_7d_label = "7D",
        .quota_window_count = 2,
    },
};

static const agent_provider_config_t s_provider_configs[] = {
    {
        .id = PROVIDER_CODEX,
        .key = "codex",
        .display_name = "Codex",
        .icon = &vibe_stick_provider_codex_icon_40,
        .accent_color = LV_COLOR_MAKE(0x4d, 0x82, 0xff),
        .enabled = true,
        .implemented = true,
    },
    {
        .id = PROVIDER_CLAUDE,
        .key = "claude",
        .display_name = "Claude",
        .icon = &vibe_stick_provider_claude_icon_40,
        .accent_color = LV_COLOR_MAKE(0xd9, 0x77, 0x57),
        .enabled = true,
        .implemented = true,
    },
};

static agent_provider_t s_current_provider = PROVIDER_CODEX;
static bool s_provider_manually_selected;

static void render_state(void);

static void queue_event(agent_event_type_t type)
{
    if (!s_event_queue) {
        return;
    }
    agent_event_t event = {.type = type};
    (void)xQueueSend(s_event_queue, &event, 0);
}

static const agent_provider_config_t *provider_config(agent_provider_t provider)
{
    for (size_t i = 0; i < sizeof(s_provider_configs) / sizeof(s_provider_configs[0]); ++i) {
        if (s_provider_configs[i].id == provider) {
            return &s_provider_configs[i];
        }
    }
    return &s_provider_configs[0];
}

static const agent_provider_config_t *current_provider_config(void)
{
    return provider_config(s_current_provider);
}

static provider_display_state_t *provider_display_state(agent_provider_t provider)
{
    if ((int)provider >= 0 && provider < PROVIDER_COUNT) {
        return &s_provider_states[provider];
    }
    return &s_provider_states[PROVIDER_CODEX];
}

static provider_display_state_t *current_provider_display_state(void)
{
    return provider_display_state(s_current_provider);
}

static bool provider_from_key(const char *key, agent_provider_t *provider)
{
    if (!key || key[0] == '\0') {
        return false;
    }
    for (size_t i = 0; i < sizeof(s_provider_configs) / sizeof(s_provider_configs[0]); ++i) {
        if (strcmp(s_provider_configs[i].key, key) == 0) {
            if (provider) {
                *provider = s_provider_configs[i].id;
            }
            return true;
        }
    }
    return false;
}

static bool set_current_provider_from_key(const char *key)
{
    agent_provider_t provider = PROVIDER_CODEX;
    if (provider_from_key(key, &provider) && vibe_device_config_module_enabled(key)) {
        s_current_provider = provider;
        return true;
    }
    return false;
}

static agent_provider_t next_enabled_provider(agent_provider_t current)
{
    const size_t count = sizeof(s_provider_configs) / sizeof(s_provider_configs[0]);
    size_t current_index = 0;
    for (size_t i = 0; i < count; ++i) {
        if (s_provider_configs[i].id == current) {
            current_index = i;
            break;
        }
    }
    for (size_t offset = 1; offset <= count; ++offset) {
        const size_t candidate_index = (current_index + offset) % count;
        if (s_provider_configs[candidate_index].enabled &&
            vibe_device_config_module_enabled(s_provider_configs[candidate_index].key)) {
            return s_provider_configs[candidate_index].id;
        }
    }
    return PROVIDER_CODEX;
}

static void switch_provider(void)
{
    if (s_recording_overlay_visible) {
        ESP_LOGI(TAG, "provider switch ignored while overlay is visible");
        return;
    }
    if (vibe_device_config_get()->side_single == VIBE_SIDE_NONE) {
        ESP_LOGI(TAG, "provider switch disabled by device configuration");
        return;
    }
    s_current_provider = next_enabled_provider(s_current_provider);
    s_provider_manually_selected = true;
    const agent_provider_config_t *provider = current_provider_config();
    ESP_LOGI(TAG, "provider switched to %s", provider->key);
    render_state();
}

static void lvgl_lock(void)
{
    if (s_lvgl_lock) {
        xSemaphoreTake(s_lvgl_lock, portMAX_DELAY);
    }
}

static void lvgl_unlock(void)
{
    if (s_lvgl_lock) {
        xSemaphoreGive(s_lvgl_lock);
    }
}

static void lvgl_tick_cb(void *arg)
{
    (void)arg;
    lv_tick_inc(LVGL_TICK_PERIOD_MS);
}

static void lvgl_task(void *arg)
{
    (void)arg;
    UBaseType_t last_reported_stack_free = LVGL_TASK_STACK_BYTES;
    while (true) {
        lvgl_lock();
        uint32_t wait_ms = lv_timer_handler();
        lvgl_unlock();
        UBaseType_t stack_free = uxTaskGetStackHighWaterMark(NULL);
        if (stack_free < last_reported_stack_free) {
            if (stack_free < LVGL_TASK_STACK_WARN_BYTES) {
                ESP_LOGW(TAG, "lvgl stack low-water=%u bytes", (unsigned)stack_free);
            } else {
                ESP_LOGI(TAG, "lvgl stack low-water=%u bytes", (unsigned)stack_free);
            }
            last_reported_stack_free = stack_free;
        }
        if (wait_ms < 5) {
            wait_ms = 5;
        }
        if (wait_ms > 250) {
            wait_ms = 250;
        }
        vTaskDelay(pdMS_TO_TICKS(wait_ms));
    }
}

static bool notify_lvgl_flush_ready(esp_lcd_panel_io_handle_t panel_io,
                                    esp_lcd_panel_io_event_data_t *edata,
                                    void *user_ctx)
{
    (void)panel_io;
    (void)edata;
    lv_display_flush_ready((lv_display_t *)user_ctx);
    return false;
}

static void lvgl_flush_cb(lv_display_t *display, const lv_area_t *area, uint8_t *px_map)
{
    esp_lcd_panel_handle_t panel = lv_display_get_user_data(display);
    int32_t width = area->x2 - area->x1 + 1;
    int32_t height = area->y2 - area->y1 + 1;
    lv_draw_sw_rgb565_swap(px_map, width * height);
    esp_lcd_panel_draw_bitmap(panel, area->x1, area->y1, area->x2 + 1, area->y2 + 1, px_map);
}

static void set_backlight(uint8_t brightness)
{
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, brightness);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

static void init_backlight(void)
{
    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_num = LEDC_TIMER_0,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .freq_hz = LCD_BACKLIGHT_PWM_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    ledc_channel_config_t channel = {
        .gpio_num = PIN_LCD_BL,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    set_backlight(LCD_BACKLIGHT_DEFAULT);
}

static esp_err_t init_display(void)
{
    init_backlight();

    spi_bus_config_t buscfg = {
        .sclk_io_num = PIN_LCD_SCK,
        .mosi_io_num = PIN_LCD_MOSI,
        .miso_io_num = -1,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = LCD_H_RES * LVGL_DRAW_BUF_LINES * sizeof(lv_color_t),
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &buscfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    esp_lcd_panel_io_handle_t io_handle = NULL;
    esp_lcd_panel_io_spi_config_t io_config = {
        .dc_gpio_num = PIN_LCD_DC,
        .cs_gpio_num = PIN_LCD_CS,
        .pclk_hz = LCD_PIXEL_CLOCK_HZ,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 10,
        .on_color_trans_done = notify_lvgl_flush_ready,
        .user_ctx = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &io_handle),
                        TAG, "panel io");

    esp_lcd_panel_handle_t panel = NULL;
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = PIN_LCD_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_st7789(io_handle, &panel_config, &panel), TAG, "panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel), TAG, "panel init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(panel, true), TAG, "panel invert");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_set_gap(panel, LCD_X_GAP, LCD_Y_GAP), TAG, "panel gap");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, true), TAG, "panel on");

    lv_init();
    s_display = lv_display_create(LCD_H_RES, LCD_V_RES);
    lv_display_set_user_data(s_display, panel);
    lv_display_set_flush_cb(s_display, lvgl_flush_cb);

    size_t buffer_size = LCD_H_RES * LVGL_DRAW_BUF_LINES * sizeof(lv_color_t);
    void *buf = heap_caps_malloc(buffer_size, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    ESP_RETURN_ON_FALSE(buf != NULL, ESP_ERR_NO_MEM, TAG, "lvgl buffer");
    lv_display_set_buffers(s_display, buf, NULL, buffer_size, LV_DISPLAY_RENDER_MODE_PARTIAL);
    esp_lcd_panel_io_callbacks_t callbacks = {
        .on_color_trans_done = notify_lvgl_flush_ready,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_panel_io_register_event_callbacks(io_handle, &callbacks, s_display),
                        TAG, "panel cb");

    const esp_timer_create_args_t tick_args = {
        .callback = lvgl_tick_cb,
        .name = "lvgl_tick",
    };
    esp_timer_handle_t tick_timer = NULL;
    ESP_RETURN_ON_ERROR(esp_timer_create(&tick_args, &tick_timer), TAG, "tick timer");
    ESP_RETURN_ON_ERROR(esp_timer_start_periodic(tick_timer, LVGL_TICK_PERIOD_MS * 1000), TAG, "tick start");

    BaseType_t task_created = xTaskCreate(
        lvgl_task, "lvgl", LVGL_TASK_STACK_BYTES, NULL, 3, NULL
    );
    ESP_RETURN_ON_FALSE(task_created == pdPASS, ESP_ERR_NO_MEM, TAG, "lvgl task");
    return ESP_OK;
}

static const char *footer_action_text(vibe_double_press_action_t action)
{
    switch (action) {
    case VIBE_DOUBLE_SHOW_STATUS: return "2X STATUS";
    case VIBE_DOUBLE_HOME: return "2X HOME";
    case VIBE_DOUBLE_TOGGLE_MUTE: return "2X MUTE";
    case VIBE_DOUBLE_REFRESH_QUOTA: return "2X REFRESH";
    }
    return "2X REFRESH";
}

static void render_state(void)
{
    if (!s_ui) return;

    const agent_provider_config_t *provider = current_provider_config();
    const provider_display_state_t *display_state = current_provider_display_state();
    const vibe_device_config_t *config = vibe_device_config_get();
    const bool implemented = provider->implemented;
    const bool quota_stale = implemented && display_state->quota_stale;
    const char *project = config->project_name[0] != '\0'
                              ? config->project_name
                              : display_state->project;
    const bool bridge_connected = config->paired && s_wifi_connected;

    vibe_ui_home_state_t ui_state = {
        .wifi_connected = s_wifi_connected,
        .bridge_connected = bridge_connected,
        .battery_percent = s_state.battery,
        .battery_charging = s_state.battery_charging,
        .usb_powered = s_state.usb_powered,
        .provider_name = provider->display_name,
        .provider_icon = provider->icon,
        .provider_accent = provider->accent_color,
        .provider_implemented = implemented,
        .status = implemented ? display_state->status : "UNIMPLEMENTED",
        .project = project,
        .project_visible = config->project_visible,
        .quota_window_count = implemented ? display_state->quota_window_count : 0,
        .quota_labels = {
            display_state->quota_5h_label,
            display_state->quota_7d_label,
        },
        .quota_values = {
            display_state->quota_5h,
            display_state->quota_7d,
        },
        .quota_valid = {
            implemented && display_state->quota_5h_valid,
            implemented && display_state->quota_7d_valid,
        },
        .quota_stale = quota_stale,
        .sync_healthy = bridge_connected && !quota_stale,
        .footer_action = footer_action_text(config->front_double),
    };

    lvgl_lock();
    vibe_ui_render_home(s_ui, &ui_state);
    lvgl_unlock();
}

static void show_recording_overlay(const char *title, const char *hint, bool visible)
{
    if (!s_ui) return;
    lvgl_lock();
    vibe_ui_show_legacy_recording(s_ui, title, hint, visible);
    s_recording_overlay_visible = visible;
    lvgl_unlock();
}

#if VIBE_STICK_ENABLE_M3B_VOICE
static vibe_ui_voice_phase_t ui_voice_phase(vibe_voice_phase_t phase)
{
    switch (phase) {
    case VIBE_VOICE_IDLE: return VIBE_UI_VOICE_IDLE;
    case VIBE_VOICE_RECORDING: return VIBE_UI_VOICE_RECORDING;
    case VIBE_VOICE_TRANSCRIBING: return VIBE_UI_VOICE_TRANSCRIBING;
    case VIBE_VOICE_PENDING_SEND: return VIBE_UI_VOICE_PENDING_SEND;
    case VIBE_VOICE_SENDING: return VIBE_UI_VOICE_SENDING;
    case VIBE_VOICE_PASTED: return VIBE_UI_VOICE_PASTED;
    case VIBE_VOICE_COPIED: return VIBE_UI_VOICE_COPIED;
    case VIBE_VOICE_SENT: return VIBE_UI_VOICE_SENT;
    case VIBE_VOICE_FAILED: return VIBE_UI_VOICE_FAILED;
    case VIBE_VOICE_EXPIRED: return VIBE_UI_VOICE_EXPIRED;
    }
    return VIBE_UI_VOICE_IDLE;
}

static vibe_ui_voice_failure_t ui_voice_failure(vibe_voice_failure_reason_t failure)
{
    switch (failure) {
    case VIBE_VOICE_FAILURE_UNCLEAR: return VIBE_UI_VOICE_FAILURE_UNCLEAR;
    case VIBE_VOICE_FAILURE_TRANSCRIPTION: return VIBE_UI_VOICE_FAILURE_TRANSCRIPTION;
    case VIBE_VOICE_FAILURE_SEND: return VIBE_UI_VOICE_FAILURE_SEND;
    case VIBE_VOICE_FAILURE_EXPIRED: return VIBE_UI_VOICE_FAILURE_NONE;
    case VIBE_VOICE_FAILURE_NONE: return VIBE_UI_VOICE_FAILURE_NONE;
    }
    return VIBE_UI_VOICE_FAILURE_NONE;
}

static void show_m3b_voice_overlay(void)
{
    if (!s_ui) return;
    lvgl_lock();
    vibe_ui_show_voice(s_ui,
                       ui_voice_phase(s_voice_interaction.phase),
                       ui_voice_failure(s_voice_interaction.failure_reason));
    s_recording_overlay_visible = s_voice_interaction.phase != VIBE_VOICE_IDLE;
    lvgl_unlock();

    ESP_LOGI(TAG, "voice overlay phase=%s",
             vibe_voice_phase_name(s_voice_interaction.phase));
}
#endif
static bool sound_for_alert_type(const char *type, agent_sound_t *sound)
{
    if (strcmp(type, "DONE") == 0 ||
        strcmp(type, "COMPLETED") == 0 ||
        strcmp(type, "SUCCESS") == 0) {
        *sound = VIBE_STICK_SOUND_DONE;
        return true;
    }
    if (strcmp(type, "ERROR") == 0 ||
        strcmp(type, "FAILED") == 0 ||
        strcmp(type, "FAILURE") == 0) {
        *sound = VIBE_STICK_SOUND_ERROR;
        return true;
    }
    if (strcmp(type, "APPROVAL") == 0 ||
        strcmp(type, "WAITING_APPROVAL") == 0 ||
        strcmp(type, "PENDING_APPROVAL") == 0 ||
        strcmp(type, "NEEDS_APPROVAL") == 0) {
        *sound = VIBE_STICK_SOUND_APPROVAL;
        return true;
    }
    return false;
}

static void remember_alert_sound_baseline(void)
{
    strlcpy(s_last_alert_event_id, s_state.alert_event_id, sizeof(s_last_alert_event_id));
    strlcpy(s_last_alert_type, s_state.alert_type, sizeof(s_last_alert_type));
    s_alert_sound_baseline_ready = true;
}

static bool should_play_alert_sound(void)
{
    agent_sound_t ignored;
    const bool target = sound_for_alert_type(s_state.alert_type, &ignored);

    if (s_alert_muted) {
        remember_alert_sound_baseline();
        return false;
    }

    if (!s_alert_sound_baseline_ready) {
        remember_alert_sound_baseline();
        return false;
    }

    if (!target) {
        remember_alert_sound_baseline();
        return false;
    }

    bool should_play = false;
    if (s_state.alert_event_id[0] != '\0') {
        should_play = strcmp(s_last_alert_event_id, s_state.alert_event_id) != 0;
    } else {
        should_play = strcmp(s_last_alert_type, s_state.alert_type) != 0;
    }
    remember_alert_sound_baseline();
    return should_play;
}

static void maybe_handle_alert(void)
{
    agent_sound_t sound;
    if (!sound_for_alert_type(s_state.alert_type, &sound)) {
        (void)should_play_alert_sound();
        return;
    }
    if (!should_play_alert_sound()) {
        return;
    }
    if (s_recording_overlay_visible || vibe_audio_is_recording()) {
        ESP_LOGI(TAG, "skip alert sound while recording overlay is active type=%s",
                 s_state.alert_type);
        return;
    }

    esp_err_t err = vibe_audio_play_sound(sound);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "alert sound skipped type=%s err=%s",
                 s_state.alert_type, esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "alert type=%s project=%s message=%s",
             s_state.alert_type, s_state.project, s_state.alert_message);
}

static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    if (evt->event_id != HTTP_EVENT_ON_DATA || !evt->user_data || !evt->data || evt->data_len <= 0) {
        return ESP_OK;
    }

    http_response_capture_t *capture = (http_response_capture_t *)evt->user_data;
    if (!capture->data || capture->capacity <= 0 || capture->used >= capture->capacity - 1) {
        return ESP_OK;
    }

    int remaining = capture->capacity - 1 - capture->used;
    int copy_len = evt->data_len < remaining ? evt->data_len : remaining;
    memcpy(capture->data + capture->used, evt->data, copy_len);
    capture->used += copy_len;
    capture->data[capture->used] = '\0';
    return ESP_OK;
}

static void set_firmware_headers(esp_http_client_handle_t client)
{
    const vibe_device_config_t *device_config = vibe_device_config_get();
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Name", FIRMWARE_NAME);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Version", FIRMWARE_VERSION);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Transport", TRANSPORT);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Build-Date", __DATE__ " " __TIME__);
    if (device_config->pairing_token[0] != '\0') {
        esp_http_client_set_header(client, "X-Vibe-Stick-Token", device_config->pairing_token);
    }
    if (device_config->paired) {
        esp_http_client_set_header(client, "X-Vibe-Stick-Device-ID", device_config->device_id);
    }
}

static esp_err_t http_request_timeout(const char *method, const char *path, const char *body,
                                      char *response, int response_len, int timeout_ms)
{
    char url[160];
    snprintf(url, sizeof(url), "http://%s:%u%s", vibe_bridge_discovery_host(),
             (unsigned)vibe_bridge_discovery_port(), path);
    http_response_capture_t capture = {
        .data = response,
        .capacity = response_len,
        .used = 0,
    };
    if (response && response_len > 0) {
        response[0] = '\0';
    }
    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = timeout_ms,
        .buffer_size = VIBE_HTTP_HEADER_BUFFER_BYTES,
        .buffer_size_tx = VIBE_HTTP_HEADER_BUFFER_BYTES,
        .event_handler = http_event_handler,
        .user_data = &capture,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    ESP_RETURN_ON_FALSE(client != NULL, ESP_ERR_NO_MEM, TAG, "http init");
    esp_http_client_set_method(client, strcmp(method, "POST") == 0 ? HTTP_METHOD_POST : HTTP_METHOD_GET);
    set_firmware_headers(client);
    if (body) {
        esp_http_client_set_header(client, "Content-Type", "application/json");
        esp_http_client_set_post_field(client, body, strlen(body));
    }
    esp_err_t err = esp_http_client_perform(client);
    int status_code = esp_http_client_get_status_code(client);
    if (err == ESP_OK && response && response_len > 0 && capture.used == 0) {
        ESP_LOGW(TAG, "http %s %s status=%d empty response", method, path, status_code);
    }
    esp_http_client_cleanup(client);
    if (err == ESP_OK && (status_code < 200 || status_code >= 300)) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return err;
}

static esp_err_t http_request(const char *method, const char *path, const char *body,
                              char *response, int response_len)
{
    return http_request_timeout(method, path, body, response, response_len, 2500);
}

static esp_err_t http_post_binary(const char *path, const uint8_t *body, size_t body_len,
                                  char *response, int response_len)
{
    char url[192];
    snprintf(url, sizeof(url), "http://%s:%u%s", vibe_bridge_discovery_host(),
             (unsigned)vibe_bridge_discovery_port(), path);
    http_response_capture_t capture = {
        .data = response,
        .capacity = response_len,
        .used = 0,
    };
    if (response && response_len > 0) {
        response[0] = '\0';
    }
    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = 20000,
        .buffer_size = VIBE_HTTP_HEADER_BUFFER_BYTES,
        .buffer_size_tx = VIBE_HTTP_HEADER_BUFFER_BYTES,
        .event_handler = http_event_handler,
        .user_data = &capture,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    ESP_RETURN_ON_FALSE(client != NULL, ESP_ERR_NO_MEM, TAG, "http init");
    esp_http_client_set_method(client, HTTP_METHOD_POST);
    set_firmware_headers(client);
    esp_http_client_set_header(client, "Content-Type", "application/octet-stream");
    esp_http_client_set_header(client, "X-Vibe-Stick-Sample-Rate", "16000");
    esp_http_client_set_header(client, "X-Vibe-Stick-Channels", "1");
    esp_http_client_set_header(client, "X-Vibe-Stick-Bits-Per-Sample", "16");
    esp_http_client_set_post_field(client, (const char *)body, body_len);
    esp_err_t err = esp_http_client_perform(client);
    int status_code = esp_http_client_get_status_code(client);
    if (err == ESP_OK && response && response_len > 0 && capture.used == 0) {
        ESP_LOGW(TAG, "http POST %s status=%d empty response", path, status_code);
    }
    esp_http_client_cleanup(client);
    if (err == ESP_OK && (status_code < 200 || status_code >= 300)) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return err;
}

static void copy_json_string(cJSON *root, const char *key, char *target, size_t target_len)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (cJSON_IsString(item) && item->valuestring) {
        strlcpy(target, item->valuestring, target_len);
    }
}

static bool json_percent_value(cJSON *item, int *value)
{
    if (cJSON_IsNumber(item)) {
        *value = item->valueint;
    } else if (cJSON_IsString(item) && item->valuestring && item->valuestring[0] != '\0') {
        char *end = NULL;
        long parsed = strtol(item->valuestring, &end, 10);
        if (!end || end == item->valuestring) {
            return false;
        }
        while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n' || *end == '%') {
            end++;
        }
        if (*end != '\0') {
            return false;
        }
        *value = (int)parsed;
    } else {
        return false;
    }
    if (*value < 0) {
        *value = 0;
    } else if (*value > 100) {
        *value = 100;
    }
    return true;
}

static bool parse_quota_windows(cJSON *source, provider_display_state_t *target)
{
    cJSON *windows = cJSON_GetObjectItemCaseSensitive(source, "quota_windows");
    if (!cJSON_IsArray(windows)) return false;

    target->quota_5h_valid = false;
    target->quota_7d_valid = false;
    target->quota_stale = false;
    strlcpy(target->quota_5h_label, "5H", sizeof(target->quota_5h_label));
    strlcpy(target->quota_7d_label, "7D", sizeof(target->quota_7d_label));
    int accepted = 0;
    cJSON *window = NULL;
    cJSON_ArrayForEach(window, windows) {
        if (!cJSON_IsObject(window) || accepted >= 2) continue;
        cJSON *label = cJSON_GetObjectItemCaseSensitive(window, "label");
        cJSON *remaining = cJSON_GetObjectItemCaseSensitive(window, "remaining_percent");
        cJSON *updated_at = cJSON_GetObjectItemCaseSensitive(window, "updated_at");
        cJSON *stale = cJSON_GetObjectItemCaseSensitive(window, "stale");
        int value = 0;
        bool valid = json_percent_value(remaining, &value);
        if (accepted == 0) {
            target->quota_5h_valid = valid;
            if (valid) target->quota_5h = value;
            if (cJSON_IsString(label) && label->valuestring) {
                strlcpy(target->quota_5h_label, label->valuestring, sizeof(target->quota_5h_label));
            }
        } else {
            target->quota_7d_valid = valid;
            if (valid) target->quota_7d = value;
            if (cJSON_IsString(label) && label->valuestring) {
                strlcpy(target->quota_7d_label, label->valuestring, sizeof(target->quota_7d_label));
            }
        }
        if (cJSON_IsString(updated_at) && updated_at->valuestring) {
            strlcpy(target->quota_updated_at, updated_at->valuestring, sizeof(target->quota_updated_at));
        }
        if (cJSON_IsBool(stale) && cJSON_IsTrue(stale)) target->quota_stale = true;
        accepted++;
    }
    target->quota_window_count = accepted;
    return true;
}

static void parse_provider_fields(cJSON *source, provider_display_state_t *target)
{
    copy_json_string(source, "status", target->status, sizeof(target->status));
    copy_json_string(source, "project", target->project, sizeof(target->project));
    copy_json_string(source, "quota_updated_at", target->quota_updated_at, sizeof(target->quota_updated_at));

    if (parse_quota_windows(source, target)) {
        return;
    }

    cJSON *quota_5h = cJSON_GetObjectItemCaseSensitive(source, "quota_5h_remaining");
    cJSON *quota_7d = cJSON_GetObjectItemCaseSensitive(source, "quota_7d_remaining");
    cJSON *stale = cJSON_GetObjectItemCaseSensitive(source, "quota_stale");
    int quota_value = 0;
    target->quota_5h_valid = json_percent_value(quota_5h, &quota_value);
    if (target->quota_5h_valid) {
        target->quota_5h = quota_value;
    }
    target->quota_7d_valid = json_percent_value(quota_7d, &quota_value);
    if (target->quota_7d_valid) {
        target->quota_7d = quota_value;
    }
    target->quota_stale = cJSON_IsBool(stale) ? cJSON_IsTrue(stale) : false;
    target->quota_window_count = 2;
    strlcpy(target->quota_5h_label, "5H", sizeof(target->quota_5h_label));
    strlcpy(target->quota_7d_label, "7D", sizeof(target->quota_7d_label));
}

static void parse_provider_json(cJSON *state_root, cJSON *provider)
{
    char provider_key[16] = "";
    copy_json_string(provider, "id", provider_key, sizeof(provider_key));
    if (provider_key[0] == '\0') {
        copy_json_string(state_root, "active_provider", provider_key, sizeof(provider_key));
    }
    agent_provider_t provider_id = s_current_provider;
    if (provider_key[0] != '\0' && provider_from_key(provider_key, &provider_id)) {
        if (!s_provider_manually_selected && vibe_device_config_module_enabled(provider_key)) {
            s_current_provider = provider_id;
        }
    }

    provider_display_state_t *display_state = provider_display_state(provider_id);
    parse_provider_fields(provider, display_state);
    ESP_LOGI(TAG, "provider parsed key=%s status=%s q5=%s%d q7=%s%d stale=%d",
             provider_config(provider_id)->key,
             display_state->status,
             display_state->quota_5h_valid ? "" : "invalid:",
             display_state->quota_5h,
             display_state->quota_7d_valid ? "" : "invalid:",
             display_state->quota_7d,
             display_state->quota_stale);
}

static void parse_codex_json(cJSON *codex)
{
    provider_display_state_t *display_state = provider_display_state(PROVIDER_CODEX);
    parse_provider_fields(codex, display_state);
    ESP_LOGI(TAG, "codex parsed status=%s q5=%s%d q7=%s%d stale=%d",
             display_state->status,
             display_state->quota_5h_valid ? "" : "invalid:",
             display_state->quota_5h,
             display_state->quota_7d_valid ? "" : "invalid:",
             display_state->quota_7d,
             display_state->quota_stale);
}

static bool parse_state_json(const char *json)
{
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *state_root = root;
    cJSON *wrapped_state = cJSON_GetObjectItemCaseSensitive(root, "state");
    if (cJSON_IsObject(wrapped_state)) {
        state_root = wrapped_state;
    }

    copy_json_string(state_root, "time", s_state.time, sizeof(s_state.time));
    cJSON *wifi = cJSON_GetObjectItemCaseSensitive(state_root, "wifi");
    cJSON *ble = cJSON_GetObjectItemCaseSensitive(state_root, "ble");
    s_state.wifi = cJSON_IsBool(wifi) ? cJSON_IsTrue(wifi) : s_state.wifi;
    s_state.ble = cJSON_IsBool(ble) ? cJSON_IsTrue(ble) : s_state.ble;

    cJSON *provider = cJSON_GetObjectItemCaseSensitive(state_root, "provider");
    cJSON *codex = cJSON_GetObjectItemCaseSensitive(state_root, "codex");
    if (cJSON_IsObject(provider)) {
        parse_provider_json(state_root, provider);
    } else {
        char active_provider[16] = "";
        copy_json_string(state_root, "active_provider", active_provider, sizeof(active_provider));
        if (active_provider[0] != '\0' && !s_provider_manually_selected) {
            set_current_provider_from_key(active_provider);
        }
    }
    if (cJSON_IsObject(codex)) {
        parse_codex_json(codex);
    }

    cJSON *alert = cJSON_GetObjectItemCaseSensitive(state_root, "alert");
    if (cJSON_IsObject(alert)) {
        copy_json_string(alert, "event_id", s_state.alert_event_id, sizeof(s_state.alert_event_id));
        copy_json_string(alert, "type", s_state.alert_type, sizeof(s_state.alert_type));
        copy_json_string(alert, "message", s_state.alert_message, sizeof(s_state.alert_message));
    }
    cJSON_Delete(root);
    return true;
}

static int64_t s_last_discovery_attempt_ms;

static void refresh_bridge_discovery_if_needed(void)
{
    const vibe_device_config_t *config = vibe_device_config_get();
    if (!config->paired || vibe_bridge_discovery_is_bonjour()) return;
    int64_t now_ms = esp_timer_get_time() / 1000;
    if (s_last_discovery_attempt_ms != 0 && now_ms - s_last_discovery_attempt_ms < 15000) return;
    s_last_discovery_attempt_ms = now_ms;
    esp_err_t err = vibe_bridge_discovery_resolve();
    if (err != ESP_OK) {
        ESP_LOGD(TAG, "Bonjour discovery unavailable; using fallback host");
    }
}

static void invalidate_bridge_discovery(void)
{
    if (!vibe_device_config_get()->paired) return;
    vibe_bridge_discovery_use_fallback();
    s_last_discovery_attempt_ms = 0;
}

static void sync_device_configuration(void)
{
    const vibe_device_config_t *config = vibe_device_config_get();
    if (!config->paired) return;
    refresh_bridge_discovery_if_needed();

    char response[1536] = {0};
    esp_err_t err = http_request("GET", VIBE_STICK_DEVICE_CONFIG_PATH, NULL, response, sizeof(response));
    if (err != ESP_OK || response[0] == '\0') {
        invalidate_bridge_discovery();
        return;
    }
    bool changed = false;
    err = vibe_device_config_apply_configuration_json(response, &changed);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "device configuration rejected: %s", esp_err_to_name(err));
        return;
    }
    config = vibe_device_config_get();
    if (!vibe_device_config_module_enabled(current_provider_config()->key)) {
        s_current_provider = PROVIDER_CODEX;
        s_provider_manually_selected = false;
    }
    if (changed) render_state();

    char body[64];
    snprintf(body, sizeof(body), "{\"revision\":%lu}", (unsigned long)config->revision);
    char ack_response[160] = {0};
    err = http_request("POST", VIBE_STICK_DEVICE_CONFIG_ACK_PATH, body, ack_response, sizeof(ack_response));
    if (err != ESP_OK) invalidate_bridge_discovery();
}

static void poll_state(void)
{
    refresh_bridge_discovery_if_needed();
    char response[1536] = {0};
    int battery_level = 0;
    if (vibe_board_battery_level(&battery_level) == ESP_OK) {
        s_state.battery = battery_level;
    }
    bool charging = false;
    bool usb_powered = false;
    bool power_read_ok = false;
    if (vibe_board_battery_charging(&charging) == ESP_OK) {
        s_state.battery_charging = charging;
        power_read_ok = true;
    }
    if (vibe_board_usb_powered(&usb_powered) == ESP_OK) {
        s_state.usb_powered = usb_powered;
        power_read_ok = true;
    }
    static bool last_power_logged = false;
    static bool last_charging = false;
    static bool last_usb_powered = false;
    if (power_read_ok &&
        (!last_power_logged ||
         last_charging != s_state.battery_charging ||
         last_usb_powered != s_state.usb_powered)) {
        ESP_LOGI(TAG, "power status battery=%d charging=%d usb=%d",
                 s_state.battery, s_state.battery_charging, s_state.usb_powered);
        last_power_logged = true;
        last_charging = s_state.battery_charging;
        last_usb_powered = s_state.usb_powered;
    }
    esp_err_t err = http_request("GET", VIBE_STICK_STATE_PATH, NULL, response, sizeof(response));
    if (err != ESP_OK || response[0] == '\0' || !parse_state_json(response)) {
        invalidate_bridge_discovery();
        provider_display_state_t *display_state = current_provider_display_state();
        strlcpy(display_state->status, "OFFLINE", sizeof(display_state->status));
        s_state.wifi = s_wifi_connected;
        render_state();
        return;
    }
    render_state();
    maybe_handle_alert();
}

static void post_simple_event(const char *event_name, const char *path)
{
    char body[96];
    snprintf(body, sizeof(body), "{\"event\":\"%s\",\"source\":\"sticks3\"}", event_name);
    char response[512] = {0};
    const char *target_path = path ? path : VIBE_STICK_EVENT_PATH;
    esp_err_t err = http_request("POST", target_path, body, response, sizeof(response));
    if (err == ESP_OK && response[0] != '\0' && parse_state_json(response)) {
        render_state();
    }
}

static bool parse_recording_session_id(const char *json, char *session_id, size_t session_id_len)
{
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *recording = cJSON_GetObjectItemCaseSensitive(root, "recording");
    cJSON *sid = cJSON_IsObject(recording) ? cJSON_GetObjectItemCaseSensitive(recording, "session_id") : NULL;
    bool ok = false;
    if (cJSON_IsString(sid) && sid->valuestring && sid->valuestring[0] != '\0') {
        strlcpy(session_id, sid->valuestring, session_id_len);
        ok = true;
    }
    cJSON_Delete(root);
    return ok;
}

static bool is_recording_failure_status(const char *status)
{
    return strcmp(status, "transcription_failed") == 0 ||
           strcmp(status, "transcript_rejected") == 0 ||
           strcmp(status, "paste_failed") == 0 ||
           strcmp(status, "audio_failed") == 0 ||
           strcmp(status, "audio_skipped") == 0 ||
           strcmp(status, "confirmation_unavailable") == 0 ||
           strcmp(status, "send_failed") == 0 ||
           strcmp(status, "start_failed") == 0 ||
           strcmp(status, "stop_failed") == 0;
}

static bool parse_recording_status(const char *json, char *status_text, size_t status_text_len)
{
    if (status_text_len > 0) {
        status_text[0] = '\0';
    }
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *recording = cJSON_GetObjectItemCaseSensitive(root, "recording");
    cJSON *status = cJSON_IsObject(recording) ?
        cJSON_GetObjectItemCaseSensitive(recording, "status") : NULL;
    bool ok = false;
    if (cJSON_IsString(status) && status->valuestring) {
        strlcpy(status_text, status->valuestring, status_text_len);
        ok = true;
    }
    cJSON_Delete(root);
    return ok;
}

#if VIBE_STICK_ENABLE_M3B_VOICE
static int parse_voice_interaction_version(const char *json)
{
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return 1;
    }
    cJSON *version = cJSON_GetObjectItemCaseSensitive(root, "voice_interaction_version");
    int parsed = cJSON_IsNumber(version) ? version->valueint : 1;
    cJSON_Delete(root);
    return parsed;
}

static bool parse_send_session(const char *json,
                               char *session_id,
                               size_t session_id_len,
                               char *phase,
                               size_t phase_len)
{
    if (session_id_len > 0) session_id[0] = '\0';
    if (phase_len > 0) phase[0] = '\0';
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *send_session = cJSON_GetObjectItemCaseSensitive(root, "send_session");
    cJSON *sid = cJSON_IsObject(send_session) ?
        cJSON_GetObjectItemCaseSensitive(send_session, "session_id") : NULL;
    cJSON *phase_item = cJSON_IsObject(send_session) ?
        cJSON_GetObjectItemCaseSensitive(send_session, "phase") : NULL;
    bool ok = cJSON_IsString(sid) && sid->valuestring &&
              cJSON_IsString(phase_item) && phase_item->valuestring;
    if (ok) {
        strlcpy(session_id, sid->valuestring, session_id_len);
        strlcpy(phase, phase_item->valuestring, phase_len);
    }
    cJSON_Delete(root);
    return ok;
}

static bool refresh_bridge_voice_capability(void)
{
    if (!vibe_device_config_get()->paired) {
        vibe_voice_set_bridge_version(&s_voice_interaction, 1);
        return false;
    }
    char response[384] = {0};
    esp_err_t err = http_request("GET", VIBE_STICK_HEALTH_PATH, NULL,
                                 response, sizeof(response));
    int version = err == ESP_OK && response[0] != '\0' ?
        parse_voice_interaction_version(response) : 1;
    vibe_voice_set_bridge_version(&s_voice_interaction, version);
    ESP_LOGI(TAG, "bridge voice interaction version=%d enabled=%d",
             version, vibe_voice_is_enabled(&s_voice_interaction));
    return vibe_voice_is_enabled(&s_voice_interaction);
}
#endif

static void generate_recording_session_id(char *session_id, size_t session_id_len)
{
    if (session_id_len < 33) {
        if (session_id_len > 0) {
            session_id[0] = '\0';
        }
        return;
    }
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; ++i) {
        uint32_t value = esp_random();
        session_id[i] = hex[value & 0x0f];
    }
    session_id[32] = '\0';
}

static void upload_recording_audio(void)
{
    size_t audio_len = 0;
    const uint8_t *audio = vibe_audio_data(&audio_len);
    if (!audio || audio_len == 0 || s_recording_session_id[0] == '\0') {
        ESP_LOGW(TAG, "skip audio upload audio=%p len=%u session=%s",
                 audio, (unsigned)audio_len, s_recording_session_id);
        return;
    }
    char path[96];
    snprintf(path, sizeof(path), "%s?session_id=%s", VIBE_STICK_RECORDING_AUDIO_PATH, s_recording_session_id);
    esp_err_t err = http_post_binary(
        path, audio, audio_len,
        s_recording_response, sizeof(s_recording_response)
    );
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "audio upload failed: %s", esp_err_to_name(err));
        return;
    }
    if (s_recording_response[0] != '\0' && parse_state_json(s_recording_response)) {
        render_state();
    }
}

static void handle_recording_start(void)
{
    generate_recording_session_id(s_recording_session_id, sizeof(s_recording_session_id));
    if (s_recording_session_id[0] == '\0') {
        ESP_LOGW(TAG, "recording start failed: no session id");
        return;
    }

#if VIBE_STICK_ENABLE_M3B_VOICE
    bool use_m3b = refresh_bridge_voice_capability();
    if (use_m3b &&
        !vibe_voice_begin_recording(&s_voice_interaction, s_recording_session_id)) {
        ESP_LOGI(TAG, "recording start ignored in voice phase=%s",
                 vibe_voice_phase_name(s_voice_interaction.phase));
        s_recording_session_id[0] = '\0';
        return;
    }
#endif

    esp_err_t audio_err = vibe_audio_start();
    if (audio_err != ESP_OK) {
        ESP_LOGW(TAG, "hardware recording start failed: %s", esp_err_to_name(audio_err));
        s_recording_session_id[0] = '\0';
#if VIBE_STICK_ENABLE_M3B_VOICE
        if (use_m3b) {
            vibe_voice_fail(&s_voice_interaction, esp_timer_get_time() / 1000);
            show_m3b_voice_overlay();
        }
#endif
        return;
    }
#if VIBE_STICK_ENABLE_M3B_VOICE
    if (use_m3b) show_m3b_voice_overlay();
    else show_recording_overlay("正在聆听", "松开发送", true);
#else
    show_recording_overlay("正在聆听", "松开发送", true);
#endif

    char body[224];
#if VIBE_STICK_ENABLE_M3B_VOICE
    if (use_m3b) {
        snprintf(body, sizeof(body),
                 "{\"event\":\"button_long_start\",\"source\":\"sticks3\","
                 "\"audio_source\":\"sticks3_pcm\",\"interaction_version\":%d,"
                 "\"session_id\":\"%s\"}",
                 VIBE_VOICE_INTERACTION_VERSION, s_recording_session_id);
    } else {
#endif
    snprintf(body, sizeof(body),
             "{\"event\":\"button_long_start\",\"source\":\"sticks3\","
             "\"audio_source\":\"sticks3_pcm\",\"session_id\":\"%s\"}",
             s_recording_session_id);
#if VIBE_STICK_ENABLE_M3B_VOICE
    }
#endif
    esp_err_t err = http_request(
        "POST", VIBE_STICK_RECORDING_START_PATH, body,
        s_recording_response, sizeof(s_recording_response)
    );
    if (err == ESP_OK && s_recording_response[0] != '\0') {
        char response_session_id[40] = {0};
        parse_recording_session_id(
            s_recording_response, response_session_id, sizeof(response_session_id)
        );
        if (response_session_id[0] != '\0' &&
            strcmp(response_session_id, s_recording_session_id) != 0) {
            ESP_LOGW(TAG, "bridge returned a different recording session id");
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (use_m3b) {
                (void)vibe_audio_stop();
                vibe_audio_clear();
                vibe_voice_fail(&s_voice_interaction, esp_timer_get_time() / 1000);
                s_recording_session_id[0] = '\0';
                show_m3b_voice_overlay();
                return;
            }
#endif
        }
#if VIBE_STICK_ENABLE_M3B_VOICE
        if (use_m3b &&
            parse_voice_interaction_version(s_recording_response) <
                VIBE_VOICE_INTERACTION_VERSION) {
            ESP_LOGW(TAG, "bridge did not confirm M3-B voice capability; using legacy flow");
            vibe_voice_set_bridge_version(&s_voice_interaction, 1);
            use_m3b = false;
        }
#endif
        if (parse_state_json(s_recording_response)) {
            render_state();
        }
    } else {
        ESP_LOGW(TAG, "recording start bridge request failed: %s", esp_err_to_name(err));
#if VIBE_STICK_ENABLE_M3B_VOICE
        if (use_m3b) {
            vibe_voice_set_bridge_version(&s_voice_interaction, 1);
        }
#endif
    }

}

static void handle_recording_stop(void)
{
#if VIBE_STICK_ENABLE_M3B_VOICE
    bool use_m3b = vibe_voice_is_enabled(&s_voice_interaction) &&
                   s_voice_interaction.phase == VIBE_VOICE_RECORDING &&
                   strcmp(s_voice_interaction.session_id, s_recording_session_id) == 0;
    if (use_m3b) {
        if (!vibe_voice_begin_transcribing(&s_voice_interaction,
                                           s_recording_session_id)) {
            vibe_voice_fail(&s_voice_interaction, esp_timer_get_time() / 1000);
        }
        show_m3b_voice_overlay();
    } else {
        show_recording_overlay("正在发送", "", true);
    }
#else
    show_recording_overlay("正在发送", "", true);
#endif
    if (s_recording_session_id[0] == '\0') {
        (void)vibe_audio_stop();
        vibe_audio_clear();
        poll_state();
        show_recording_overlay(NULL, NULL, false);
        return;
    }

    esp_err_t audio_err = vibe_audio_stop();
    if (audio_err != ESP_OK) {
        ESP_LOGW(TAG, "hardware recording stop failed: %s", esp_err_to_name(audio_err));
    }

    upload_recording_audio();
    vibe_audio_clear();

#if VIBE_STICK_ENABLE_M3B_VOICE
    if (!use_m3b) {
        show_recording_overlay("正在识别", "", true);
    }
#else
    show_recording_overlay("正在识别", "", true);
#endif
    char body[160];
#if VIBE_STICK_ENABLE_M3B_VOICE
    if (use_m3b) {
        snprintf(body, sizeof(body),
                 "{\"event\":\"button_long_stop\",\"source\":\"sticks3\","
                 "\"paste\":true,\"session_id\":\"%s\"}",
                 s_recording_session_id);
    } else {
#endif
        strlcpy(body,
                "{\"event\":\"button_long_stop\",\"source\":\"sticks3\",\"paste\":true}",
                sizeof(body));
#if VIBE_STICK_ENABLE_M3B_VOICE
    }
#endif
    esp_err_t err = http_request_timeout(
        "POST", VIBE_STICK_RECORDING_STOP_PATH, body,
        s_recording_response, sizeof(s_recording_response), 30000
    );
    bool recording_failed = false;
    char recording_status[32] = {0};
    if (err == ESP_OK && s_recording_response[0] != '\0') {
        if (parse_recording_status(
                s_recording_response, recording_status, sizeof(recording_status))) {
            recording_failed = is_recording_failure_status(recording_status);
            if (recording_failed) {
                ESP_LOGW(TAG, "recording failed status=%s", recording_status);
            }
        }
#if VIBE_STICK_ENABLE_M3B_VOICE
        if (use_m3b) {
            char response_session_id[40] = {0};
            bool session_ok = parse_recording_session_id(
                s_recording_response, response_session_id, sizeof(response_session_id)
            ) && strcmp(response_session_id, s_recording_session_id) == 0;
            bool version_ok =
                parse_voice_interaction_version(s_recording_response) >=
                VIBE_VOICE_INTERACTION_VERSION;
            if (!version_ok) {
                ESP_LOGW(TAG, "bridge dropped M3-B voice capability; using legacy result");
                vibe_voice_set_bridge_version(&s_voice_interaction, 1);
                use_m3b = false;
            } else if (!session_ok || recording_status[0] == '\0' ||
                       !vibe_voice_apply_recording_status(
                           &s_voice_interaction,
                           s_recording_session_id,
                           recording_status,
                           esp_timer_get_time() / 1000
                       )) {
                recording_failed = true;
                vibe_voice_fail(&s_voice_interaction, esp_timer_get_time() / 1000);
            }
        }
#endif
        if (parse_state_json(s_recording_response)) {
            render_state();
        }
    }
#if VIBE_STICK_ENABLE_M3B_VOICE
    if (use_m3b) {
        if (err != ESP_OK || recording_failed) {
            ESP_LOGW(TAG, "M3-B recording result failed err=%s status=%s",
                     esp_err_to_name(err), recording_status);
            vibe_voice_fail(&s_voice_interaction, esp_timer_get_time() / 1000);
        }
        show_m3b_voice_overlay();
        return;
    }
#endif
    if (err != ESP_OK || recording_failed) {
        ESP_LOGW(TAG, "recording stop bridge request failed: %s", esp_err_to_name(err));
        const char *title = (strcmp(recording_status, "audio_skipped") == 0 ||
                             strcmp(recording_status, "transcript_rejected") == 0)
            ? "未听清" : "识别失败";
        show_recording_overlay(title, "", true);
        vTaskDelay(pdMS_TO_TICKS(900));
    }
    s_recording_session_id[0] = '\0';
    poll_state();
    show_recording_overlay(NULL, NULL, false);
}

#if VIBE_STICK_ENABLE_M3B_VOICE
static void handle_send_confirmation(void)
{
    int64_t now_ms = esp_timer_get_time() / 1000;
    char session_id[VIBE_VOICE_SESSION_ID_CAPACITY];
    strlcpy(session_id, s_voice_interaction.session_id, sizeof(session_id));
    if (!vibe_voice_begin_confirmation(&s_voice_interaction, now_ms)) {
        show_m3b_voice_overlay();
        return;
    }
    show_m3b_voice_overlay();

    char body[96];
    snprintf(body, sizeof(body), "{\"session_id\":\"%s\"}", session_id);
    esp_err_t err = http_request_timeout(
        "POST", VIBE_STICK_RECORDING_CONFIRM_PATH, body,
        s_recording_response, sizeof(s_recording_response), 5000
    );
    char response_session_id[VIBE_VOICE_SESSION_ID_CAPACITY] = {0};
    char phase[24] = {0};
    bool sent = err == ESP_OK && s_recording_response[0] != '\0' &&
                parse_send_session(
                    s_recording_response,
                    response_session_id,
                    sizeof(response_session_id),
                    phase,
                    sizeof(phase)
                ) &&
                strcmp(response_session_id, session_id) == 0 &&
                strcmp(phase, "sent") == 0;
    vibe_voice_finish_confirmation(
        &s_voice_interaction, sent, esp_timer_get_time() / 1000
    );
    if (!sent) {
        ESP_LOGW(TAG, "send confirmation rejected err=%s phase=%s",
                 esp_err_to_name(err), phase);
    }
    if (s_recording_response[0] != '\0' &&
        parse_state_json(s_recording_response)) {
        render_state();
    }
    show_m3b_voice_overlay();
}
#endif

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    (void)arg;
    (void)event_data;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_connected = false;
        esp_wifi_connect();
        render_state();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        s_wifi_connected = true;
        render_state();
        queue_event(VIBE_STICK_EVENT_POLL_STATE);
    }
}

static esp_err_t init_wifi(void)
{
    if (strlen(VIBE_STICK_WIFI_SSID) == 0) {
        ESP_LOGW(TAG, "VIBE_STICK_WIFI_SSID is empty; Wi-Fi disabled");
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "event loop");
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL));
    wifi_config_t wifi_config = {0};
    strlcpy((char *)wifi_config.sta.ssid, VIBE_STICK_WIFI_SSID, sizeof(wifi_config.sta.ssid));
    strlcpy((char *)wifi_config.sta.password, VIBE_STICK_WIFI_PASSWORD, sizeof(wifi_config.sta.password));
    wifi_config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "wifi mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &wifi_config), TAG, "wifi config");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");
    return ESP_OK;
}

static void button_single_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_SHORT_PRESS);
}

static void button_double_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_DOUBLE_CLICK);
}

static void side_button_single_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_PROVIDER_NEXT);
}

static void button_long_start_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    s_long_press_active = true;
    queue_event(VIBE_STICK_EVENT_LONG_START);
}

static void button_up_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    if (s_long_press_active) {
        s_long_press_active = false;
        queue_event(VIBE_STICK_EVENT_LONG_STOP);
    }
}

static esp_err_t init_button(void)
{
    button_handle_t button = NULL;
    button_handle_t side_button = NULL;
    const button_config_t button_config = {0};
    const button_gpio_config_t gpio_config = {
        .gpio_num = PIN_BUTTON_FRONT,
        .active_level = 0,
        .enable_power_save = true,
    };
    ESP_RETURN_ON_ERROR(iot_button_new_gpio_device(&button_config, &gpio_config, &button), TAG, "button");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(button, BUTTON_SINGLE_CLICK, NULL, button_single_click_cb, NULL),
                        TAG, "button single");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(button, BUTTON_DOUBLE_CLICK, NULL, button_double_click_cb, NULL),
                        TAG, "button double");
    button_event_args_t long_press_args = {
        .long_press = {
            .press_time = 450,
        },
    };
    ESP_RETURN_ON_ERROR(iot_button_register_cb(button, BUTTON_LONG_PRESS_START, &long_press_args, button_long_start_cb, NULL),
                        TAG, "button long");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(button, BUTTON_PRESS_UP, NULL, button_up_cb, NULL),
                        TAG, "button up");

    const button_gpio_config_t side_gpio_config = {
        .gpio_num = PIN_BUTTON_SIDE,
        .active_level = 0,
        .enable_power_save = false,
    };
    ESP_RETURN_ON_ERROR(iot_button_new_gpio_device(&button_config, &side_gpio_config, &side_button), TAG, "side button");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(side_button, BUTTON_SINGLE_CLICK, NULL,
                                               side_button_single_click_cb, NULL),
                        TAG, "side button single");
    return ESP_OK;
}

static void app_task(void *arg)
{
    (void)arg;
    agent_event_t event;
    int64_t last_poll = 0;
    int64_t last_config_sync = 0;
    while (true) {
        int64_t now_ms = esp_timer_get_time() / 1000;
#if VIBE_STICK_ENABLE_M3B_VOICE
        if (vibe_voice_tick(&s_voice_interaction, now_ms)) {
            if (s_voice_interaction.phase == VIBE_VOICE_IDLE) {
                s_recording_session_id[0] = '\0';
            }
            show_m3b_voice_overlay();
        }
#endif
        if (s_wifi_connected && now_ms - last_poll >= VIBE_STICK_STATE_POLL_MS) {
            last_poll = now_ms;
            poll_state();
        }
        if (s_wifi_connected && vibe_device_config_get()->paired &&
            now_ms - last_config_sync >= 10000) {
            last_config_sync = now_ms;
            sync_device_configuration();
        }
        if (xQueueReceive(s_event_queue, &event, pdMS_TO_TICKS(100)) != pdTRUE) {
            continue;
        }
        switch (event.type) {
        case VIBE_STICK_EVENT_POLL_STATE:
            poll_state();
            break;
        case VIBE_STICK_EVENT_SHORT_PRESS:
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (vibe_voice_overlay_active(&s_voice_interaction)) {
                if (s_voice_interaction.phase == VIBE_VOICE_PENDING_SEND) {
                    handle_send_confirmation();
                } else if (s_voice_interaction.phase == VIBE_VOICE_PASTED ||
                           s_voice_interaction.phase == VIBE_VOICE_COPIED ||
                           s_voice_interaction.phase == VIBE_VOICE_SENT ||
                           s_voice_interaction.phase == VIBE_VOICE_FAILED ||
                           s_voice_interaction.phase == VIBE_VOICE_EXPIRED) {
                    vibe_voice_dismiss(&s_voice_interaction);
                    s_recording_session_id[0] = '\0';
                    show_m3b_voice_overlay();
                } else {
                    ESP_LOGI(TAG, "front click ignored in voice phase=%s",
                             vibe_voice_phase_name(s_voice_interaction.phase));
                }
                break;
            }
#endif
            post_simple_event("button_short", NULL);
            break;
        case VIBE_STICK_EVENT_DOUBLE_CLICK:
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (vibe_voice_overlay_active(&s_voice_interaction)) {
                ESP_LOGI(TAG, "front double click ignored in voice phase=%s",
                         vibe_voice_phase_name(s_voice_interaction.phase));
                break;
            }
#endif
            switch (vibe_device_config_get()->front_double) {
            case VIBE_DOUBLE_REFRESH_QUOTA:
                post_simple_event("button_double", VIBE_STICK_QUOTA_REFRESH_PATH);
                break;
            case VIBE_DOUBLE_TOGGLE_MUTE:
                s_alert_muted = !s_alert_muted;
                ESP_LOGI(TAG, "alert sounds muted=%d", s_alert_muted);
                break;
            case VIBE_DOUBLE_SHOW_STATUS:
            case VIBE_DOUBLE_HOME:
                post_simple_event("button_double", NULL);
                break;
            }
            poll_state();
            break;
        case VIBE_STICK_EVENT_LONG_START:
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (s_voice_interaction.phase == VIBE_VOICE_RECORDING ||
                s_voice_interaction.phase == VIBE_VOICE_TRANSCRIBING ||
                s_voice_interaction.phase == VIBE_VOICE_SENDING) {
                ESP_LOGI(TAG, "long press ignored in voice phase=%s",
                         vibe_voice_phase_name(s_voice_interaction.phase));
                break;
            }
#endif
            handle_recording_start();
            break;
        case VIBE_STICK_EVENT_LONG_STOP:
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (vibe_voice_is_enabled(&s_voice_interaction) &&
                s_voice_interaction.phase != VIBE_VOICE_RECORDING) {
                ESP_LOGI(TAG, "button up ignored in voice phase=%s",
                         vibe_voice_phase_name(s_voice_interaction.phase));
                break;
            }
#endif
            handle_recording_stop();
            break;
        case VIBE_STICK_EVENT_PROVIDER_NEXT:
#if VIBE_STICK_ENABLE_M3B_VOICE
            if (vibe_voice_overlay_active(&s_voice_interaction)) {
                ESP_LOGI(TAG, "side click ignored in voice phase=%s",
                         vibe_voice_phase_name(s_voice_interaction.phase));
                break;
            }
#endif
            switch_provider();
            break;
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "boot %s version=%s build=%s %s transport=%s",
             FIRMWARE_NAME, FIRMWARE_VERSION, __DATE__, __TIME__, TRANSPORT);
    esp_err_t nvs = nvs_flash_init();
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(nvs);
    }

    ESP_ERROR_CHECK(vibe_device_config_init());
#if VIBE_STICK_ENABLE_M3B_VOICE
    vibe_voice_interaction_init(&s_voice_interaction);
#endif

    ESP_ERROR_CHECK_WITHOUT_ABORT(vibe_board_init_power());
    s_event_queue = xQueueCreate(10, sizeof(agent_event_t));
    s_lvgl_lock = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(init_display());
    lvgl_lock();
    s_ui = vibe_ui_create(lv_display_get_screen_active(s_display),
                          current_provider_config()->icon);
    lvgl_unlock();
    ESP_ERROR_CHECK(s_ui ? ESP_OK : ESP_ERR_NO_MEM);
    render_state();
    ESP_ERROR_CHECK(init_button());
    ESP_ERROR_CHECK(vibe_audio_init());
    ESP_ERROR_CHECK(init_wifi());
    ESP_ERROR_CHECK_WITHOUT_ABORT(vibe_bridge_discovery_init());
    ESP_ERROR_CHECK_WITHOUT_ABORT(vibe_usb_pairing_start());
    xTaskCreate(app_task, "agent_app", 6144, NULL, 4, NULL);
}
