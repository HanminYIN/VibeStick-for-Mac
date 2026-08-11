import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from vibe_stick.codex import local_observer
from vibe_stick.codex.local_observer import _is_codex_process_command, observe_codex
from vibe_stick.protocol.state import AgentStatus


class CodexProcessDetectionTests(unittest.TestCase):
    def test_detects_legacy_codex_app(self) -> None:
        self.assertTrue(
            _is_codex_process_command(
                "/Applications/Codex.app/Contents/Resources/codex app-server"
            )
        )

    def test_detects_codex_embedded_in_chatgpt_app(self) -> None:
        self.assertTrue(
            _is_codex_process_command(
                "/Applications/ChatGPT.app/Contents/Resources/codex "
                "-c features.code_mode_host=true app-server"
            )
        )

    def test_ignores_unrelated_chatgpt_helper(self) -> None:
        self.assertFalse(
            _is_codex_process_command(
                "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
                "Helpers/Codex (Renderer)"
            )
        )

    def test_new_activity_after_completion_reports_running(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "session.jsonl"
            self._write_events(
                session,
                [
                    self._event(now - timedelta(minutes=2), "task_complete"),
                    self._event(now - timedelta(seconds=10), "custom_tool_call"),
                ],
            )
            with (
                patch.object(local_observer, "SESSIONS_DIR", Path(tmp)),
                patch.object(local_observer, "_codex_process_running", return_value=True),
            ):
                observation = observe_codex(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.latest_event_type, "custom_tool_call")
        self.assertEqual(observation.alert_type, "")

    def test_latest_completion_still_reports_done(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "session.jsonl"
            self._write_events(
                session,
                [
                    self._event(now - timedelta(seconds=20), "custom_tool_call"),
                    self._event(now - timedelta(seconds=5), "task_complete"),
                ],
            )
            with (
                patch.object(local_observer, "SESSIONS_DIR", Path(tmp)),
                patch.object(local_observer, "_codex_process_running", return_value=True),
            ):
                observation = observe_codex(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")

    @staticmethod
    def _event(timestamp: datetime, payload_type: str) -> dict[str, object]:
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {"type": payload_type},
        }

    @staticmethod
    def _write_events(path: Path, events: list[dict[str, object]]) -> None:
        path.write_text("".join(json.dumps(event) + "\n" for event in events))


if __name__ == "__main__":
    unittest.main()
