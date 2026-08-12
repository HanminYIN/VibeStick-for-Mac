from __future__ import annotations

import json
import os
import platform
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from vibe_stick.audio.send_session import SendTarget


_LSREGISTER_PATH = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)


@dataclass
class PasteResult:
    success: bool
    message: str
    target: SendTarget | None = None
    delivery: str = ""


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

    def inspect_target(self) -> PasteResult:
        helper = os.environ.get("VIBE_STICK_PASTE_HELPER", "").strip()
        if not helper:
            return PasteResult(False, "Focused-target inspection requires VibeStick Paste")
        result = self._invoke_helper(helper, {"operation": "inspect_target"})
        if result.success and result.target is None:
            return PasteResult(False, "VibeStick Paste returned no focused target")
        return result

    def confirm_return(self, expected_target: SendTarget) -> PasteResult:
        helper = os.environ.get("VIBE_STICK_PASTE_HELPER", "").strip()
        if not helper:
            return PasteResult(False, "Confirmed Return requires VibeStick Paste")
        result = self._invoke_helper(
            helper,
            {
                "operation": "confirm_return",
                "expected_target": asdict(expected_target),
            },
        )
        if result.success and result.target != expected_target:
            return PasteResult(False, "VibeStick Paste confirmed a different target", result.target)
        return result

    def _paste_with_helper(self, helper: str, text: str, press_enter: bool) -> PasteResult:
        return self._invoke_helper(
            helper,
            {
                "operation": "paste",
                "text": text,
                "press_enter": press_enter,
            },
        )

    def _invoke_helper(self, helper: str, request: dict[str, object]) -> PasteResult:
        helper_path = Path(helper).expanduser()
        if not helper_path.is_dir():
            return PasteResult(False, f"VibeStick Paste helper not found: {helper_path}")

        with tempfile.TemporaryDirectory(prefix="vibestick-paste-") as tmp:
            request_path = Path(tmp) / "request.json"
            response_path = Path(tmp) / "response.json"
            request_path.write_text(
                json.dumps(request),
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
            finally:
                self._unregister_helper(helper_path)
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "VibeStick Paste helper failed").strip()
                return PasteResult(False, message)
            try:
                response = json.loads(response_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                return PasteResult(False, f"VibeStick Paste helper returned no result: {exc}")
            success = bool(response.get("success"))
            message = str(response.get("message") or "VibeStick Paste helper failed")
            target = _target_from_response(response.get("target"))
            delivery = _delivery_from_response(response.get("delivery"), success=success, target=target)
            return PasteResult(success, message, target, delivery)

    @staticmethod
    def _unregister_helper(helper_path: Path) -> None:
        try:
            subprocess.run(
                [str(_LSREGISTER_PATH), "-u", str(helper_path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass

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


def _target_from_response(raw: object) -> SendTarget | None:
    if not isinstance(raw, dict):
        return None
    return SendTarget.normalized(
        bundle_id=str(raw.get("bundle_id") or ""),
        process_id=raw.get("process_id"),
        focus_fingerprint=str(raw.get("focus_fingerprint") or ""),
    )


def _delivery_from_response(
    raw: object,
    *,
    success: bool,
    target: SendTarget | None,
) -> str:
    value = str(raw or "").strip().lower()
    if value in {"pasted", "clipboard"}:
        return value
    if success:
        return "pasted" if target is not None else ""
    return ""
