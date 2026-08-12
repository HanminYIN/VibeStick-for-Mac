import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick.desktop import hud


class DesktopHudTests(unittest.TestCase):
    def test_show_hud_writes_vibestick_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            primary_state = app_support / "hud-state.json"

            with mock.patch.object(hud, "HUD_STATE_PATH", primary_state):
                with mock.patch.object(
                    hud,
                    "ensure_app_support",
                    lambda: app_support.mkdir(parents=True, exist_ok=True),
                ):
                    hud.show_hud("listening")

            primary = json.loads(primary_state.read_text())

        self.assertEqual(primary["status"], "listening")
        self.assertEqual(primary["text"], "正在聆听")

    def test_send_failure_is_distinct_from_transcription_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            primary_state = app_support / "hud-state.json"

            with mock.patch.object(hud, "HUD_STATE_PATH", primary_state):
                with mock.patch.object(
                    hud,
                    "ensure_app_support",
                    lambda: app_support.mkdir(parents=True, exist_ok=True),
                ):
                    hud.show_hud("send_failed", hold_seconds=1.8)

            primary = json.loads(primary_state.read_text())

        self.assertEqual(primary["status"], "send_failed")
        self.assertEqual(primary["text"], "发送失败")


if __name__ == "__main__":
    unittest.main()
