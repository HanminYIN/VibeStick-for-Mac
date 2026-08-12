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
        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        for required in (
            "lv_arc_create(s_recording_overlay)",
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
            self.assertIn(required, main_source)
        self.assertNotIn("s_voice_transcript", main_source)

    def test_m3b_ui_fonts_and_lvgl_stack_match_the_device_renderer(self) -> None:
        main_source = (ROOT / "firmware/sticks3/src/main.c").read_text()
        stack_match = re.search(r"^#define LVGL_TASK_STACK_BYTES (\d+)$", main_source, re.MULTILINE)
        self.assertIsNotNone(stack_match)
        self.assertGreaterEqual(int(stack_match.group(1)), 8192)
        self.assertIn("VOICE_WAVE_BAR_COUNT 6", main_source)
        self.assertIn("uxTaskGetStackHighWaterMark(NULL)", main_source)

        defaults = (ROOT / "firmware/sticks3/sdkconfig.defaults").read_text()
        self.assertIn("CONFIG_LV_FONT_MONTSERRAT_8=y", defaults)
        self.assertIn("# CONFIG_LV_USE_FONT_COMPRESSED is not set", defaults)

        for font_name in ("vibe_stick_ui_10.c", "vibe_stick_ui_12.c"):
            font_source = (ROOT / "firmware/sticks3/generated" / font_name).read_text()
            self.assertIn(".bitmap_format = 0", font_source)
            self.assertNotIn(".bitmap_format = 1", font_source)

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
