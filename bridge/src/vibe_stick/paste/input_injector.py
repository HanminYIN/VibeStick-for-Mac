from __future__ import annotations

import json
import os
import platform
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class PasteResult:
    success: bool
    message: str


class MacPasteInjector:
    def paste(self, text: str, press_enter: bool = False) -> PasteResult:
        text = text.strip()
        if not text:
            return PasteResult(False, "No text to paste")
        if platform.system() != "Darwin":
            return PasteResult(False, "Automatic paste is only available on macOS")

        helper = os.environ.get("VIBE_STICK_PASTE_HELPER", "").strip()
        if helper:
            return self._paste_with_helper(helper, text, press_enter)

        previous_text = self._read_clipboard()
        set_result = self._set_clipboard(text)
        if not set_result.success:
            return set_result

        script = [
            'tell application "System Events" to keystroke "v" using command down',
        ]
        if press_enter:
            script.extend([
                "delay 0.12",
                'tell application "System Events" to key code 36',
            ])

        args = ["osascript"]
        for line in script:
            args.extend(["-e", line])
        result = subprocess.run(args, check=False, capture_output=True, text=True, timeout=5)
        time.sleep(0.2)
        if previous_text is not None:
            self._set_clipboard(previous_text)

        if result.returncode != 0:
            message = (result.stderr or result.stdout or "macOS paste failed").strip()
            return PasteResult(False, message)
        return PasteResult(True, "Pasted into the focused app")

    def _paste_with_helper(self, helper: str, text: str, press_enter: bool) -> PasteResult:
        helper_path = Path(helper).expanduser()
        if not helper_path.is_dir():
            return PasteResult(False, f"VibeStick Paste helper not found: {helper_path}")

        with tempfile.TemporaryDirectory(prefix="vibestick-paste-") as tmp:
            request_path = Path(tmp) / "request.json"
            response_path = Path(tmp) / "response.json"
            request_path.write_text(
                json.dumps({"text": text, "press_enter": press_enter}),
                encoding="utf-8",
            )
            os.chmod(request_path, 0o600)
            args = [
                "/usr/bin/open",
                "-W",
                "-g",
                "-n",
                str(helper_path),
                "--args",
                "--request",
                str(request_path),
                "--response",
                str(response_path),
            ]
            try:
                result = subprocess.run(
                    args,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                return PasteResult(False, f"VibeStick Paste helper failed: {exc}")
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "VibeStick Paste helper failed").strip()
                return PasteResult(False, message)
            try:
                response = json.loads(response_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                return PasteResult(False, f"VibeStick Paste helper returned no result: {exc}")
            success = bool(response.get("success"))
            message = str(response.get("message") or "VibeStick Paste helper failed")
            return PasteResult(success, message)

    def _read_clipboard(self) -> str | None:
        try:
            result = subprocess.run(
                ["pbpaste"],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        return result.stdout

    def _set_clipboard(self, text: str) -> PasteResult:
        try:
            result = subprocess.run(
                ["pbcopy"],
                input=text,
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return PasteResult(False, f"Clipboard write failed: {exc}")
        if result.returncode != 0:
            message = (result.stderr or "Clipboard write failed").strip()
            return PasteResult(False, message)
        return PasteResult(True, "Clipboard updated")
