from __future__ import annotations

import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from vibe_stick.audio.send_session import (
    PendingSendCoordinator,
    SendSessionPhase,
    SendTarget,
)


class _Clock:
    def __init__(self, value: float = 1_000.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


def _target(*, process_id: int = 42, fingerprint: str = "a" * 64) -> SendTarget:
    target = SendTarget.normalized(
        bundle_id="com.openai.codex",
        process_id=process_id,
        focus_fingerprint=fingerprint,
    )
    assert target is not None
    return target


class PendingSendCoordinatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "pending-send-v1.json"
        self.clock = _Clock()
        self.coordinator = PendingSendCoordinator(self.path, clock=self.clock)
        self.session_id = "0123456789abcdef0123456789abcdef"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_matching_confirmation_is_consumed_exactly_once(self) -> None:
        armed = self.coordinator.arm(session_id=self.session_id, target=_target())
        first = self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )
        duplicate = self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )
        finished = self.coordinator.finish_confirmation(
            session_id=self.session_id,
            success=True,
        )
        after_sent = self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )

        self.assertTrue(armed.accepted)
        self.assertTrue(first.accepted)
        self.assertTrue(first.should_press_enter)
        self.assertFalse(duplicate.accepted)
        self.assertFalse(duplicate.should_press_enter)
        self.assertEqual(duplicate.reason, "confirmation_already_consumed")
        self.assertEqual(finished.snapshot.phase, SendSessionPhase.SENT)
        self.assertFalse(after_sent.should_press_enter)

    def test_concurrent_confirmation_allows_only_one_return_action(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())

        def confirm() -> bool:
            result = self.coordinator.begin_confirmation(
                session_id=self.session_id,
                current_target=_target(),
            )
            return result.should_press_enter

        with ThreadPoolExecutor(max_workers=8) as pool:
            actions = list(pool.map(lambda _: confirm(), range(24)))

        self.assertEqual(actions.count(True), 1)
        self.assertEqual(actions.count(False), 23)
        self.assertEqual(self.coordinator.snapshot().phase, SendSessionPhase.CONFIRMING)

    def test_rearming_same_session_cannot_reset_consumed_confirmation(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())
        duplicate_pending = self.coordinator.arm(session_id=self.session_id, target=_target())
        self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )
        self.coordinator.finish_confirmation(session_id=self.session_id, success=True)
        duplicate_sent = self.coordinator.arm(session_id=self.session_id, target=_target())

        self.assertTrue(duplicate_pending.accepted)
        self.assertEqual(duplicate_pending.reason, "pending_send_already_armed")
        self.assertFalse(duplicate_sent.accepted)
        self.assertEqual(duplicate_sent.reason, "pending_send_session_already_consumed")
        self.assertEqual(duplicate_sent.snapshot.phase, SendSessionPhase.SENT)

    def test_changed_focus_target_invalidates_pending_send(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())

        result = self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(process_id=99),
        )

        self.assertFalse(result.accepted)
        self.assertFalse(result.should_press_enter)
        self.assertEqual(result.reason, "focused_target_changed")
        self.assertEqual(result.snapshot.phase, SendSessionPhase.INVALIDATED)

    def test_mismatched_session_does_not_consume_pending_send(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())

        result = self.coordinator.begin_confirmation(
            session_id="fedcba9876543210fedcba9876543210",
            current_target=_target(),
        )

        self.assertFalse(result.accepted)
        self.assertEqual(result.reason, "pending_send_session_mismatch")
        self.assertEqual(self.coordinator.snapshot().phase, SendSessionPhase.PENDING)

    def test_pending_send_expires_after_thirty_seconds(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())
        self.clock.advance(30.0)

        snapshot = self.coordinator.snapshot()
        result = self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )

        self.assertEqual(snapshot.phase, SendSessionPhase.EXPIRED)
        self.assertFalse(result.accepted)
        self.assertFalse(result.should_press_enter)
        self.assertEqual(result.reason, "pending_send_expired")

    def test_new_recording_invalidates_pending_but_not_confirming(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())
        second_session_id = "11111111111111111111111111111111"
        invalidated = self.coordinator.begin_recording(
            session_id=second_session_id
        )
        self.coordinator.arm(session_id=second_session_id, target=_target())
        self.coordinator.begin_confirmation(
            session_id=second_session_id,
            current_target=_target(),
        )
        blocked = self.coordinator.begin_recording(
            session_id="22222222222222222222222222222222"
        )

        self.assertTrue(invalidated.accepted)
        self.assertEqual(invalidated.snapshot.phase, SendSessionPhase.INVALIDATED)
        self.assertEqual(invalidated.reason, "previous_pending_send_invalidated")
        self.assertFalse(blocked.accepted)
        self.assertEqual(blocked.reason, "confirmation_in_progress")

    def test_restart_during_confirmation_fails_closed(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())
        self.coordinator.begin_confirmation(
            session_id=self.session_id,
            current_target=_target(),
        )

        restored = PendingSendCoordinator(self.path, clock=self.clock)
        snapshot = restored.snapshot()

        self.assertEqual(snapshot.phase, SendSessionPhase.INVALIDATED)
        self.assertEqual(snapshot.reason, "bridge_restarted_during_confirmation")

    def test_persisted_state_is_private_and_contains_no_transcript_material(self) -> None:
        self.coordinator.arm(session_id=self.session_id, target=_target())

        payload = json.loads(self.path.read_text(encoding="utf-8"))
        serialized = json.dumps(payload).lower()
        mode = os.stat(self.path).st_mode & 0o777

        self.assertEqual(mode, 0o600)
        self.assertNotIn("transcript", serialized)
        self.assertNotIn("window_title", serialized)
        self.assertNotIn("clipboard", serialized)
        self.assertEqual(payload["target"]["bundle_id"], "com.openai.codex")
        self.assertEqual(payload["target"]["process_id"], 42)

    def test_invalid_target_and_ttl_are_rejected(self) -> None:
        invalid_target = SendTarget.normalized(
            bundle_id="com.openai.codex",
            process_id=42,
            focus_fingerprint="not-a-sha256",
        )

        self.assertIsNone(invalid_target)
        with self.assertRaises(ValueError):
            PendingSendCoordinator(self.path, clock=self.clock, ttl_seconds=301)

    def test_malformed_or_unknown_persisted_state_fails_closed_to_idle(self) -> None:
        self.path.write_text(
            json.dumps({"schema_version": 99, "phase": "pending", "transcript": "secret"}),
            encoding="utf-8",
        )
        unknown_schema = PendingSendCoordinator(self.path, clock=self.clock)
        self.assertEqual(unknown_schema.snapshot().phase, SendSessionPhase.IDLE)

        self.path.write_text("{not-json", encoding="utf-8")
        malformed = PendingSendCoordinator(self.path, clock=self.clock)
        self.assertEqual(malformed.snapshot().phase, SendSessionPhase.IDLE)


if __name__ == "__main__":
    unittest.main()
