#pragma once

#include <stdbool.h>

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

#define VIBE_UI_H_RES 135
#define VIBE_UI_V_RES 240
#define VIBE_UI_VOICE_CIRCLE_OPTICAL_SCALE_Y 270

typedef struct vibe_ui vibe_ui_t;

typedef struct {
    bool wifi_connected;
    bool bridge_connected;
    int battery_percent;
    bool battery_charging;
    bool usb_powered;
    const char *provider_name;
    const lv_image_dsc_t *provider_icon;
    lv_color_t provider_accent;
    bool provider_implemented;
    const char *status;
    const char *project;
    bool project_visible;
    int quota_window_count;
    const char *quota_labels[2];
    int quota_values[2];
    bool quota_valid[2];
    bool quota_stale;
    bool sync_healthy;
    const char *footer_action;
} vibe_ui_home_state_t;

typedef enum {
    VIBE_UI_VOICE_IDLE = 0,
    VIBE_UI_VOICE_RECORDING,
    VIBE_UI_VOICE_TRANSCRIBING,
    VIBE_UI_VOICE_PENDING_SEND,
    VIBE_UI_VOICE_SENDING,
    VIBE_UI_VOICE_PASTED,
    VIBE_UI_VOICE_COPIED,
    VIBE_UI_VOICE_SENT,
    VIBE_UI_VOICE_FAILED,
    VIBE_UI_VOICE_EXPIRED,
} vibe_ui_voice_phase_t;

typedef enum {
    VIBE_UI_VOICE_FAILURE_NONE = 0,
    VIBE_UI_VOICE_FAILURE_UNCLEAR,
    VIBE_UI_VOICE_FAILURE_TRANSCRIPTION,
    VIBE_UI_VOICE_FAILURE_SEND,
} vibe_ui_voice_failure_t;

vibe_ui_t *vibe_ui_create(lv_obj_t *screen, const lv_image_dsc_t *initial_provider_icon);
void vibe_ui_render_home(vibe_ui_t *ui, const vibe_ui_home_state_t *state);
void vibe_ui_show_voice(vibe_ui_t *ui,
                        vibe_ui_voice_phase_t phase,
                        vibe_ui_voice_failure_t failure);
void vibe_ui_show_legacy_recording(vibe_ui_t *ui,
                                   const char *title,
                                   const char *hint,
                                   bool visible);

#ifdef __cplusplus
}
#endif
