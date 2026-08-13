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

    def test_delayed_hide_preserves_the_current_active_hud(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            primary_state = app_support / "hud-state.json"
            app_support.mkdir(parents=True)
            primary_state.write_text(
                json.dumps(
                    {
                        "active": True,
                        "status": "listening",
                        "text": "正在聆听",
                        "updated_at_epoch": 199.0,
                        "expires_at_epoch": None,
                    }
                ),
                encoding="utf-8",
            )

            with (
                mock.patch.object(hud, "HUD_STATE_PATH", primary_state),
                mock.patch.object(
                    hud,
                    "ensure_app_support",
                    lambda: app_support.mkdir(parents=True, exist_ok=True),
                ),
                mock.patch.object(hud.time, "time", return_value=200.0),
            ):
                hud.hide_hud(delay_seconds=0.5)

            primary = json.loads(primary_state.read_text())

        self.assertTrue(primary["active"])
        self.assertEqual(primary["status"], "listening")
        self.assertEqual(primary["text"], "正在聆听")
        self.assertEqual(primary["updated_at_epoch"], 200.0)
        self.assertEqual(primary["expires_at_epoch"], 200.5)

    def test_delayed_hide_does_not_reactivate_an_expired_hud(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            primary_state = app_support / "hud-state.json"
            app_support.mkdir(parents=True)
            primary_state.write_text(
                json.dumps(
                    {
                        "active": True,
                        "status": "transcribing",
                        "text": "正在识别",
                        "updated_at_epoch": 98.0,
                        "expires_at_epoch": 99.0,
                    }
                ),
                encoding="utf-8",
            )

            with (
                mock.patch.object(hud, "HUD_STATE_PATH", primary_state),
                mock.patch.object(
                    hud,
                    "ensure_app_support",
                    lambda: app_support.mkdir(parents=True, exist_ok=True),
                ),
                mock.patch.object(hud.time, "time", return_value=100.0),
            ):
                hud.hide_hud(delay_seconds=0.5)

            primary = json.loads(primary_state.read_text())

        self.assertFalse(primary["active"])
        self.assertEqual(primary["status"], "idle")
        self.assertEqual(primary["text"], "")
        self.assertIsNone(primary["expires_at_epoch"])


if __name__ == "__main__":
    unittest.main()
