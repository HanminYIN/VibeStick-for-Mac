from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick.audio.recorder import RecordingController
from vibe_stick.audio.send_session import SendSessionPhase, SendTarget
from vibe_stick.paste.input_injector import PasteResult


def _target(*, process_id: int = 42) -> SendTarget:
    target = SendTarget.normalized(
        bundle_id="com.openai.codex",
        process_id=process_id,
        focus_fingerprint=("a" if process_id == 42 else "b") * 64,
    )
    assert target is not None
    return target


class RecordingSendFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.controller = RecordingController(
            root / "recording.json",
            pending_send_path=root / "pending-send-v1.json",
        )
        self.controller.paste_injector = mock.Mock()
        self.session_id = "0123456789abcdef0123456789abcdef"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _start(self, *, interaction_version: int | None = None, session_id: str | None = None) -> None:
        request = {
            "audio_source": "sticks3_pcm",
            "session_id": session_id or self.session_id,
        }
        if interaction_version is not None:
            request["interaction_version"] = interaction_version
        with mock.patch("vibe_stick.audio.recorder.show_hud"):
            self.controller.start(request)

    def _stop(self, *, session_id: str | None = None):  # noqa: ANN201
        with (
            mock.patch("vibe_stick.audio.recorder.show_hud"),
            mock.patch("vibe_stick.audio.recorder.hide_hud"),
        ):
            request = {"text": "hello from VibeStick", "paste": True}
            if self.controller.session.interaction_version >= 2:
                request["session_id"] = session_id or self.controller.session.session_id
            return self.controller.stop(request)

    def test_legacy_firmware_never_enters_confirmation_mode(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_SEND_MODE": "confirm", "VIBE_STICK_AUTO_ENTER": "0"},
            clear=True,
        ):
            self._start()
            session = self._stop()

        self.assertEqual(session.interaction_version, 1)
        self.assertEqual(session.send_mode, "paste_only")
        self.assertEqual(session.status, "pasted")
        self.assertEqual(self.controller.send_session_snapshot().phase, SendSessionPhase.IDLE)
        self.controller.paste_injector.paste.assert_called_once_with(
            "hello from VibeStick",
            press_enter=False,
        )

    def test_m3b_confirm_mode_arms_pending_send_after_paste(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            session = self._stop()

        pending = self.controller.send_session_snapshot()
        self.assertEqual(session.interaction_version, 2)
        self.assertEqual(session.send_mode, "confirm")
        self.assertEqual(session.status, "pending_send")
        self.assertEqual(pending.phase, SendSessionPhase.PENDING)
        self.assertEqual(pending.session_id, self.session_id)
        self.assertEqual(pending.target, _target())

    def test_m3b_without_a_focused_input_copies_transcript_without_failing(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Paste attempted; transcript remains on the clipboard",
            None,
            "clipboard",
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            session = self._stop()

        self.assertEqual(session.status, "copied")
        self.assertFalse(session.pasted)
        self.assertEqual(
            self.controller.send_session_snapshot().phase,
            SendSessionPhase.IDLE,
        )

    def test_m3b_confirmation_sends_return_once_and_is_idempotent(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        self.controller.paste_injector.inspect_target.return_value = PasteResult(
            True,
            "Focused input identified",
            _target(),
        )
        self.controller.paste_injector.confirm_return.return_value = PasteResult(
            True,
            "Return sent to the confirmed input",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            self._stop()
            with (
                mock.patch("vibe_stick.audio.recorder.show_hud"),
                mock.patch("vibe_stick.audio.recorder.hide_hud"),
            ):
                first = self.controller.confirm_send(self.session_id)
                duplicate = self.controller.confirm_send(self.session_id)

        self.assertTrue(first.accepted)
        self.assertEqual(first.snapshot.phase, SendSessionPhase.SENT)
        self.assertFalse(duplicate.accepted)
        self.assertEqual(duplicate.reason, "confirmation_already_consumed")
        self.assertEqual(self.controller.session.status, "sent")
        self.controller.paste_injector.inspect_target.assert_called_once_with()
        self.controller.paste_injector.confirm_return.assert_called_once_with(_target())

    def test_changed_target_never_calls_confirm_return(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        self.controller.paste_injector.inspect_target.return_value = PasteResult(
            True,
            "Focused input identified",
            _target(process_id=99),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            self._stop()
            with mock.patch("vibe_stick.audio.recorder.show_hud"):
                result = self.controller.confirm_send(self.session_id)

        self.assertFalse(result.accepted)
        self.assertEqual(result.snapshot.phase, SendSessionPhase.INVALIDATED)
        self.assertEqual(self.controller.session.status, "send_failed")
        self.controller.paste_injector.confirm_return.assert_not_called()

    def test_transient_target_inspection_failure_is_retried_before_send(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        self.controller.paste_injector.inspect_target.side_effect = [
            PasteResult(False, "Focused input could not be verified"),
            PasteResult(True, "Focused input identified", _target()),
        ]
        self.controller.paste_injector.confirm_return.return_value = PasteResult(
            True,
            "Return sent to the confirmed input",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            self._stop()
            with (
                mock.patch("vibe_stick.audio.recorder.show_hud"),
                mock.patch("vibe_stick.audio.recorder.hide_hud"),
                mock.patch("vibe_stick.audio.recorder.time.sleep") as sleep,
            ):
                result = self.controller.confirm_send(self.session_id)

        self.assertTrue(result.accepted)
        self.assertEqual(result.snapshot.phase, SendSessionPhase.SENT)
        self.assertEqual(self.controller.paste_injector.inspect_target.call_count, 2)
        sleep.assert_called_once_with(0.12)
        self.controller.paste_injector.confirm_return.assert_called_once_with(_target())

    def test_new_recording_invalidates_previous_pending_send(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            self._stop()
            self._start(
                interaction_version=2,
                session_id="11111111111111111111111111111111",
            )

        self.assertEqual(
            self.controller.send_session_snapshot().phase,
            SendSessionPhase.INVALIDATED,
        )
        self.assertEqual(self.controller.session.status, "recording")

    def test_m3b_stop_rejects_a_mismatched_session_before_paste(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            session = self._stop(session_id="11111111111111111111111111111111")

        self.assertEqual(session.status, "stop_failed")
        self.assertFalse(session.pasted)
        self.assertEqual(self.controller.send_session_snapshot().phase, SendSessionPhase.IDLE)
        self.controller.paste_injector.paste.assert_not_called()

    def test_m3b_auto_send_preserves_single_helper_operation(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted and sent",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "auto_send"}, clear=True):
            self._start(interaction_version=2)
            session = self._stop()

        self.assertEqual(session.status, "sent")
        self.controller.paste_injector.paste.assert_called_once_with(
            "hello from VibeStick",
            press_enter=True,
        )
        self.controller.paste_injector.confirm_return.assert_not_called()

    def test_recording_state_is_private_and_omits_transcript_material(self) -> None:
        self.controller.paste_injector.paste.return_value = PasteResult(
            True,
            "Pasted into the focused app",
            _target(),
        )
        with mock.patch.dict(os.environ, {"VIBE_STICK_SEND_MODE": "confirm"}, clear=True):
            self._start(interaction_version=2)
            session = self._stop()

        state_path = Path(self.temporary.name) / "recording.json"
        persisted = json.loads(state_path.read_text(encoding="utf-8"))
        permissions = state_path.stat().st_mode & 0o777

        self.assertEqual(session.transcript, "hello from VibeStick")
        self.assertEqual(persisted["schema_version"], 2)
        self.assertEqual(persisted["status"], "pending_send")
        self.assertNotIn("transcript", persisted)
        self.assertNotIn("audio_file", persisted)
        self.assertNotIn("message", persisted)
        self.assertNotIn("hello from VibeStick", state_path.read_text(encoding="utf-8"))
        self.assertEqual(permissions, 0o600)

        restored = RecordingController(
            state_path,
            pending_send_path=Path(self.temporary.name) / "pending-send-v1.json",
        )
        self.assertEqual(restored.session.status, "pending_send")
        self.assertEqual(restored.session.transcript, "")
        self.assertEqual(restored.session.audio_file, "")


if __name__ == "__main__":
    unittest.main()
