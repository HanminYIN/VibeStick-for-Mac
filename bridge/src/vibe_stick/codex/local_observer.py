from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from vibe_stick.codex.quota import QuotaSnapshot
from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers._jsonl import session_files, tail_json_events


CODEX_HOME = Path.home() / ".codex"
SESSIONS_DIR = CODEX_HOME / "sessions"
TAIL_BYTES = 1_500_000
MAX_SESSION_FILES = 40
RUNNING_ACTIVITY_WINDOW = timedelta(minutes=4)
ALERT_ACTIVITY_WINDOW = timedelta(minutes=5)
QUOTA_STALE_AFTER = timedelta(minutes=30)


@dataclass
class LocalCodexObservation:
    status: AgentStatus
    project: str
    quota: QuotaSnapshot | None
    quota_found: bool
    alert_type: str = ""
    alert_message: str = ""
    alert_timestamp: datetime | None = None
    latest_event_type: str = ""
    latest_event_timestamp: datetime | None = None
    latest_session_path: str = ""
    codex_online: bool = False


def observe_codex(project_root: Path) -> LocalCodexObservation:
    now = datetime.now(timezone.utc)
    codex_online = _codex_process_running()
    project = _project_name_from_env_or_root(project_root)
    latest_cwd: Path | None = None
    latest_cwd_timestamp: datetime | None = None
    latest_event: tuple[datetime, str, str] | None = None
    latest_alert: tuple[datetime, AgentStatus, str, str] | None = None
    latest_quota: tuple[datetime, QuotaSnapshot] | None = None
    latest_session_path = ""

    for session_path in _session_files():
        latest_session_path = latest_session_path or str(session_path)
        for event in _tail_json_events(session_path):
            timestamp = _parse_timestamp(event.get("timestamp"))
            if timestamp is None:
                continue

            top_type = str(event.get("type") or "")
            payload = event.get("payload")
            payload = payload if isinstance(payload, dict) else {}
            payload_type = str(payload.get("type") or top_type)
            candidate_type = payload_type or top_type

            if top_type == "turn_context":
                cwd = payload.get("cwd")
                if isinstance(cwd, str) and cwd:
                    if latest_cwd is None or _is_newer(timestamp, latest_cwd_timestamp):
                        latest_cwd = Path(cwd)
                        latest_cwd_timestamp = timestamp

            if candidate_type:
                if latest_event is None or timestamp > latest_event[0]:
                    latest_event = (timestamp, candidate_type, str(payload.get("message") or ""))

            quota = _quota_from_payload(payload, timestamp, now)
            if quota is not None and (latest_quota is None or timestamp > latest_quota[0]):
                latest_quota = (timestamp, quota)

            alert = _alert_from_payload(candidate_type, payload)
            if alert is not None:
                alert_status, alert_kind, message = alert
                if latest_alert is None or timestamp > latest_alert[0]:
                    latest_alert = (timestamp, alert_status, alert_kind, message)

    if latest_cwd is not None:
        project = _project_name_from_path(latest_cwd)

    quota_snapshot = latest_quota[1] if latest_quota else None
    alert_is_latest = bool(
        latest_alert
        and now - latest_alert[0] <= ALERT_ACTIVITY_WINDOW
        and (latest_event is None or latest_alert[0] >= latest_event[0])
    )

    if not codex_online:
        status = AgentStatus.OFFLINE
    elif alert_is_latest and latest_alert:
        status = latest_alert[1]
    elif latest_event and now - latest_event[0] <= RUNNING_ACTIVITY_WINDOW:
        status = AgentStatus.RUNNING
    else:
        status = AgentStatus.IDLE

    observation = LocalCodexObservation(
        status=status,
        project=project,
        quota=quota_snapshot,
        quota_found=quota_snapshot is not None,
        latest_session_path=latest_session_path,
        codex_online=codex_online,
    )
    if latest_alert and status == latest_alert[1]:
        observation.alert_timestamp = latest_alert[0]
        observation.alert_type = latest_alert[2]
        observation.alert_message = latest_alert[3]
    if latest_event:
        observation.latest_event_timestamp = latest_event[0]
        observation.latest_event_type = latest_event[1]
    return observation


def _session_files() -> list[Path]:
    return session_files(SESSIONS_DIR, max_files=MAX_SESSION_FILES)


def _tail_json_events(path: Path) -> list[dict[str, Any]]:
    return list(tail_json_events(path, tail_bytes=TAIL_BYTES))


def _quota_from_payload(
    payload: dict[str, Any],
    timestamp: datetime,
    now: datetime,
) -> QuotaSnapshot | None:
    if payload.get("type") != "token_count":
        return None
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return None

    five_hour = None
    seven_day = None
    for window in ("primary", "secondary"):
        data = rate_limits.get(window)
        if not isinstance(data, dict):
            continue
        remaining = _remaining_percent(data.get("used_percent"))
        minutes = data.get("window_minutes")
        if minutes == 300:
            five_hour = remaining
        elif minutes == 10080:
            seven_day = remaining

    if five_hour is None and seven_day is None:
        return None

    return QuotaSnapshot(
        quota_5h_remaining=five_hour,
        quota_7d_remaining=seven_day,
        quota_updated_at=timestamp.astimezone().strftime("%H:%M"),
        quota_stale=now - timestamp > QUOTA_STALE_AFTER,
    )


def _remaining_percent(used_percent: object) -> int | None:
    try:
        used = float(used_percent)
    except (TypeError, ValueError):
        return None
    return max(0, min(100, int(round(100.0 - used))))


def _alert_from_payload(
    payload_type: str,
    payload: dict[str, Any],
) -> tuple[AgentStatus, str, str] | None:
    normalized = payload_type.lower()
    if normalized == "task_complete":
        return (AgentStatus.DONE, "DONE", "Codex task completed")
    if "approval" in normalized or "permission" in normalized:
        return (AgentStatus.APPROVAL, "APPROVAL", "Codex is waiting for approval")
    if normalized in {"error", "agent_error"} or normalized.endswith("_error"):
        message = str(payload.get("message") or payload.get("error") or "Codex task failed or needs attention")
        return (AgentStatus.ERROR, "ERROR", message)
    rate_limit_reached = payload.get("rate_limit_reached_type")
    if rate_limit_reached:
        return (AgentStatus.ERROR, "ERROR", "Codex quota limit reached")
    return None


def _parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _is_newer(value: datetime, other: datetime | None) -> bool:
    return other is None or value > other


def _codex_process_running() -> bool:
    try:
        result = subprocess.run(
            ["ps", "-axo", "command="],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0:
        return False

    for line in result.stdout.splitlines():
        if _is_codex_process_command(line):
            return True
    return False


def _is_codex_process_command(command: str) -> bool:
    lower = command.lower()
    if "/applications/codex.app/" in lower:
        return True
    if "codex app-server" in lower:
        return True
    return (
        "/applications/chatgpt.app/contents/resources/codex" in lower
        and " app-server" in lower
    )


def _project_name_from_env_or_root(project_root: Path) -> str:
    configured = os.environ.get("VIBE_STICK_PROJECT_NAME", "").strip()
    if configured:
        return configured
    return _project_name_from_path(project_root)


def _project_name_from_path(path: Path) -> str:
    root = path.expanduser().resolve()
    if root.name in {"bridge", "firmware", "app", "scripts"} and (root.parent / "README.md").exists():
        root = root.parent
    return root.name or "vibestick"
