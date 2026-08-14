#include "vibe_ui.h"

#include <stdio.h>
#include <string.h>

#include "vibe_stick_ui_assets.h"

#define VOICE_WAVE_BAR_COUNT 6
#define VOICE_FOOTER_DOT_SIZE 4
#define VOICE_FOOTER_GAP 3
#define VOICE_FOOTER_STATUS_TOP 199
#define VOICE_FOOTER_DOT_TOP 203
#define VOICE_CIRCLE_OPTICAL_SCALE_Y VIBE_UI_VOICE_CIRCLE_OPTICAL_SCALE_Y
#define VOICE_SPINNER_SIZE 62
#define VOICE_SPINNER_TOP 50
#define VOICE_SPINNER_CORE_SIZE 16
#define VOICE_SPINNER_CENTER_SIZE 6
#define VOICE_PENDING_ARROW_SIZE 22
#define VOICE_PENDING_ARROW_GROUP_SIZE 26
#define VOICE_PENDING_ARROW_TOP 53
#define VOICE_RESULT_GROUP_WIDTH 68
#define VOICE_RESULT_GROUP_HEIGHT 74
#define VOICE_RESULT_GROUP_TOP 44
#define VOICE_RESULT_RING_SIZE 64
#define VOICE_RESULT_CORE_SIZE 44
#define BATTERY_FILL_MAX_WIDTH 20
#define FOCUS_PROVIDER_TEXT_LEFT 65
#define FOCUS_PROVIDER_TEXT_RIGHT 123
#define FOCUS_NO_PROJECT_TEXT_CENTER 92
#define FOCUS_STATUS_PREFIX_WIDTH 7

extern const lv_font_t vibe_stick_cn_16;
extern const lv_font_t vibe_stick_ui_10;
extern const lv_font_t vibe_stick_ui_12;
extern const lv_font_t vibe_stick_project_cn_10;

#define FONT_CN (&vibe_stick_cn_16)
#define FONT_UI_SMALL (&vibe_stick_ui_10)
#define FONT_UI (&vibe_stick_ui_12)
#define FONT_PROJECT (&vibe_stick_project_cn_10)

struct vibe_ui {
    lv_obj_t *screen;
    lv_obj_t *wifi_label;
    lv_obj_t *battery_label;
    lv_obj_t *battery_icon;
    lv_obj_t *battery_fill;
    lv_obj_t *battery_cap;
    lv_obj_t *battery_bolt;
    lv_obj_t *bridge_dot;
    lv_obj_t *focus_card;
    lv_obj_t *provider_icon;
    lv_obj_t *provider_label;
    lv_obj_t *status_dot;
    lv_obj_t *status_label;
    lv_obj_t *project_dot;
    lv_obj_t *project_label;
    lv_obj_t *quota_card;
    lv_obj_t *quota_title_labels[2];
    lv_obj_t *quota_single_remaining_label;
    lv_obj_t *quota_divider;
    lv_obj_t *quota_bars[2];
    lv_obj_t *quota_value_labels[2];
    lv_obj_t *quota_status_label;
    lv_obj_t *footer_sync_dot;
    lv_obj_t *footer_sync_label;
    lv_obj_t *footer_action_label;
    lv_obj_t *footer_divider;
    lv_obj_t *footer_voice_label;
    lv_obj_t *recording_overlay;
    lv_obj_t *recording_wave_group;
    lv_obj_t *recording_wave_bars[VOICE_WAVE_BAR_COUNT];
    lv_obj_t *recording_title;
    lv_obj_t *recording_hint;
    lv_obj_t *voice_secondary_hint;
    lv_obj_t *voice_header_label;
    lv_obj_t *voice_header_dot;
    lv_obj_t *voice_footer_dot;
    lv_obj_t *voice_footer_status;
    lv_obj_t *voice_footer_divider;
    lv_obj_t *voice_home_indicator;
    lv_obj_t *voice_spinner;
    lv_obj_t *voice_spinner_core;
    lv_obj_t *voice_spinner_center;
    lv_obj_t *voice_pending_group;
    lv_obj_t *voice_pending_arrow;
    lv_obj_t *voice_success_group;
    lv_obj_t *voice_success_ring;
    lv_obj_t *voice_failed_group;
    lv_obj_t *voice_failed_ring;
};

static vibe_ui_t s_ui;

static const lv_point_precise_t s_battery_bolt_points[] = {
    {3, 0},
    {1, 3},
    {3, 3},
    {2, 7},
    {6, 2},
    {4, 2},
};

static const lv_point_precise_t s_voice_arrow_points[] = {
    {0, 4}, {8, 4}, {5, 1}, {8, 4}, {5, 7},
};

static const lv_point_precise_t s_voice_check_points[] = {
    {0, 9}, {7, 16}, {21, 1},
};

static lv_obj_t *make_label(lv_obj_t *parent, const char *text, const lv_font_t *font,
                            lv_color_t color, int32_t width, lv_text_align_t align)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, color, 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
    lv_obj_set_width(label, width);
    lv_obj_set_style_text_align(label, align, 0);
    return label;
}

static lv_obj_t *make_bar(lv_obj_t *parent, int32_t width)
{
    lv_obj_t *bar = lv_bar_create(parent);
    lv_obj_set_size(bar, width, 5);
    lv_bar_set_range(bar, 0, 100);
    lv_obj_set_style_radius(bar, 3, 0);
    lv_obj_set_style_bg_color(bar, lv_color_hex(0x2a2d33), 0);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(bar, lv_color_hex(0xf4f5f7), LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, 3, LV_PART_INDICATOR);
    return bar;
}

static lv_obj_t *make_plain_obj(lv_obj_t *parent, int32_t w, int32_t h,
                                lv_color_t color, lv_opa_t opa, int32_t radius)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(obj);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_bg_color(obj, color, 0);
    lv_obj_set_style_bg_opa(obj, opa, 0);
    lv_obj_set_style_radius(obj, radius, 0);
    return obj;
}

static void apply_voice_circle_optical_scale(lv_obj_t *obj, int32_t size)
{
    lv_obj_set_style_transform_pivot_x(obj, size / 2, 0);
    lv_obj_set_style_transform_pivot_y(obj, size / 2, 0);
    lv_obj_set_style_transform_scale_y(obj, VOICE_CIRCLE_OPTICAL_SCALE_Y, 0);
}

static void center_voice_footer_status(vibe_ui_t *ui)
{
    if (!ui->voice_footer_dot || !ui->voice_footer_status) {
        return;
    }

    lv_obj_update_layout(ui->voice_footer_status);
    int32_t group_width = VOICE_FOOTER_DOT_SIZE + VOICE_FOOTER_GAP +
                          lv_obj_get_width(ui->voice_footer_status);
    int32_t group_left = (VIBE_UI_H_RES - group_width + 1) / 2;
    lv_obj_align(ui->voice_footer_dot, LV_ALIGN_TOP_LEFT,
                 group_left, VOICE_FOOTER_DOT_TOP);
    lv_obj_align(ui->voice_footer_status, LV_ALIGN_TOP_LEFT,
                 group_left + VOICE_FOOTER_DOT_SIZE + VOICE_FOOTER_GAP,
                 VOICE_FOOTER_STATUS_TOP);
}

static const char *status_text_for(const char *status)
{
    if (strcmp(status, "RUNNING") == 0) return "运行中";
    if (strcmp(status, "DONE") == 0) return "已完成";
    if (strcmp(status, "APPROVAL") == 0) return "待确认";
    if (strcmp(status, "ERROR") == 0) return "出错";
    if (strcmp(status, "OFFLINE") == 0) return "离线";
    return "待命";
}

static void set_battery_ui(vibe_ui_t *ui, int battery_value, bool charging, bool usb_powered)
{
    if (battery_value < 0) battery_value = 0;
    else if (battery_value > 100) battery_value = 100;

    char battery[8];
    if (battery_value > 0) snprintf(battery, sizeof(battery), "%d%%", battery_value);
    else snprintf(battery, sizeof(battery), "--%%");
    lv_label_set_text(ui->battery_label, battery);

    int fill_width = battery_value > 0 ? (battery_value * BATTERY_FILL_MAX_WIDTH) / 100 : 0;
    if (fill_width < 1 && battery_value > 0) fill_width = 1;

    const bool external_power = charging || usb_powered;
    const lv_color_t normal_color = lv_color_hex(0xf3f4f6);
    const lv_color_t charging_color = lv_color_hex(0x32d583);
    lv_obj_set_style_border_color(ui->battery_icon, normal_color, 0);
    lv_obj_set_style_bg_color(ui->battery_fill, external_power ? charging_color : normal_color, 0);
    lv_obj_set_style_bg_color(ui->battery_cap, normal_color, 0);
    lv_obj_set_width(ui->battery_fill, fill_width);
    if (external_power) lv_obj_clear_flag(ui->battery_bolt, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(ui->battery_bolt, LV_OBJ_FLAG_HIDDEN);
}

static void wave_bar_height_cb(void *obj, int32_t height)
{
    lv_obj_set_height((lv_obj_t *)obj, height);
}

static void stop_recording_wave(vibe_ui_t *ui)
{
    static const int heights[VOICE_WAVE_BAR_COUNT] = {22, 38, 56, 42, 26, 12};
    for (int i = 0; i < VOICE_WAVE_BAR_COUNT; ++i) {
        if (ui->recording_wave_bars[i]) {
            lv_anim_delete(ui->recording_wave_bars[i], NULL);
            lv_obj_set_height(ui->recording_wave_bars[i], heights[i]);
        }
    }
}

static void start_recording_wave(vibe_ui_t *ui)
{
    static const int min_heights[VOICE_WAVE_BAR_COUNT] = {12, 18, 24, 18, 12, 8};
    static const int max_heights[VOICE_WAVE_BAR_COUNT] = {28, 44, 56, 48, 34, 24};
    stop_recording_wave(ui);
    for (int i = 0; i < VOICE_WAVE_BAR_COUNT; ++i) {
        lv_anim_t anim;
        lv_anim_init(&anim);
        lv_anim_set_var(&anim, ui->recording_wave_bars[i]);
        lv_anim_set_values(&anim, min_heights[i], max_heights[i]);
        lv_anim_set_duration(&anim, 460);
        lv_anim_set_playback_duration(&anim, 460);
        lv_anim_set_delay(&anim, i * 70);
        lv_anim_set_repeat_count(&anim, LV_ANIM_REPEAT_INFINITE);
        lv_anim_set_exec_cb(&anim, wave_bar_height_cb);
        lv_anim_start(&anim);
    }
}

static void voice_arc_rotation_cb(void *obj, int32_t rotation)
{
    lv_arc_set_rotation((lv_obj_t *)obj, rotation);
}

static void voice_opacity_cb(void *obj, int32_t opacity)
{
    lv_obj_set_style_opa((lv_obj_t *)obj, (lv_opa_t)opacity, 0);
}

static void stop_voice_visual_animations(vibe_ui_t *ui)
{
    if (ui->voice_spinner) lv_anim_delete(ui->voice_spinner, voice_arc_rotation_cb);
    if (ui->voice_pending_arrow) lv_anim_delete(ui->voice_pending_arrow, voice_opacity_cb);
    if (ui->voice_success_ring) lv_anim_delete(ui->voice_success_ring, voice_opacity_cb);
    if (ui->voice_failed_ring) lv_anim_delete(ui->voice_failed_ring, voice_opacity_cb);
    if (ui->voice_pending_arrow) lv_obj_set_style_opa(ui->voice_pending_arrow, LV_OPA_COVER, 0);
    if (ui->voice_success_ring) lv_obj_set_style_opa(ui->voice_success_ring, LV_OPA_COVER, 0);
    if (ui->voice_failed_ring) lv_obj_set_style_opa(ui->voice_failed_ring, LV_OPA_COVER, 0);
}

static void start_voice_spinner(vibe_ui_t *ui)
{
    lv_anim_t anim;
    lv_anim_init(&anim);
    lv_anim_set_var(&anim, ui->voice_spinner);
    lv_anim_set_values(&anim, 0, 360);
    lv_anim_set_duration(&anim, 900);
    lv_anim_set_repeat_count(&anim, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_exec_cb(&anim, voice_arc_rotation_cb);
    lv_anim_start(&anim);
}

static void start_voice_breathe(lv_obj_t *obj)
{
    lv_anim_t anim;
    lv_anim_init(&anim);
    lv_anim_set_var(&anim, obj);
    lv_anim_set_values(&anim, LV_OPA_60, LV_OPA_COVER);
    lv_anim_set_duration(&anim, 440);
    lv_anim_set_playback_duration(&anim, 440);
    lv_anim_set_repeat_count(&anim, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_exec_cb(&anim, voice_opacity_cb);
    lv_anim_start(&anim);
}

static void set_voice_object_visible(lv_obj_t *obj, bool visible)
{
    if (!obj) return;
    if (visible) lv_obj_clear_flag(obj, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
}

static void hide_voice_visuals(vibe_ui_t *ui)
{
    set_voice_object_visible(ui->recording_wave_group, false);
    set_voice_object_visible(ui->voice_spinner, false);
    set_voice_object_visible(ui->voice_spinner_core, false);
    set_voice_object_visible(ui->voice_spinner_center, false);
    set_voice_object_visible(ui->voice_pending_group, false);
    set_voice_object_visible(ui->voice_success_group, false);
    set_voice_object_visible(ui->voice_failed_group, false);
}

static void set_m3b_voice_chrome_visible(vibe_ui_t *ui, bool visible)
{
    lv_obj_t *objects[] = {
        ui->voice_header_label,
        ui->voice_header_dot,
        ui->voice_footer_dot,
        ui->voice_footer_status,
        ui->voice_footer_divider,
        ui->voice_home_indicator,
        ui->voice_secondary_hint,
    };
    for (size_t i = 0; i < sizeof(objects) / sizeof(objects[0]); ++i) {
        set_voice_object_visible(objects[i], visible);
    }
}

vibe_ui_t *vibe_ui_create(lv_obj_t *screen, const lv_image_dsc_t *initial_provider_icon)
{
    if (!screen) return NULL;

    vibe_ui_t *ui = &s_ui;
    memset(ui, 0, sizeof(*ui));
    ui->screen = screen;

    lv_obj_set_style_bg_color(screen, lv_color_hex(0x050608), 0);
    lv_obj_set_style_pad_all(screen, 0, 0);

    ui->wifi_label = make_label(screen, "WiFi", &lv_font_montserrat_10,
                                lv_color_hex(0xf3f4f6), 22, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(ui->wifi_label, LV_ALIGN_TOP_LEFT, 8, 9);

    ui->bridge_dot = make_plain_obj(screen, 5, 5, lv_color_hex(0x32d583),
                                    LV_OPA_COVER, LV_RADIUS_CIRCLE);
    lv_obj_align(ui->bridge_dot, LV_ALIGN_TOP_LEFT, 35, 11);

    ui->battery_label = make_label(screen, "--%", &lv_font_montserrat_10,
                                   lv_color_hex(0xf3f4f6), 26, LV_TEXT_ALIGN_RIGHT);
    lv_obj_align(ui->battery_label, LV_ALIGN_TOP_RIGHT, -37, 9);
    ui->battery_icon = make_plain_obj(screen, 26, 13, lv_color_hex(0x000000),
                                      LV_OPA_TRANSP, 3);
    lv_obj_set_style_border_width(ui->battery_icon, 1, 0);
    lv_obj_set_style_border_color(ui->battery_icon, lv_color_hex(0xf3f4f6), 0);
    lv_obj_align(ui->battery_icon, LV_ALIGN_TOP_RIGHT, -8, 8);
    ui->battery_fill = make_plain_obj(ui->battery_icon, 0, 9, lv_color_hex(0xf3f4f6),
                                      LV_OPA_COVER, 2);
    lv_obj_align(ui->battery_fill, LV_ALIGN_LEFT_MID, 2, 0);
    ui->battery_bolt = lv_line_create(ui->battery_icon);
    lv_line_set_points(ui->battery_bolt, s_battery_bolt_points,
                       sizeof(s_battery_bolt_points) / sizeof(s_battery_bolt_points[0]));
    lv_obj_set_style_line_width(ui->battery_bolt, 1, 0);
    lv_obj_set_style_line_color(ui->battery_bolt, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_line_rounded(ui->battery_bolt, true, 0);
    lv_obj_align(ui->battery_bolt, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_flag(ui->battery_bolt, LV_OBJ_FLAG_HIDDEN);
    ui->battery_cap = make_plain_obj(screen, 2, 7, lv_color_hex(0xf3f4f6),
                                     LV_OPA_COVER, 1);
    lv_obj_align_to(ui->battery_cap, ui->battery_icon, LV_ALIGN_OUT_RIGHT_MID, 1, 0);

    ui->focus_card = make_plain_obj(screen, VIBE_UI_H_RES - 16, 81,
                                    lv_color_hex(0x0c0f14), LV_OPA_COVER, 9);
    lv_obj_set_style_border_width(ui->focus_card, 1, 0);
    lv_obj_set_style_border_color(ui->focus_card, lv_color_hex(0x202631), 0);
    lv_obj_align(ui->focus_card, LV_ALIGN_TOP_MID, 0, 30);

    ui->provider_icon = lv_image_create(screen);
    if (initial_provider_icon) lv_image_set_src(ui->provider_icon, initial_provider_icon);
    lv_obj_align(ui->provider_icon, LV_ALIGN_TOP_LEFT, 18, 52);

    ui->status_dot = make_plain_obj(screen, 5, 5, lv_color_hex(0xf3f4f6),
                                    LV_OPA_COVER, LV_RADIUS_CIRCLE);
    lv_obj_align(ui->status_dot, LV_ALIGN_TOP_LEFT, 82, 63);

    ui->provider_label = make_label(screen, "CODEX", &lv_font_montserrat_10,
                                    lv_color_hex(0x9fa8b6), 52, LV_TEXT_ALIGN_CENTER);
    lv_obj_set_style_text_letter_space(ui->provider_label, 1, 0);
    lv_obj_align(ui->provider_label, LV_ALIGN_TOP_LEFT, 78, 43);

    ui->status_label = make_label(screen, "待命", FONT_CN, lv_color_hex(0xf3f4f6),
                                  42, LV_TEXT_ALIGN_RIGHT);
    lv_obj_set_style_text_letter_space(ui->status_label, 1, 0);
    lv_obj_align(ui->status_label, LV_ALIGN_TOP_RIGHT, -16, 58);

    ui->project_dot = make_plain_obj(screen, 3, 3, lv_color_hex(0x0a84ff),
                                     LV_OPA_COVER, LV_RADIUS_CIRCLE);
    ui->project_label = make_label(screen, "VibeStick", FONT_PROJECT,
                                   lv_color_hex(0xaeb4bf), 88, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->project_dot, LV_ALIGN_TOP_MID, -22, 92);
    lv_obj_align(ui->project_label, LV_ALIGN_TOP_MID, 5, 87);

    ui->quota_card = make_plain_obj(screen, VIBE_UI_H_RES - 16, 88,
                                    lv_color_hex(0x0c0f14), LV_OPA_COVER, 9);
    lv_obj_set_style_border_width(ui->quota_card, 1, 0);
    lv_obj_set_style_border_color(ui->quota_card, lv_color_hex(0x202631), 0);
    lv_obj_align(ui->quota_card, LV_ALIGN_TOP_MID, 0, 116);

    ui->quota_divider = make_plain_obj(ui->quota_card, 1, 61,
                                       lv_color_hex(0x282e38), LV_OPA_COVER, 1);
    lv_obj_align(ui->quota_divider, LV_ALIGN_CENTER, 0, 1);

    ui->quota_title_labels[0] = make_label(screen, "5H 剩余", FONT_UI,
                                           lv_color_hex(0x8a9099), 44,
                                           LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->quota_title_labels[0], LV_ALIGN_TOP_LEFT, 16, 124);
    ui->quota_value_labels[0] = make_label(screen, "--%", &lv_font_montserrat_20,
                                           lv_color_hex(0xf3f4f6), 54,
                                           LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->quota_value_labels[0], LV_ALIGN_TOP_LEFT, 10, 148);
    ui->quota_bars[0] = make_bar(screen, 40);
    lv_obj_align(ui->quota_bars[0], LV_ALIGN_TOP_LEFT, 18, 183);

    ui->quota_title_labels[1] = make_label(screen, "7D 剩余", FONT_UI,
                                           lv_color_hex(0x8a9099), 44,
                                           LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->quota_title_labels[1], LV_ALIGN_TOP_RIGHT, -16, 124);
    ui->quota_single_remaining_label = make_label(screen, "LEFT", &lv_font_montserrat_12,
                                                  lv_color_hex(0x8a9099), 36,
                                                  LV_TEXT_ALIGN_RIGHT);
    lv_obj_align(ui->quota_single_remaining_label, LV_ALIGN_TOP_RIGHT, -17, 124);
    lv_obj_add_flag(ui->quota_single_remaining_label, LV_OBJ_FLAG_HIDDEN);
    ui->quota_value_labels[1] = make_label(screen, "--%", &lv_font_montserrat_20,
                                           lv_color_hex(0xf3f4f6), 54,
                                           LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->quota_value_labels[1], LV_ALIGN_TOP_RIGHT, -10, 148);
    ui->quota_bars[1] = make_bar(screen, 40);
    lv_obj_align(ui->quota_bars[1], LV_ALIGN_TOP_RIGHT, -18, 183);
    ui->quota_status_label = make_label(screen, "WAIT", &lv_font_montserrat_10,
                                        lv_color_hex(0x686e78), 84,
                                        LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->quota_status_label, LV_ALIGN_TOP_MID, 0, 207);
    lv_obj_add_flag(ui->quota_status_label, LV_OBJ_FLAG_HIDDEN);

    ui->footer_sync_dot = make_plain_obj(screen, 3, 3, lv_color_hex(0x32d583),
                                         LV_OPA_COVER, LV_RADIUS_CIRCLE);
    lv_obj_align(ui->footer_sync_dot, LV_ALIGN_TOP_LEFT, 9, 213);
    ui->footer_sync_label = make_label(screen, "SYNC", &lv_font_montserrat_10,
                                       lv_color_hex(0x8c95a3), 42, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(ui->footer_sync_label, LV_ALIGN_TOP_LEFT, 15, 208);
    ui->footer_action_label = make_label(screen, "2X REFRESH", &lv_font_montserrat_10,
                                         lv_color_hex(0x8c95a3), 62, LV_TEXT_ALIGN_RIGHT);
    lv_obj_align(ui->footer_action_label, LV_ALIGN_TOP_RIGHT, -8, 208);
    ui->footer_divider = make_plain_obj(screen, 119, 1, lv_color_hex(0x191d24),
                                        LV_OPA_COVER, 1);
    lv_obj_align(ui->footer_divider, LV_ALIGN_TOP_MID, 0, 222);
    ui->footer_voice_label = make_label(screen, "HOLD TO SPEAK", &lv_font_montserrat_10,
                                        lv_color_hex(0xb9c0ca), 119,
                                        LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->footer_voice_label, LV_ALIGN_TOP_MID, 0, 226);

    ui->recording_overlay = lv_obj_create(screen);
    lv_obj_set_size(ui->recording_overlay, VIBE_UI_H_RES, VIBE_UI_V_RES);
    lv_obj_align(ui->recording_overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_radius(ui->recording_overlay, 0, 0);
    lv_obj_set_style_bg_color(ui->recording_overlay, lv_color_hex(0x050608), 0);
    lv_obj_set_style_bg_opa(ui->recording_overlay, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ui->recording_overlay, 0, 0);
    lv_obj_set_style_pad_all(ui->recording_overlay, 0, 0);
    lv_obj_add_flag(ui->recording_overlay, LV_OBJ_FLAG_HIDDEN);

    ui->voice_header_label = make_label(ui->recording_overlay, "VOICE",
                                        &lv_font_montserrat_8,
                                        lv_color_hex(0x9fa8b6), 52,
                                        LV_TEXT_ALIGN_LEFT);
    lv_obj_set_style_text_letter_space(ui->voice_header_label, 1, 0);
    lv_obj_align(ui->voice_header_label, LV_ALIGN_TOP_LEFT, 9, 8);
    ui->voice_header_dot = make_plain_obj(ui->recording_overlay, 6, 6,
                                          lv_color_hex(0x0a84ff), LV_OPA_COVER,
                                          LV_RADIUS_CIRCLE);
    lv_obj_align(ui->voice_header_dot, LV_ALIGN_TOP_RIGHT, -8, 10);

    ui->recording_wave_group = lv_obj_create(ui->recording_overlay);
    lv_obj_remove_style_all(ui->recording_wave_group);
    lv_obj_set_size(ui->recording_wave_group, 82, 60);
    lv_obj_set_flex_flow(ui->recording_wave_group, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(ui->recording_wave_group, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(ui->recording_wave_group, 6, 0);
    lv_obj_align(ui->recording_wave_group, LV_ALIGN_TOP_MID, 0, 50);
    static const int initial_wave_heights[VOICE_WAVE_BAR_COUNT] = {22, 38, 56, 42, 26, 12};
    for (int i = 0; i < VOICE_WAVE_BAR_COUNT; ++i) {
        ui->recording_wave_bars[i] = make_plain_obj(
            ui->recording_wave_group, 5, initial_wave_heights[i],
            lv_color_hex(0xf4f5f7), LV_OPA_COVER, 3
        );
    }

    ui->voice_spinner = lv_arc_create(ui->recording_overlay);
    lv_obj_set_size(ui->voice_spinner, VOICE_SPINNER_SIZE, VOICE_SPINNER_SIZE);
    lv_obj_align(ui->voice_spinner, LV_ALIGN_TOP_MID, 0, VOICE_SPINNER_TOP);
    lv_arc_set_bg_angles(ui->voice_spinner, 0, 360);
    lv_arc_set_angles(ui->voice_spinner, 0, 95);
    lv_obj_set_style_arc_width(ui->voice_spinner, 5, LV_PART_MAIN);
    lv_obj_set_style_arc_color(ui->voice_spinner, lv_color_hex(0x242a35), LV_PART_MAIN);
    lv_obj_set_style_arc_width(ui->voice_spinner, 5, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(ui->voice_spinner, lv_color_hex(0x0a84ff), LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(ui->voice_spinner, true,
                                 LV_PART_MAIN | LV_PART_INDICATOR);
    lv_obj_remove_style(ui->voice_spinner, NULL, LV_PART_KNOB);
    lv_obj_remove_flag(ui->voice_spinner, LV_OBJ_FLAG_CLICKABLE);
    apply_voice_circle_optical_scale(ui->voice_spinner, VOICE_SPINNER_SIZE);
    ui->voice_spinner_core = make_plain_obj(ui->recording_overlay,
                                            VOICE_SPINNER_CORE_SIZE,
                                            VOICE_SPINNER_CORE_SIZE,
                                            lv_color_hex(0xf4f5f7), LV_OPA_COVER,
                                            LV_RADIUS_CIRCLE);
    ui->voice_spinner_center = make_plain_obj(ui->recording_overlay,
                                              VOICE_SPINNER_CENTER_SIZE,
                                              VOICE_SPINNER_CENTER_SIZE,
                                              lv_color_hex(0x0a84ff), LV_OPA_COVER,
                                              LV_RADIUS_CIRCLE);
    lv_obj_update_layout(ui->recording_overlay);
    lv_obj_align_to(ui->voice_spinner_core, ui->voice_spinner,
                    LV_ALIGN_CENTER, 0, 0);
    lv_obj_align_to(ui->voice_spinner_center, ui->voice_spinner_core,
                    LV_ALIGN_CENTER, 0, 0);

    ui->voice_pending_group = lv_obj_create(ui->recording_overlay);
    lv_obj_remove_style_all(ui->voice_pending_group);
    lv_obj_set_size(ui->voice_pending_group, 76, 80);
    lv_obj_align(ui->voice_pending_group, LV_ALIGN_TOP_MID, 0, 51);
    lv_obj_t *pending_box = make_plain_obj(ui->voice_pending_group, 66, 58,
                                           lv_color_hex(0x050608), LV_OPA_TRANSP, 12);
    lv_obj_set_style_border_width(pending_box, 2, 0);
    lv_obj_set_style_border_color(pending_box, lv_color_hex(0x0a84ff), 0);
    lv_obj_align(pending_box, LV_ALIGN_TOP_MID, 0, 0);
    static const int pending_line_widths[] = {39, 30, 35};
    for (size_t i = 0; i < sizeof(pending_line_widths) / sizeof(pending_line_widths[0]); ++i) {
        lv_obj_t *line = make_plain_obj(pending_box, pending_line_widths[i], 4,
                                        lv_color_hex(0x667085), LV_OPA_COVER, 2);
        lv_obj_align(line, LV_ALIGN_TOP_LEFT, 13, 15 + (int32_t)i * 11);
    }
    lv_obj_t *pending_cursor = make_plain_obj(pending_box, 2, 31,
                                              lv_color_hex(0x0a84ff), LV_OPA_COVER, 1);
    lv_obj_align(pending_cursor, LV_ALIGN_RIGHT_MID, -9, 1);
    ui->voice_pending_arrow = lv_obj_create(ui->voice_pending_group);
    lv_obj_remove_style_all(ui->voice_pending_arrow);
    lv_obj_set_size(ui->voice_pending_arrow,
                    VOICE_PENDING_ARROW_GROUP_SIZE,
                    VOICE_PENDING_ARROW_GROUP_SIZE);
    lv_obj_align(ui->voice_pending_arrow, LV_ALIGN_TOP_MID, 0,
                 VOICE_PENDING_ARROW_TOP);
    lv_obj_t *pending_arrow_circle = make_plain_obj(ui->voice_pending_arrow,
                                                    VOICE_PENDING_ARROW_SIZE,
                                                    VOICE_PENDING_ARROW_SIZE,
                                                    lv_color_hex(0x0a84ff),
                                                    LV_OPA_COVER,
                                                    LV_RADIUS_CIRCLE);
    lv_obj_align(pending_arrow_circle, LV_ALIGN_CENTER, 0, 0);
    apply_voice_circle_optical_scale(pending_arrow_circle,
                                     VOICE_PENDING_ARROW_SIZE);
    lv_obj_t *arrow_line = lv_line_create(ui->voice_pending_arrow);
    lv_line_set_points(arrow_line, s_voice_arrow_points,
                       sizeof(s_voice_arrow_points) / sizeof(s_voice_arrow_points[0]));
    lv_obj_set_style_line_width(arrow_line, 2, 0);
    lv_obj_set_style_line_color(arrow_line, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_line_rounded(arrow_line, true, 0);
    lv_obj_align(arrow_line, LV_ALIGN_CENTER, 0, 0);

    ui->voice_success_group = lv_obj_create(ui->recording_overlay);
    lv_obj_remove_style_all(ui->voice_success_group);
    lv_obj_set_size(ui->voice_success_group,
                    VOICE_RESULT_GROUP_WIDTH, VOICE_RESULT_GROUP_HEIGHT);
    lv_obj_align(ui->voice_success_group, LV_ALIGN_TOP_MID, 0,
                 VOICE_RESULT_GROUP_TOP);
    ui->voice_success_ring = make_plain_obj(ui->voice_success_group,
                                            VOICE_RESULT_RING_SIZE,
                                            VOICE_RESULT_RING_SIZE,
                                            lv_color_hex(0x050608), LV_OPA_TRANSP,
                                            LV_RADIUS_CIRCLE);
    lv_obj_set_style_border_width(ui->voice_success_ring, 2, 0);
    lv_obj_set_style_border_color(ui->voice_success_ring, lv_color_hex(0x147a57), 0);
    lv_obj_align(ui->voice_success_ring, LV_ALIGN_CENTER, 0, 0);
    apply_voice_circle_optical_scale(ui->voice_success_ring, VOICE_RESULT_RING_SIZE);
    lv_obj_t *success_core = make_plain_obj(ui->voice_success_group,
                                            VOICE_RESULT_CORE_SIZE,
                                            VOICE_RESULT_CORE_SIZE,
                                            lv_color_hex(0x32d583), LV_OPA_COVER,
                                            LV_RADIUS_CIRCLE);
    lv_obj_align(success_core, LV_ALIGN_CENTER, 0, 0);
    apply_voice_circle_optical_scale(success_core, VOICE_RESULT_CORE_SIZE);
    lv_obj_t *check_line = lv_line_create(ui->voice_success_group);
    lv_line_set_points(check_line, s_voice_check_points,
                       sizeof(s_voice_check_points) / sizeof(s_voice_check_points[0]));
    lv_obj_set_style_line_width(check_line, 5, 0);
    lv_obj_set_style_line_color(check_line, lv_color_hex(0x052e20), 0);
    lv_obj_set_style_line_rounded(check_line, true, 0);
    lv_obj_align(check_line, LV_ALIGN_CENTER, 0, 0);

    ui->voice_failed_group = lv_obj_create(ui->recording_overlay);
    lv_obj_remove_style_all(ui->voice_failed_group);
    lv_obj_set_size(ui->voice_failed_group,
                    VOICE_RESULT_GROUP_WIDTH, VOICE_RESULT_GROUP_HEIGHT);
    lv_obj_align(ui->voice_failed_group, LV_ALIGN_TOP_MID, 0,
                 VOICE_RESULT_GROUP_TOP);
    ui->voice_failed_ring = make_plain_obj(ui->voice_failed_group,
                                           VOICE_RESULT_RING_SIZE,
                                           VOICE_RESULT_RING_SIZE,
                                           lv_color_hex(0x050608), LV_OPA_TRANSP,
                                           LV_RADIUS_CIRCLE);
    lv_obj_set_style_border_width(ui->voice_failed_ring, 2, 0);
    lv_obj_set_style_border_color(ui->voice_failed_ring, lv_color_hex(0x8f2d3a), 0);
    lv_obj_align(ui->voice_failed_ring, LV_ALIGN_CENTER, 0, 0);
    apply_voice_circle_optical_scale(ui->voice_failed_ring, VOICE_RESULT_RING_SIZE);
    lv_obj_t *failed_core = make_plain_obj(ui->voice_failed_group,
                                           VOICE_RESULT_CORE_SIZE,
                                           VOICE_RESULT_CORE_SIZE,
                                           lv_color_hex(0xff5a67), LV_OPA_COVER,
                                           LV_RADIUS_CIRCLE);
    lv_obj_align(failed_core, LV_ALIGN_CENTER, 0, 0);
    apply_voice_circle_optical_scale(failed_core, VOICE_RESULT_CORE_SIZE);
    lv_obj_t *exclamation_line = make_plain_obj(ui->voice_failed_group, 5, 16,
                                                lv_color_hex(0x3b0710),
                                                LV_OPA_COVER,
                                                LV_RADIUS_CIRCLE);
    lv_obj_align(exclamation_line, LV_ALIGN_CENTER, 0, -4);
    lv_obj_t *exclamation_dot = make_plain_obj(ui->voice_failed_group, 5, 5,
                                               lv_color_hex(0x3b0710), LV_OPA_COVER,
                                               LV_RADIUS_CIRCLE);
    lv_obj_align(exclamation_dot, LV_ALIGN_CENTER, 0, 11);

    ui->recording_title = make_label(ui->recording_overlay, "正在聆听", FONT_CN,
                                     lv_color_hex(0xf4f5f7), 120,
                                     LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->recording_title, LV_ALIGN_TOP_MID, 0, 129);
    ui->recording_hint = make_label(ui->recording_overlay, "松开蓝键完成", FONT_UI_SMALL,
                                    lv_color_hex(0x8b9098), 120,
                                    LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->recording_hint, LV_ALIGN_TOP_MID, 0, 154);
    ui->voice_secondary_hint = make_label(ui->recording_overlay, "长按开始新录音",
                                          FONT_UI_SMALL, lv_color_hex(0x555c68), 120,
                                          LV_TEXT_ALIGN_CENTER);
    lv_obj_align(ui->voice_secondary_hint, LV_ALIGN_TOP_MID, 0, 174);

    ui->voice_footer_dot = make_plain_obj(ui->recording_overlay,
                                          VOICE_FOOTER_DOT_SIZE,
                                          VOICE_FOOTER_DOT_SIZE,
                                          lv_color_hex(0x0a84ff), LV_OPA_COVER,
                                          LV_RADIUS_CIRCLE);
    ui->voice_footer_status = make_label(ui->recording_overlay, "HOLDING",
                                         &lv_font_montserrat_8,
                                         lv_color_hex(0x8ec5ff),
                                         LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
    lv_obj_set_style_text_letter_space(ui->voice_footer_status, 1, 0);
    center_voice_footer_status(ui);
    ui->voice_footer_divider = make_plain_obj(ui->recording_overlay, 119, 1,
                                              lv_color_hex(0x202631), LV_OPA_COVER, 1);
    lv_obj_align(ui->voice_footer_divider, LV_ALIGN_TOP_MID, 0, 218);
    ui->voice_home_indicator = make_plain_obj(ui->recording_overlay, 35, 4,
                                              lv_color_hex(0x242a35), LV_OPA_COVER, 3);
    lv_obj_align(ui->voice_home_indicator, LV_ALIGN_TOP_MID, 0, 227);

    hide_voice_visuals(ui);
    set_m3b_voice_chrome_visible(ui, false);
    return ui;
}

static void set_quota_label(lv_obj_t *bar, lv_obj_t *label,
                            int value, bool valid, lv_color_t accent_color)
{
    lv_obj_set_style_bg_color(bar,
                              valid ? accent_color : lv_color_hex(0x4b4f57),
                              LV_PART_INDICATOR);
    if (!valid) {
        lv_bar_set_value(bar, 0, LV_ANIM_OFF);
        lv_label_set_text(label, "--%");
        return;
    }

    if (value < 0) value = 0;
    else if (value > 100) value = 100;
    lv_bar_set_value(bar, value, LV_ANIM_OFF);
    char text[8];
    snprintf(text, sizeof(text), "%d%%", value);
    lv_label_set_text(label, text);
}

static void set_quota_title(lv_obj_t *label, const char *prefix,
                            bool stale, bool single_window)
{
    char text[24];
    const char *safe_prefix = prefix && prefix[0] ? prefix : "--";
    const char *suffix = single_window ? "" : " 剩余";
    if (stale) snprintf(text, sizeof(text), "%s%s*", safe_prefix, suffix);
    else snprintf(text, sizeof(text), "%s%s", safe_prefix, suffix);
    lv_label_set_text(label, text);
}

static void set_status_color(vibe_ui_t *ui, const vibe_ui_home_state_t *state)
{
    const char *status = state->status ? state->status : "UNKNOWN";
    lv_color_t color = lv_color_hex(0x9aa0aa);
    if (!state->provider_implemented) {
        color = lv_color_hex(0x9aa0aa);
    } else if (strcmp(status, "RUNNING") == 0 || strcmp(status, "DONE") == 0) {
        color = state->provider_accent;
    } else if (strcmp(status, "APPROVAL") == 0) {
        color = lv_color_hex(0xcfd3da);
    } else if (strcmp(status, "ERROR") == 0 || strcmp(status, "OFFLINE") == 0) {
        color = lv_color_hex(0x686e78);
    }
    lv_obj_set_style_bg_color(ui->status_dot, color, 0);
}

static void set_object_array_visible(lv_obj_t *const *objects, size_t count, bool visible)
{
    for (size_t i = 0; i < count; ++i) {
        set_voice_object_visible(objects[i], visible);
    }
}

static void layout_quota_windows(vibe_ui_t *ui, int count)
{
    if (count < 0) count = 0;
    else if (count > 2) count = 2;

    lv_obj_t *first[] = {
        ui->quota_title_labels[0], ui->quota_value_labels[0], ui->quota_bars[0],
    };
    lv_obj_t *second[] = {
        ui->quota_title_labels[1], ui->quota_value_labels[1], ui->quota_bars[1],
    };
    set_object_array_visible(first, sizeof(first) / sizeof(first[0]), count > 0);
    set_object_array_visible(second, sizeof(second) / sizeof(second[0]), count > 1);

    if (count == 1) {
        lv_obj_add_flag(ui->quota_divider, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(ui->quota_single_remaining_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(ui->quota_title_labels[0], 101);
        lv_obj_set_style_text_font(ui->quota_title_labels[0], &lv_font_montserrat_14, 0);
        lv_obj_set_width(ui->quota_value_labels[0], 96);
        lv_obj_set_width(ui->quota_bars[0], 101);
        lv_obj_align(ui->quota_title_labels[0], LV_ALIGN_TOP_LEFT, 17, 123);
        lv_obj_set_style_text_align(ui->quota_title_labels[0], LV_TEXT_ALIGN_LEFT, 0);
        lv_obj_align(ui->quota_value_labels[0], LV_ALIGN_TOP_MID, 0, 148);
        lv_obj_align(ui->quota_bars[0], LV_ALIGN_TOP_MID, 0, 183);
    } else {
        lv_obj_add_flag(ui->quota_single_remaining_label, LV_OBJ_FLAG_HIDDEN);
        if (count > 1) lv_obj_clear_flag(ui->quota_divider, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(ui->quota_divider, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(ui->quota_title_labels[0], 44);
        lv_obj_set_style_text_font(ui->quota_title_labels[0], FONT_UI, 0);
        lv_obj_set_width(ui->quota_value_labels[0], 54);
        lv_obj_set_width(ui->quota_bars[0], 40);
        lv_obj_set_style_text_align(ui->quota_title_labels[0], LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(ui->quota_title_labels[0], LV_ALIGN_TOP_LEFT, 16, 124);
        lv_obj_align(ui->quota_value_labels[0], LV_ALIGN_TOP_LEFT, 10, 148);
        lv_obj_align(ui->quota_bars[0], LV_ALIGN_TOP_LEFT, 18, 183);
    }
}

typedef struct {
    int8_t provider_x;
    int8_t status_y;
} focus_status_optics_t;

static focus_status_optics_t focus_status_optics(const char *status)
{
    if (strcmp(status, "RUNNING") == 0) return (focus_status_optics_t){.provider_x = -2, .status_y = 0};
    if (strcmp(status, "DONE") == 0) return (focus_status_optics_t){.provider_x = 1, .status_y = 0};
    if (strcmp(status, "APPROVAL") == 0) return (focus_status_optics_t){.provider_x = -2, .status_y = -1};
    if (strcmp(status, "ERROR") == 0) return (focus_status_optics_t){.provider_x = 1, .status_y = 1};
    if (strcmp(status, "OFFLINE") == 0) return (focus_status_optics_t){.provider_x = -1, .status_y = 1};
    if (strcmp(status, "IDLE") == 0 || strcmp(status, "UNKNOWN") == 0) {
        return (focus_status_optics_t){.provider_x = -1, .status_y = 1};
    }
    return (focus_status_optics_t){.provider_x = -1, .status_y = 0};
}

static void layout_provider_label(vibe_ui_t *ui, const char *provider_name,
                                  int32_t preferred_center, int32_t center_offset,
                                  int32_t label_width, int32_t top)
{
    lv_point_t provider_size = {0};
    lv_text_get_size(&provider_size, provider_name, &lv_font_montserrat_10, 1, 0,
                     LV_COORD_MAX, LV_TEXT_FLAG_NONE);

    int32_t provider_width = provider_size.x;
    if (provider_width < 1) provider_width = 1;
    if (provider_width > label_width) provider_width = label_width;

    int32_t provider_left = preferred_center - label_width / 2 + center_offset;
    int32_t ink_left = provider_left + (label_width - provider_width) / 2;
    int32_t ink_right = ink_left + provider_width - 1;
    if (ink_left < FOCUS_PROVIDER_TEXT_LEFT) {
        provider_left += FOCUS_PROVIDER_TEXT_LEFT - ink_left;
    }
    if (ink_right > FOCUS_PROVIDER_TEXT_RIGHT) {
        provider_left -= ink_right - FOCUS_PROVIDER_TEXT_RIGHT;
    }

    lv_obj_set_width(ui->provider_label, label_width);
    lv_obj_align(ui->provider_label, LV_ALIGN_TOP_LEFT, provider_left, top);
}

static void layout_focus_card(vibe_ui_t *ui, const vibe_ui_home_state_t *state,
                              const char *status_text)
{
    const char *status = state->status ? state->status : "UNKNOWN";
    const char *project_text = state->project ? state->project : "";
    const bool show_project = state->project_visible && project_text[0] != '\0';
    const int32_t focus_group_x = show_project ? -3 : 0;
    const int32_t status_letter_space = strlen(status_text) > 6 ? 0 : 1;
    lv_point_t status_size = {0};
    lv_text_get_size(&status_size, status_text, FONT_CN, status_letter_space, 0,
                     LV_COORD_MAX, LV_TEXT_FLAG_NONE);
    const int32_t status_group_width = status_size.x + FOCUS_STATUS_PREFIX_WIDTH;
    const int32_t status_right = show_project
                                     ? 119 + focus_group_x
                                     : FOCUS_NO_PROJECT_TEXT_CENTER +
                                           status_group_width / 2;
    const int32_t status_left = status_right - status_size.x;
    const int32_t status_center = status_left + status_size.x / 2;

    char provider_name[16];
    snprintf(provider_name, sizeof(provider_name), "%s",
             state->provider_name ? state->provider_name : "Codex");
    for (size_t index = 0; provider_name[index] != '\0'; ++index) {
        if (provider_name[index] >= 'a' && provider_name[index] <= 'z') {
            provider_name[index] = (char)(provider_name[index] - ('a' - 'A'));
        }
    }
    lv_label_set_text(ui->provider_label, provider_name);
    lv_label_set_text(ui->status_label, status_text);
    lv_obj_set_style_text_letter_space(ui->status_label, status_letter_space, 0);
    lv_obj_set_width(ui->status_label, 56);

    if (show_project) {
        const focus_status_optics_t optics = focus_status_optics(status);
        const int32_t group_y = 2;
        lv_image_set_scale(ui->provider_icon, LV_SCALE_NONE);
        lv_obj_align(ui->provider_icon, LV_ALIGN_TOP_LEFT, 17, 46);
        layout_provider_label(ui, provider_name, status_center,
                              optics.provider_x, 52, 46 + group_y);
        lv_obj_align(ui->status_label, LV_ALIGN_TOP_RIGHT, -16 + focus_group_x,
                     61 + group_y + optics.status_y);
        lv_obj_align(ui->status_dot, LV_ALIGN_TOP_LEFT, status_left - 7,
                     66 + group_y + optics.status_y);

        lv_point_t project_size = {0};
        lv_text_get_size(&project_size, project_text, FONT_PROJECT, 0, 0,
                         94, LV_TEXT_FLAG_NONE);
        int32_t project_width = project_size.x;
        if (project_width < 1) project_width = 1;
        if (project_width > 94) project_width = 94;
        const int32_t project_start = (VIBE_UI_H_RES - project_width - 7) / 2;
        lv_label_set_text(ui->project_label, project_text);
        lv_obj_set_width(ui->project_label, project_width);
        lv_obj_clear_flag(ui->project_dot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(ui->project_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_align(ui->project_dot, LV_ALIGN_TOP_LEFT, project_start, 95);
        lv_obj_align(ui->project_label, LV_ALIGN_TOP_LEFT, project_start + 7, 90);
    } else {
        lv_image_set_scale(ui->provider_icon, 287);
        lv_obj_align(ui->provider_icon, LV_ALIGN_TOP_LEFT, 15, 49);
        layout_provider_label(ui, provider_name, FOCUS_NO_PROJECT_TEXT_CENTER,
                              0, 54, 51);
        lv_obj_align(ui->status_label, LV_ALIGN_TOP_RIGHT,
                     status_right - VIBE_UI_H_RES, 67);
        lv_obj_align(ui->status_dot, LV_ALIGN_TOP_LEFT, status_left - 7, 72);
        lv_obj_add_flag(ui->project_dot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(ui->project_label, LV_OBJ_FLAG_HIDDEN);
    }
}

void vibe_ui_render_home(vibe_ui_t *ui, const vibe_ui_home_state_t *state)
{
    if (!ui || !state) return;

    const char *status = state->status ? state->status : "UNKNOWN";
    lv_label_set_text(ui->wifi_label, state->wifi_connected ? "WiFi" : "OFF");
    lv_obj_set_style_text_color(ui->wifi_label,
                                state->wifi_connected
                                    ? lv_color_hex(0xf3f4f6)
                                    : lv_color_hex(0x686e78),
                                0);
    set_battery_ui(ui, state->battery_percent,
                   state->battery_charging, state->usb_powered);

    if (state->provider_icon) {
        lv_image_set_src(ui->provider_icon, state->provider_icon);
        lv_obj_clear_flag(ui->provider_icon, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(ui->provider_icon, LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_set_style_text_color(ui->provider_label,
                                state->provider_implemented
                                    ? lv_color_hex(0xf3f4f6)
                                    : lv_color_hex(0xd7d9de),
                                0);
    const char *status_text = state->provider_implemented ? status_text_for(status) : "待命";
    layout_focus_card(ui, state, status_text);
    set_status_color(ui, state);

    lv_obj_set_style_bg_color(ui->bridge_dot,
                              state->bridge_connected
                                  ? lv_color_hex(0x32d583)
                                  : lv_color_hex(0x686e78),
                              0);
    lv_obj_set_style_bg_color(ui->footer_sync_dot,
                              state->sync_healthy
                                  ? lv_color_hex(0x32d583)
                                  : lv_color_hex(0x686e78),
                              0);
    lv_label_set_text(ui->footer_sync_label, "SYNC");
    lv_label_set_text(ui->footer_action_label,
                      state->footer_action ? state->footer_action : "2X REFRESH");

    const int count = state->quota_window_count < 0
                          ? 0
                          : state->quota_window_count > 2
                                ? 2
                                : state->quota_window_count;
    layout_quota_windows(ui, count);
    if (count > 0) {
        set_quota_title(ui->quota_title_labels[0], state->quota_labels[0],
                        state->quota_stale, count == 1);
        set_quota_label(ui->quota_bars[0], ui->quota_value_labels[0],
                        state->quota_values[0], state->quota_valid[0],
                        state->provider_accent);
    }
    if (count > 1) {
        set_quota_title(ui->quota_title_labels[1], state->quota_labels[1],
                        state->quota_stale, false);
        set_quota_label(ui->quota_bars[1], ui->quota_value_labels[1],
                        state->quota_values[1], state->quota_valid[1],
                        state->provider_accent);
    }
    lv_label_set_text(ui->quota_status_label, "");
    lv_obj_add_flag(ui->quota_status_label, LV_OBJ_FLAG_HIDDEN);
}

void vibe_ui_show_legacy_recording(vibe_ui_t *ui,
                                   const char *title,
                                   const char *hint,
                                   bool visible)
{
    if (!ui) return;
    if (visible) {
        stop_voice_visual_animations(ui);
        set_m3b_voice_chrome_visible(ui, false);
        hide_voice_visuals(ui);
        set_voice_object_visible(ui->recording_wave_group, true);
        lv_obj_align(ui->recording_wave_group, LV_ALIGN_CENTER, 0, -34);
        lv_obj_set_style_text_font(ui->recording_title, FONT_CN, 0);
        lv_obj_set_style_text_font(ui->recording_hint, FONT_CN, 0);
        lv_obj_align(ui->recording_title, LV_ALIGN_CENTER, 0, 22);
        lv_obj_align(ui->recording_hint, LV_ALIGN_BOTTOM_MID, 0, -22);
        if (title) lv_label_set_text(ui->recording_title, title);
        if (hint) {
            lv_label_set_text(ui->recording_hint, hint);
            set_voice_object_visible(ui->recording_hint, hint[0] != '\0');
        }
        lv_obj_clear_flag(ui->recording_overlay, LV_OBJ_FLAG_HIDDEN);
        start_recording_wave(ui);
    } else {
        stop_recording_wave(ui);
        stop_voice_visual_animations(ui);
        lv_obj_add_flag(ui->recording_overlay, LV_OBJ_FLAG_HIDDEN);
    }
}

void vibe_ui_show_voice(vibe_ui_t *ui,
                        vibe_ui_voice_phase_t phase,
                        vibe_ui_voice_failure_t failure)
{
    if (!ui) return;
    if (phase == VIBE_UI_VOICE_IDLE) {
        vibe_ui_show_legacy_recording(ui, NULL, NULL, false);
        return;
    }

    const char *title = "";
    const char *hint = "";
    const char *secondary_hint = "";
    const char *footer_status = "";
    int32_t title_top = 129;
    int32_t hint_top = 154;
    int32_t secondary_hint_top = 172;
    lv_color_t accent = lv_color_hex(0x0a84ff);
    enum {
        VOICE_VISUAL_NONE,
        VOICE_VISUAL_WAVE,
        VOICE_VISUAL_SPINNER,
        VOICE_VISUAL_PENDING,
        VOICE_VISUAL_SUCCESS,
        VOICE_VISUAL_FAILED,
    } visual = VOICE_VISUAL_NONE;

    switch (phase) {
    case VIBE_UI_VOICE_RECORDING:
        title = "正在聆听";
        hint = "松开蓝键完成";
        footer_status = "HOLDING";
        visual = VOICE_VISUAL_WAVE;
        break;
    case VIBE_UI_VOICE_TRANSCRIBING:
        title = "正在识别";
        hint = "请稍候";
        footer_status = "WORKING";
        visual = VOICE_VISUAL_SPINNER;
        break;
    case VIBE_UI_VOICE_PENDING_SEND:
        title = "待发送";
        hint = "单击蓝键发送";
        secondary_hint = "长按开始新录音";
        footer_status = "PENDING";
        accent = lv_color_hex(0xffbd4a);
        visual = VOICE_VISUAL_PENDING;
        title_top = 134;
        hint_top = 159;
        secondary_hint_top = 174;
        break;
    case VIBE_UI_VOICE_SENDING:
        title = "正在发送";
        hint = "请稍候";
        footer_status = "SENDING";
        visual = VOICE_VISUAL_SPINNER;
        break;
    case VIBE_UI_VOICE_PASTED:
        title = "已完成";
        hint = "即将返回首页";
        footer_status = "DONE";
        accent = lv_color_hex(0x32d583);
        visual = VOICE_VISUAL_SUCCESS;
        break;
    case VIBE_UI_VOICE_COPIED:
        title = "已识别";
        hint = "未发送";
        footer_status = "NOT SENT";
        accent = lv_color_hex(0x32d583);
        visual = VOICE_VISUAL_SUCCESS;
        break;
    case VIBE_UI_VOICE_SENT:
        title = "已发送";
        hint = "即将返回首页";
        footer_status = "DONE";
        accent = lv_color_hex(0x32d583);
        visual = VOICE_VISUAL_SUCCESS;
        break;
    case VIBE_UI_VOICE_FAILED:
        if (failure == VIBE_UI_VOICE_FAILURE_UNCLEAR) {
            title = "未听清";
            hint = "长按可重新录音";
        } else if (failure == VIBE_UI_VOICE_FAILURE_TRANSCRIPTION) {
            title = "识别失败";
            hint = "长按可重新录音";
        } else {
            title = "发送失败";
            hint = "切回原输入框重试";
            secondary_hint = "长按可重新录音";
        }
        footer_status = "NOT SENT";
        accent = lv_color_hex(0xff5a67);
        visual = VOICE_VISUAL_FAILED;
        break;
    case VIBE_UI_VOICE_EXPIRED:
        title = "未发送";
        hint = "长按开始新录音";
        footer_status = "NOT SENT";
        accent = lv_color_hex(0xff5a67);
        visual = VOICE_VISUAL_FAILED;
        break;
    case VIBE_UI_VOICE_IDLE:
        return;
    }

    stop_recording_wave(ui);
    stop_voice_visual_animations(ui);
    hide_voice_visuals(ui);
    set_m3b_voice_chrome_visible(ui, true);
    lv_label_set_text(ui->recording_title, title);
    lv_label_set_text(ui->recording_hint, hint);
    lv_label_set_text(ui->voice_secondary_hint, secondary_hint);
    lv_label_set_text(ui->voice_footer_status, footer_status);
    center_voice_footer_status(ui);
    lv_obj_set_style_text_font(ui->recording_title, FONT_CN, 0);
    lv_obj_set_style_text_font(ui->recording_hint, FONT_UI_SMALL, 0);
    lv_obj_set_style_text_font(ui->voice_secondary_hint, FONT_UI_SMALL, 0);
    lv_obj_align(ui->recording_title, LV_ALIGN_TOP_MID, 0, title_top);
    lv_obj_align(ui->recording_hint, LV_ALIGN_TOP_MID, 0, hint_top);
    lv_obj_align(ui->voice_secondary_hint, LV_ALIGN_TOP_MID, 0, secondary_hint_top);
    set_voice_object_visible(ui->recording_hint, hint[0] != '\0');
    set_voice_object_visible(ui->voice_secondary_hint, secondary_hint[0] != '\0');
    lv_obj_set_style_bg_color(ui->voice_header_dot, accent, 0);
    lv_obj_set_style_bg_color(ui->voice_footer_dot, accent, 0);
    lv_obj_set_style_text_color(ui->voice_footer_status, accent, 0);

    switch (visual) {
    case VOICE_VISUAL_WAVE:
        lv_obj_align(ui->recording_wave_group, LV_ALIGN_TOP_MID, 0, 50);
        set_voice_object_visible(ui->recording_wave_group, true);
        start_recording_wave(ui);
        break;
    case VOICE_VISUAL_SPINNER:
        set_voice_object_visible(ui->voice_spinner, true);
        set_voice_object_visible(ui->voice_spinner_core, true);
        set_voice_object_visible(ui->voice_spinner_center, true);
        start_voice_spinner(ui);
        break;
    case VOICE_VISUAL_PENDING:
        set_voice_object_visible(ui->voice_pending_group, true);
        start_voice_breathe(ui->voice_pending_arrow);
        break;
    case VOICE_VISUAL_SUCCESS:
        set_voice_object_visible(ui->voice_success_group, true);
        start_voice_breathe(ui->voice_success_ring);
        break;
    case VOICE_VISUAL_FAILED:
        set_voice_object_visible(ui->voice_failed_group, true);
        start_voice_breathe(ui->voice_failed_ring);
        break;
    case VOICE_VISUAL_NONE:
        break;
    }
    lv_obj_clear_flag(ui->recording_overlay, LV_OBJ_FLAG_HIDDEN);
}
