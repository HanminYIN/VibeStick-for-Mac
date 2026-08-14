from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLANG = shutil.which("clang")


@unittest.skipUnless(CLANG, "clang is required for the host firmware state-machine test")
class FirmwareVoiceInteractionTests(unittest.TestCase):
    def test_terminal_states_remain_readable_for_requested_duration(self) -> None:
        header = (ROOT / "firmware/sticks3/include/vibe_voice_interaction.h").read_text()
        self.assertIn("#define VIBE_VOICE_SUCCESS_HOLD_MS 1200", header)
        self.assertIn("#define VIBE_VOICE_FAILURE_HOLD_MS 1500", header)

    def test_m3b_partition_expands_app_without_moving_nvs(self) -> None:
        partition_csv = (ROOT / "firmware/sticks3/partitions_vibestick.csv").read_text()
        normalized = re.sub(r"\s+", "", partition_csv)
        self.assertIn("nvs,data,nvs,0x9000,0x6000,", normalized)
        self.assertIn("phy_init,data,phy,0xf000,0x1000,", normalized)
        self.assertIn("factory,app,factory,0x10000,0x300000,", normalized)

        defaults = (ROOT / "firmware/sticks3/sdkconfig.defaults").read_text()
        self.assertIn("CONFIG_PARTITION_TABLE_CUSTOM=y", defaults)
        self.assertIn(
            'CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_vibestick.csv"',
            defaults,
        )

    def test_m3b_overlay_uses_vector_states_and_fixed_copy(self) -> None:
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        for required in (
            "lv_arc_create(ui->recording_overlay)",
            'title = "正在聆听"',
            'title = "正在识别"',
            'title = "待发送"',
            'title = "已发送"',
            'title = "发送失败"',
            'title = "未听清"',
            'title = "识别失败"',
            'title = "未发送"',
            'hint = "单击蓝键发送"',
            'hint = "即将返回首页"',
            'footer_status = "DONE"',
            'footer_status = "NOT SENT"',
        ):
            self.assertIn(required, ui_source)
        self.assertNotIn("voice_transcript", ui_source)

    def test_m3b_ui_fonts_and_lvgl_stack_match_the_device_renderer(self) -> None:
        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        stack_match = re.search(r"^#define LVGL_TASK_STACK_BYTES (\d+)$", main_source, re.MULTILINE)
        self.assertIsNotNone(stack_match)
        self.assertGreaterEqual(int(stack_match.group(1)), 8192)
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        self.assertIn("VOICE_WAVE_BAR_COUNT 6", ui_source)
        self.assertIn("uxTaskGetStackHighWaterMark(NULL)", main_source)

        defaults = (ROOT / "firmware/sticks3/sdkconfig.defaults").read_text()
        self.assertIn("CONFIG_LV_FONT_MONTSERRAT_8=y", defaults)
        self.assertIn("# CONFIG_LV_USE_FONT_COMPRESSED is not set", defaults)

        for font_name in ("vibe_stick_ui_10.c", "vibe_stick_ui_12.c"):
            font_source = (ROOT / "firmware/sticks3/generated" / font_name).read_text()
            self.assertIn(".bitmap_format = 0", font_source)
            self.assertNotIn(".bitmap_format = 1", font_source)

    def test_project_name_font_supports_simplified_chinese_with_ascii_fallback(self) -> None:
        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        cmake_source = (ROOT / "firmware/sticks3/src/CMakeLists.txt").read_text()
        font_source = (
            ROOT / "firmware/sticks3/generated/vibe_stick_project_cn_10.c"
        ).read_text()
        generator_source = (ROOT / "scripts/generate-project-font.sh").read_text()

        self.assertIn("#define FONT_PROJECT (&vibe_stick_project_cn_10)", ui_source)
        self.assertIn('make_label(screen, "VibeStick", FONT_PROJECT,', ui_source)
        self.assertIn(
            "lv_text_get_size(&project_size, project_text, FONT_PROJECT,",
            ui_source,
        )
        self.assertIn("vibe_ui_render_home(s_ui, &ui_state);", main_source)
        self.assertIn('"vibe_ui.c"', cmake_source)
        self.assertIn('"../generated/vibe_stick_project_cn_10.c"', cmake_source)

        self.assertEqual(font_source.count("{.bitmap_index"), 6_785)
        self.assertIn('/* U+4E2D "中" */', font_source)
        self.assertIn('/* U+6587 "文" */', font_source)
        self.assertIn('/* U+9879 "项" */', font_source)
        self.assertIn('/* U+76EE "目" */', font_source)
        self.assertIn('/* U+836F "药" */', font_source)
        self.assertIn('/* U+65F6 "时" */', font_source)
        self.assertIn(".bitmap_format = 0", font_source)
        self.assertIn(".fallback = &lv_font_montserrat_10", font_source)
        self.assertNotIn(str(ROOT), font_source)

        self.assertIn("if len(hanzi) != 6763", generator_source)
        self.assertIn('FONT_CONVERTER_VERSION="1.5.3"', generator_source)
        self.assertIn("--no-compress", generator_source)
        self.assertIn("--lv-fallback lv_font_montserrat_10", generator_source)

    def test_provider_label_ink_is_clamped_inside_the_focus_card(self) -> None:
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        for required in (
            "#define FOCUS_PROVIDER_TEXT_LEFT 65",
            "#define FOCUS_PROVIDER_TEXT_RIGHT 123",
            "#define FOCUS_NO_PROJECT_TEXT_CENTER 92",
            "lv_text_get_size(&provider_size, provider_name,",
            "if (ink_left < FOCUS_PROVIDER_TEXT_LEFT)",
            "if (ink_right > FOCUS_PROVIDER_TEXT_RIGHT)",
            "layout_provider_label(ui, provider_name, status_center,",
            "status_group_width / 2;",
            "lv_obj_align(ui->provider_icon, LV_ALIGN_TOP_LEFT, 15, 49);",
            "layout_provider_label(ui, provider_name, FOCUS_NO_PROJECT_TEXT_CENTER,",
            "status_right - VIBE_UI_H_RES, 67);",
        ):
            self.assertIn(required, ui_source)

    def test_voice_footer_dot_and_status_are_centered_as_one_measured_group(self) -> None:
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        for required in (
            "static void center_voice_footer_status(vibe_ui_t *ui)",
            "lv_obj_update_layout(ui->voice_footer_status);",
            "lv_obj_get_width(ui->voice_footer_status)",
            "(VIBE_UI_H_RES - group_width + 1) / 2",
            "group_left + VOICE_FOOTER_DOT_SIZE + VOICE_FOOTER_GAP",
            "LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT",
        ):
            self.assertIn(required, ui_source)
        self.assertGreaterEqual(ui_source.count("center_voice_footer_status(ui);"), 2)
        self.assertNotIn(
            "lv_obj_align(ui->voice_footer_dot, LV_ALIGN_TOP_LEFT, 45, 203);",
            ui_source,
        )
        self.assertNotIn(
            "lv_obj_align(ui->voice_footer_status, LV_ALIGN_TOP_LEFT, 52, 199);",
            ui_source,
        )

    def test_voice_circles_apply_real_lcd_vertical_optical_compensation(self) -> None:
        ui_header = (ROOT / "firmware/sticks3/include/vibe_ui.h").read_text()
        ui_source = (ROOT / "firmware/sticks3/src/vibe_ui.c").read_text()
        scale_match = re.search(
            r"^#define VIBE_UI_VOICE_CIRCLE_OPTICAL_SCALE_Y (\d+)$",
            ui_header,
            re.MULTILINE,
        )
        self.assertIsNotNone(scale_match)
        self.assertEqual(int(scale_match.group(1)), 270)
        for required in (
            "static void apply_voice_circle_optical_scale(lv_obj_t *obj, int32_t size)",
            "lv_obj_set_style_transform_pivot_x(obj, size / 2, 0);",
            "lv_obj_set_style_transform_pivot_y(obj, size / 2, 0);",
            "lv_obj_set_style_transform_scale_y(obj, VOICE_CIRCLE_OPTICAL_SCALE_Y, 0);",
            "lv_obj_set_size(ui->voice_spinner, VOICE_SPINNER_SIZE, VOICE_SPINNER_SIZE);",
            "VOICE_SPINNER_CORE_SIZE,\n                                            VOICE_SPINNER_CORE_SIZE,",
            "VOICE_SPINNER_CENTER_SIZE,\n                                              VOICE_SPINNER_CENTER_SIZE,",
            "VOICE_PENDING_ARROW_SIZE,\n                                                    VOICE_PENDING_ARROW_SIZE,",
            "lv_obj_align_to(ui->voice_spinner_core, ui->voice_spinner,",
            "lv_obj_align_to(ui->voice_spinner_center, ui->voice_spinner_core,",
            "VOICE_RESULT_RING_SIZE,\n                                            VOICE_RESULT_RING_SIZE,",
            "VOICE_RESULT_CORE_SIZE,\n                                            VOICE_RESULT_CORE_SIZE,",
            "lv_line_create(ui->voice_success_group)",
        ):
            self.assertIn(required, ui_source)

        self.assertIn(
            "lv_obj_align_to(ui->voice_spinner_core, ui->voice_spinner,\n"
            "                    LV_ALIGN_CENTER, 0, 0);",
            ui_source,
        )
        self.assertIn(
            "lv_obj_align_to(ui->voice_spinner_center, ui->voice_spinner_core,\n"
            "                    LV_ALIGN_CENTER, 0, 0);",
            ui_source,
        )
        self.assertNotIn("VOICE_SPINNER_HEIGHT", ui_source)
        self.assertNotIn("VOICE_RESULT_RING_HEIGHT", ui_source)
        self.assertNotIn("voice_exclamation_points", ui_source)
        self.assertNotIn("lv_line_create(ui->voice_failed_group)", ui_source)
        self.assertIn(
            "make_plain_obj(ui->voice_failed_group, 5, 16,",
            ui_source,
        )
        self.assertIn(
            "lv_obj_align(exclamation_line, LV_ALIGN_CENTER, 0, -4);",
            ui_source,
        )
        self.assertIn(
            "lv_obj_align(exclamation_dot, LV_ALIGN_CENTER, 0, 11);",
            ui_source,
        )

    def test_m3b_is_the_default_firmware_and_http_headers_have_room(self) -> None:
        project_cmake = (ROOT / "firmware/sticks3/CMakeLists.txt").read_text()
        self.assertIn(
            'option(VIBE_STICK_ENABLE_M3B_VOICE "Compile the M3-B voice interaction path" ON)',
            project_cmake,
        )

        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        header_buffer_match = re.search(
            r"^#define VIBE_HTTP_HEADER_BUFFER_BYTES (\d+)$",
            main_source,
            re.MULTILINE,
        )
        self.assertIsNotNone(header_buffer_match)
        self.assertGreaterEqual(int(header_buffer_match.group(1)), 1024)
        self.assertEqual(
            main_source.count(".buffer_size_tx = VIBE_HTTP_HEADER_BUFFER_BYTES"),
            2,
        )
        self.assertEqual(
            main_source.count(".buffer_size = VIBE_HTTP_HEADER_BUFFER_BYTES"),
            2,
        )

    def test_recording_responses_fit_current_m3b_payloads_without_stack_copies(self) -> None:
        config_source = (ROOT / "firmware/sticks3/include/vibe_stick_config.h").read_text()
        capacity_match = re.search(
            r"^#define VIBE_STICK_RECORDING_RESPONSE_CAPACITY (\d+)$",
            config_source,
            re.MULTILINE,
        )
        self.assertIsNotNone(capacity_match)
        self.assertGreaterEqual(int(capacity_match.group(1)), 2048)

        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        self.assertEqual(
            main_source.count(
                "static char s_recording_response[VIBE_STICK_RECORDING_RESPONSE_CAPACITY];"
            ),
            1,
        )
        self.assertEqual(
            main_source.count("s_recording_response, sizeof(s_recording_response)"),
            4,
        )
        self.assertNotIn("char response[768]", main_source)

    def test_pure_c_state_machine_passes_with_warnings_as_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vibestick-firmware-voice-") as temporary:
            executable = Path(temporary) / "vibe_voice_interaction_test"
            compile_result = subprocess.run(
                [
                    CLANG,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    f"-I{ROOT / 'firmware/sticks3/include'}",
                    str(ROOT / "firmware/sticks3/src/vibe_voice_interaction.c"),
                    str(ROOT / "firmware/sticks3/tests/vibe_voice_interaction_test.c"),
                    "-o",
                    str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertEqual(run_result.stdout.strip(), "vibe_voice_interaction_test: ok")


if __name__ == "__main__":
    unittest.main()
