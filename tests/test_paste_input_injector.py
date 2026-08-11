import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from vibe_stick.paste.input_injector import MacPasteInjector


class MacPasteInjectorTests(unittest.TestCase):
    def test_installed_helper_receives_text_without_exposing_it_in_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "VibeStick Paste.app"
            helper.mkdir()

            def launch_helper(args, **kwargs):
                request_path = Path(args[args.index("--request") + 1])
                response_path = Path(args[args.index("--response") + 1])
                request = json.loads(request_path.read_text())
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
        run.assert_called_once()
        args, kwargs = run.call_args
        self.assertEqual(args[0][:6], ["/usr/bin/open", "-W", "-g", "-n", str(helper), "--args"])
        self.assertEqual(kwargs, {"check": False, "capture_output": True, "text": True, "timeout": 5})

    def test_configured_missing_helper_is_reported(self) -> None:
        with (
            patch.dict(os.environ, {"VIBE_STICK_PASTE_HELPER": "/missing/VibeStickPaste"}),
            patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin"),
        ):
            result = MacPasteInjector().paste("hello")

        self.assertFalse(result.success)
        self.assertIn("not found", result.message)


if __name__ == "__main__":
    unittest.main()
