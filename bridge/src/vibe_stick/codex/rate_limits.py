from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from vibe_stick.codex.quota import QuotaSnapshot


DEFAULT_TIMEOUT_SECONDS = 15.0
APP_SERVER_CLIENT_NAME = "vibestick-bridge"
APP_SERVER_CLIENT_VERSION = "0.2.0"
CODEX_EXECUTABLE_CANDIDATES = (
    Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
    Path("/Applications/Codex.app/Contents/Resources/codex"),
)


def fetch_account_quota(
    *,
    executable: Path | None = None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> QuotaSnapshot | None:
    """Read account-wide Codex limits through the local app-server protocol.

    This method initializes a short-lived local Codex app-server and invokes
    only ``account/rateLimits/read``. Responses are parsed in memory; account
    metadata, credits, and authentication data are never returned or stored.
    """

    codex = executable or _resolve_codex_executable()
    if codex is None:
        return None

    try:
        process = subprocess.Popen(
            [str(codex), "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except OSError:
        return None

    deadline = time.monotonic() + max(1.0, timeout_seconds)
    try:
        if process.stdin is None or process.stdout is None:
            return None
        _send_message(
            process,
            {
                "method": "initialize",
                "id": 1,
                "params": {
                    "clientInfo": {
                        "name": APP_SERVER_CLIENT_NAME,
                        "version": APP_SERVER_CLIENT_VERSION,
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
        )
        initialized = _read_response(process, request_id=1, deadline=deadline)
        if initialized is None or initialized.get("error") is not None:
            return None

        _send_message(process, {"method": "initialized", "params": {}})
        _send_message(
            process,
            {"method": "account/rateLimits/read", "id": 2, "params": None},
        )
        response = _read_response(process, request_id=2, deadline=deadline)
        if response is None or response.get("error") is not None:
            return None
        result = response.get("result")
        return quota_from_rate_limits_result(result)
    except (BrokenPipeError, OSError, ValueError):
        return None
    finally:
        _stop_process(process)


def quota_from_rate_limits_result(
    result: object,
    *,
    observed_at: datetime | None = None,
) -> QuotaSnapshot | None:
    if not isinstance(result, dict):
        return None

    snapshot = None
    by_limit_id = result.get("rateLimitsByLimitId")
    if isinstance(by_limit_id, dict):
        candidate = by_limit_id.get("codex")
        if isinstance(candidate, dict):
            snapshot = candidate

    if snapshot is None:
        historical = result.get("rateLimits")
        if isinstance(historical, dict):
            limit_id = str(historical.get("limitId") or "codex").strip().lower()
            if limit_id == "codex":
                snapshot = historical
    if snapshot is None:
        return None

    five_hour = None
    seven_day = None
    for name in ("primary", "secondary"):
        window = snapshot.get(name)
        if not isinstance(window, dict):
            continue
        used = _percent_or_none(window.get("usedPercent"))
        duration = window.get("windowDurationMins")
        if used is None:
            continue
        remaining = 100 - used
        if duration == 300:
            five_hour = remaining
        elif duration == 10080:
            seven_day = remaining

    if five_hour is None and seven_day is None:
        return None

    timestamp = observed_at or datetime.now(timezone.utc)
    return QuotaSnapshot(
        quota_5h_remaining=five_hour,
        quota_7d_remaining=seven_day,
        quota_updated_at=timestamp.astimezone().strftime("%H:%M"),
        quota_stale=False,
        quota_source="codex-app-server",
        quota_observed_at_epoch=timestamp.timestamp(),
    )


def _resolve_codex_executable() -> Path | None:
    configured = os.environ.get("VIBE_STICK_CODEX_CLI", "").strip()
    if configured:
        candidate = Path(configured).expanduser()
        return candidate if candidate.is_file() else None
    for candidate in CODEX_EXECUTABLE_CANDIDATES:
        if candidate.is_file():
            return candidate
    discovered = shutil.which("codex")
    return Path(discovered) if discovered else None


def _send_message(process: subprocess.Popen[str], message: dict[str, Any]) -> None:
    if process.stdin is None:
        raise BrokenPipeError
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def _read_response(
    process: subprocess.Popen[str],
    *,
    request_id: int,
    deadline: float,
) -> dict[str, Any] | None:
    if process.stdout is None:
        return None
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([process.stdout], [], [], remaining)
        if not ready:
            return None
        line = process.stdout.readline()
        if not line:
            return None
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            return message
    return None


def _stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def _percent_or_none(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return max(0, min(100, number))
