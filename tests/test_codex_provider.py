import hashlib
import unittest
from datetime import datetime, timezone

from vibe_stick.codex.local_observer import LocalCodexObservation
from vibe_stick.codex.quota import QuotaSnapshot
from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers.codex import observation_from_local_codex


class CodexProviderTests(unittest.TestCase):
    def test_codex_local_observation_maps_to_provider_observation(self) -> None:
        timestamp = datetime(2026, 6, 28, 9, 41, tzinfo=timezone.utc)
        observation = observation_from_local_codex(
            LocalCodexObservation(
                status=AgentStatus.DONE,
                project="VibeStick",
                quota=QuotaSnapshot(66, 96, "09:40", False),
                quota_found=True,
                alert_type="DONE",
                alert_message="Codex task completed",
                alert_timestamp=timestamp,
                latest_event_timestamp=timestamp,
                codex_online=True,
            )
        )

        self.assertEqual(observation.provider_id, "codex")
        self.assertEqual(observation.display_name, "Codex")
        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.quota_5h_remaining, 66)
        self.assertEqual(observation.quota_7d_remaining, 96)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, f"evt_{timestamp.astimezone().strftime('%Y%m%d_%H%M%S')}_done")
        self.assertEqual(observation.latest_event_timestamp, timestamp)

    def test_missing_codex_quota_maps_to_unknown_bars(self) -> None:
        observation = observation_from_local_codex(
            LocalCodexObservation(
                status=AgentStatus.IDLE,
                project="VibeStick",
                quota=None,
                quota_found=False,
                codex_online=True,
            )
        )

        self.assertIsNone(observation.quota_5h_remaining)
        self.assertIsNone(observation.quota_7d_remaining)
        self.assertEqual(observation.alert_type, "NONE")

    def test_completion_alert_is_preserved_while_another_main_task_is_running(self) -> None:
        timestamp = datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc)
        event_key = "task-a:turn-a:DONE"
        observation = observation_from_local_codex(
            LocalCodexObservation(
                status=AgentStatus.RUNNING,
                project="VibeStick",
                quota=None,
                quota_found=False,
                alert_type="DONE",
                alert_message="Codex task completed",
                alert_timestamp=timestamp,
                alert_event_key=event_key,
                codex_online=True,
            )
        )

        digest = hashlib.sha256(event_key.encode("utf-8")).hexdigest()[:16]
        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, f"evt_{digest}_done")

    def test_distinct_main_turns_have_distinct_completion_event_ids(self) -> None:
        timestamp = datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc)

        def event_id(event_key: str) -> str:
            return observation_from_local_codex(
                LocalCodexObservation(
                    status=AgentStatus.DONE,
                    project="VibeStick",
                    quota=None,
                    quota_found=False,
                    alert_type="DONE",
                    alert_timestamp=timestamp,
                    alert_event_key=event_key,
                    codex_online=True,
                )
            ).alert_event_id

        self.assertNotEqual(
            event_id("task-a:turn-a:DONE"),
            event_id("task-b:turn-b:DONE"),
        )


if __name__ == "__main__":
    unittest.main()
