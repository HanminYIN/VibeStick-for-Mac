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


class CodexMainTaskObservationTests(unittest.TestCase):
    def setUp(self) -> None:
        local_observer._SESSION_IDENTITY_CACHE.clear()

    def test_new_activity_after_completion_reports_running_without_completion_alert(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = self._session_path(Path(tmp), "root-session")
            self._write_session(
                session,
                "root-session",
                "vscode",
                [
                    self._event(now - timedelta(minutes=2), "task_complete", "turn-1"),
                    self._event(now - timedelta(seconds=10), "custom_tool_call", "turn-1"),
                ],
            )
            observation = self._observe(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.latest_event_type, "custom_tool_call")
        self.assertEqual(observation.alert_type, "")

    def test_latest_main_completion_reports_done(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = self._session_path(Path(tmp), "root-session")
            self._write_session(
                session,
                "root-session",
                "vscode",
                [
                    self._event(now - timedelta(seconds=20), "task_started", "turn-1"),
                    self._event(now - timedelta(seconds=5), "task_complete", "turn-1"),
                ],
            )
            observation = self._observe(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_key, "root-session:turn-1:DONE")

    def test_subagent_completion_does_not_complete_running_main_task(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_session(
                self._session_path(root, "root-session"),
                "root-session",
                "vscode",
                [self._event(now - timedelta(seconds=30), "task_started", "main-turn")],
            )
            self._write_session(
                self._session_path(root, "sub-session"),
                "sub-session",
                {"subagent": {"thread_spawn": {"parent_thread_id": "root-session"}}},
                [
                    self._event(now - timedelta(seconds=10), "task_started", "sub-turn"),
                    self._event(now - timedelta(seconds=2), "task_complete", "sub-turn"),
                ],
            )
            observation = self._observe(root)

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")
        self.assertEqual(observation.latest_event_type, "task_started")

    def test_guardian_completion_does_not_complete_running_main_task(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_session(
                self._session_path(root, "root-session"),
                "root-session",
                "vscode",
                [self._event(now - timedelta(seconds=30), "task_started", "main-turn")],
            )
            self._write_session(
                self._session_path(root, "guardian-session"),
                "guardian-session",
                {"subagent": {"other": "guardian"}},
                [
                    self._event(now - timedelta(seconds=6), "task_started", "review-turn"),
                    self._event(now - timedelta(seconds=2), "task_complete", "review-turn"),
                ],
            )
            observation = self._observe(root)

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")

    def test_one_main_task_completion_alerts_while_another_remains_running(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_session(
                self._session_path(root, "task-a"),
                "task-a",
                "vscode",
                [
                    self._event(now - timedelta(seconds=30), "task_started", "turn-a"),
                    self._event(now - timedelta(seconds=3), "task_complete", "turn-a"),
                ],
            )
            self._write_session(
                self._session_path(root, "task-b"),
                "task-b",
                "vscode",
                [self._event(now - timedelta(seconds=20), "task_started", "turn-b")],
            )
            observation = self._observe(root)

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_key, "task-a:turn-a:DONE")

    def test_new_main_turn_keeps_prior_completion_event_while_running(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = self._session_path(Path(tmp), "root-session")
            self._write_session(
                session,
                "root-session",
                "vscode",
                [
                    self._event(now - timedelta(seconds=30), "task_started", "turn-1"),
                    self._event(now - timedelta(seconds=20), "task_complete", "turn-1"),
                    self._event(now - timedelta(seconds=10), "task_started", "turn-2"),
                ],
            )
            observation = self._observe(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_key, "root-session:turn-1:DONE")

    def test_interrupted_main_task_does_not_play_completion(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            session = self._session_path(Path(tmp), "root-session")
            self._write_session(
                session,
                "root-session",
                "vscode",
                [
                    self._event(now - timedelta(seconds=20), "task_started", "turn-1"),
                    self._event(now - timedelta(seconds=2), "turn_aborted", "turn-1"),
                ],
            )
            observation = self._observe(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.IDLE)
        self.assertEqual(observation.alert_type, "")

    def test_missing_session_metadata_fails_safe_without_done_alert(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "legacy.jsonl"
            session.write_text(
                json.dumps(self._event(now - timedelta(seconds=2), "task_complete", "turn-1"))
                + "\n"
            )
            observation = self._observe(root)

        self.assertNotEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "")

    def test_internal_sessions_do_not_evict_main_session_from_discovery_limit(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_session(
                self._session_path(root, "root-session"),
                "root-session",
                "vscode",
                [self._event(now - timedelta(seconds=30), "task_started", "main-turn")],
            )
            for index in range(MAX_INTERNAL_SESSIONS):
                session_id = f"sub-{index:02d}"
                self._write_session(
                    self._session_path(root, session_id),
                    session_id,
                    {"subagent": {"other": "guardian"}},
                    [self._event(now - timedelta(seconds=2), "task_complete", f"turn-{index}")],
                )
            observation = self._observe(root)

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")

    @staticmethod
    def _session_path(root: Path, session_id: str) -> Path:
        return root / f"rollout-test-{session_id}.jsonl"

    @staticmethod
    def _event(timestamp: datetime, payload_type: str, turn_id: str) -> dict[str, object]:
        return {
            "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
            "type": "event_msg",
            "payload": {"type": payload_type, "turn_id": turn_id},
        }

    @staticmethod
    def _write_session(
        path: Path,
        session_id: str,
        source: object,
        events: list[dict[str, object]],
    ) -> None:
        metadata = {
            "timestamp": "2026-08-11T00:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "source": source,
                "thread_source": "subagent",
            },
        }
        path.write_text("".join(json.dumps(event) + "\n" for event in [metadata, *events]))

    @staticmethod
    def _observe(root: Path):
        with (
            patch.object(local_observer, "SESSIONS_DIR", root),
            patch.object(local_observer, "_codex_process_running", return_value=True),
        ):
            return observe_codex(root)


MAX_INTERNAL_SESSIONS = 45


if __name__ == "__main__":
    unittest.main()
