import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from vibe_stick.audio.send_session import SendTarget, TARGET_SCOPE_CHATGPT_WINDOW
from vibe_stick.paste.input_injector import MacPasteInjector


class MacPasteInjectorTests(unittest.TestCase):
    def test_swift_helper_attempts_paste_before_clipboard_only_fallback(self) -> None:
        source = (
            Path(__file__).resolve().parents[1]
            / "app/macos/VibeStickPaste/main.swift"
        ).read_text()
        perform_paste = source.split("private func performPaste", 1)[1].split(
            "private func inspectTarget", 1
        )[0]

        self.assertIn("postKey(9, flags: .maskCommand)", perform_paste)
        self.assertIn("guard let target else", perform_paste)
        self.assertLess(
            perform_paste.index("postKey(9, flags: .maskCommand)"),
            perform_paste.index("guard let target else"),
        )
        self.assertIn("Paste attempted; transcript remains on the clipboard", perform_paste)

    def test_swift_helper_limits_window_fallback_to_chatgpt_confirm_mode(self) -> None:
        source = (
            Path(__file__).resolve().parents[1]
            / "app/macos/VibeStickPaste/main.swift"
        ).read_text()

        self.assertIn(
            'chatGPTCompatibilityBundleIDs: Set<String> = ["com.openai.codex"]',
            source,
        )
        self.assertIn('private let chatGPTWindowScope = "chatgpt_window"', source)
        self.assertIn("kAXFocusedWindowAttribute", source)
        self.assertIn("allowChatGPTWindowFallback: !pressEnter", source)
        self.assertIn('delivery: target.verification_scope == chatGPTWindowScope', source)
        self.assertIn('? "pasted_compat"', source)

    def test_installed_helper_receives_text_without_exposing_it_in_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                request_path = Path(args[args.index("--request") + 1])
                response_path = Path(args[args.index("--response") + 1])
                request = json.loads(request_path.read_text())
                self.assertEqual(request["operation"], "paste")
                self.assertEqual(request["text"], "hello from VibeStick")
                self.assertTrue(request["press_enter"])
                self.assertNotIn("hello from VibeStick", " ".join(args))
                response_path.write_text(json.dumps({"success": True, "message": "Pasted into the focused app"}))
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin"),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().paste("hello from VibeStick", press_enter=True)

        self.assertTrue(result.success)
        self.assertEqual(run.call_count, 2)
        args, kwargs = run.call_args_list[0]
        self.assertEqual(args[0][:6], ["/usr/bin/open", "-W", "-g", "-n", str(helper), "--args"])
        self.assertEqual(kwargs, {"check": False, "capture_output": True, "text": True, "timeout": 5})
        unregister_args, unregister_kwargs = run.call_args_list[1]
        self.assertTrue(unregister_args[0][0].endswith("/lsregister"))
        self.assertEqual(unregister_args[0][1:], ["-u", str(helper)])
        self.assertEqual(
            unregister_kwargs,
            {"check": False, "capture_output": True, "text": True, "timeout": 2},
        )

    def test_configured_missing_helper_is_reported(self) -> None:
        with (
            patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": "/missing/VibeStickPaste"}),
            patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin"),
        ):
            result = MacPasteInjector().paste("hello")

        self.assertFalse(result.success)
        self.assertIn("not found", result.message)

    def test_helper_target_identity_is_parsed_without_window_content(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                request_path = Path(args[args.index("--request") + 1])
                response_path = Path(args[args.index("--response") + 1])
                request = json.loads(request_path.read_text())
                self.assertEqual(request["operation"], "inspect_target")
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Focused input identified",
                            "target": {
                                "bundle_id": "com.openai.codex",
                                "process_id": 42,
                                "focus_fingerprint": "a" * 64,
                            },
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().inspect_target()

        self.assertTrue(result.success)
        self.assertIsNotNone(result.target)
        self.assertEqual(result.target.bundle_id, "com.openai.codex")
        self.assertEqual(result.target.process_id, 42)
        self.assertEqual(result.target.verification_scope, "focused_input")

    def test_chatgpt_window_target_and_compatibility_delivery_are_parsed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                response_path = Path(args[args.index("--response") + 1])
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Pasted into ChatGPT; waiting for blue-button confirmation",
                            "target": {
                                "bundle_id": "com.openai.codex",
                                "process_id": 42,
                                "focus_fingerprint": "d" * 64,
                                "verification_scope": TARGET_SCOPE_CHATGPT_WINDOW,
                            },
                            "delivery": "pasted_compat",
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin"),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().paste("hello from VibeStick")

        self.assertTrue(result.success)
        self.assertIsNotNone(result.target)
        self.assertEqual(result.target.verification_scope, TARGET_SCOPE_CHATGPT_WINDOW)
        self.assertEqual(result.delivery, "pasted_compat")

    def test_target_inspection_preserves_the_expected_verification_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()
            expected_target = SendTarget.normalized(
                bundle_id="com.openai.codex",
                process_id=42,
                focus_fingerprint="e" * 64,
                verification_scope=TARGET_SCOPE_CHATGPT_WINDOW,
            )
            self.assertIsNotNone(expected_target)

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                request_path = Path(args[args.index("--request") + 1])
                response_path = Path(args[args.index("--response") + 1])
                request = json.loads(request_path.read_text())
                self.assertEqual(request["operation"], "inspect_target")
                self.assertEqual(
                    request["expected_target"]["verification_scope"],
                    TARGET_SCOPE_CHATGPT_WINDOW,
                )
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Focused ChatGPT window identified",
                            "target": request["expected_target"],
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().inspect_target(expected_target)

        self.assertTrue(result.success)
        self.assertEqual(result.target, expected_target)

    def test_clipboard_fallback_is_a_success_without_a_send_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                response_path = Path(args[args.index("--response") + 1])
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Paste attempted; transcript remains on the clipboard",
                            "target": None,
                            "delivery": "clipboard",
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin"),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().paste("hello from VibeStick")

        self.assertTrue(result.success)
        self.assertIsNone(result.target)
        self.assertEqual(result.delivery, "clipboard")

    def test_confirm_return_passes_only_expected_target_and_no_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()
            expected_target = SendTarget.normalized(
                bundle_id="com.openai.codex",
                process_id=42,
                focus_fingerprint="b" * 64,
            )
            self.assertIsNotNone(expected_target)

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                request_path = Path(args[args.index("--request") + 1])
                response_path = Path(args[args.index("--response") + 1])
                request = json.loads(request_path.read_text())
                self.assertEqual(request["operation"], "confirm_return")
                self.assertEqual(request["expected_target"]["bundle_id"], "com.openai.codex")
                self.assertEqual(
                    request["expected_target"]["verification_scope"],
                    "focused_input",
                )
                self.assertNotIn("text", request)
                self.assertNotIn("transcript", request)
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Return sent to the confirmed input",
                            "target": request["expected_target"],
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().confirm_return(expected_target)

        self.assertTrue(result.success)
        self.assertEqual(result.target, expected_target)

    def test_confirm_return_rejects_helper_target_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()
            expected_target = SendTarget.normalized(
                bundle_id="com.openai.codex",
                process_id=42,
                focus_fingerprint="b" * 64,
            )
            self.assertIsNotNone(expected_target)

            def launch_helper(args, **kwargs):
                if args[0].endswith("/lsregister"):
                    return subprocess.CompletedProcess(args, 0, "", "")
                response_path = Path(args[args.index("--response") + 1])
                response_path.write_text(
                    json.dumps(
                        {
                            "success": True,
                            "message": "Return sent",
                            "target": {
                                "bundle_id": "com.openai.codex",
                                "process_id": 99,
                                "focus_fingerprint": "c" * 64,
                            },
                        }
                    )
                )
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": str(helper)}),
                patch("vibe_stick.paste.input_injector.subprocess.run") as run,
            ):
                run.side_effect = launch_helper
                result = MacPasteInjector().confirm_return(expected_target)

        self.assertFalse(result.success)
        self.assertIn("different target", result.message)


if __name__ == "__main__":
    unittest.main()
