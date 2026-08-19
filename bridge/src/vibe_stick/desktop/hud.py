from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from vibe_stick.config.paths import HUD_STATE_PATH, ensure_app_support

HUD_TEXT = {
    "listening": "正在聆听",
    "sending": "正在发送",
    "transcribing": "正在识别",
    "unclear": "未听清",
    "failed": "识别失败",
    "send_failed": "发送失败",
}


def show_hud(status: str, *, hold_seconds: float | None = None) -> None:
    text = HUD_TEXT.get(status, status)
    now = time.time()
    _write_hud_state(
        {
            "active": True,
            "status": status,
            "text": text,
            "updated_at_epoch": now,
            "expires_at_epoch": now + hold_seconds if hold_seconds else None,
        }
    )


def hide_hud(*, delay_seconds: float = 0.0) -> None:
    now = time.time()
    if delay_seconds > 0:
        current = _read_hud_state()
        if current is not None and _is_active_and_unexpired(current, now=now):
            _write_hud_state(
                {
                    "active": True,
                    "status": current["status"],
                    "text": current["text"],
                    "updated_at_epoch": now,
                    "expires_at_epoch": now + delay_seconds,
                }
            )
            return
    _write_hud_state(
        {
            "active": False,
            "status": "idle",
            "text": "",
            "updated_at_epoch": now,
            "expires_at_epoch": None,
        }
    )


def _read_hud_state() -> dict[str, Any] | None:
    try:
        payload = json.loads(HUD_STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _is_active_and_unexpired(payload: dict[str, Any], *, now: float) -> bool:
    if payload.get("active") is not True:
        return False
    if not isinstance(payload.get("status"), str) or not isinstance(payload.get("text"), str):
        return False
    expires_at = payload.get("expires_at_epoch")
    if expires_at is None:
        return True
    if isinstance(expires_at, bool) or not isinstance(expires_at, (int, float)):
        return False
    return expires_at > now


def _write_hud_state(payload: dict[str, Any]) -> None:
    ensure_app_support()
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    tmp_path = HUD_STATE_PATH.with_suffix(".json.tmp")
    try:
        tmp_path.write_text(data, encoding="utf-8")
        tmp_path.replace(HUD_STATE_PATH)
    except OSError as exc:
        print(f"hud state write failed path={HUD_STATE_PATH} error={exc}", flush=True)
        _cleanup_tmp(tmp_path)


def _cleanup_tmp(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass
