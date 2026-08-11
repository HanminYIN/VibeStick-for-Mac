from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
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
MAX_DISCOVERY_SESSION_FILES = 160
MAX_UNKNOWN_SESSION_FILES = 10
SESSION_META_BYTES = 262_144
RUNNING_ACTIVITY_WINDOW = timedelta(minutes=4)
ALERT_ACTIVITY_WINDOW = timedelta(minutes=5)
QUOTA_STALE_AFTER = timedelta(minutes=30)


@dataclass(frozen=True)
class _SessionIdentity:
    session_id: str
    user_initiated: bool | None


@dataclass(frozen=True)
class _AlertCandidate:
    timestamp: datetime
    status: AgentStatus
    kind: str
    message: str
    event_key: str


@dataclass
class _SessionObservation:
    identity: _SessionIdentity
    latest_event: tuple[datetime, str, str] | None = None
    latest_cwd: tuple[datetime, Path] | None = None
    latest_lifecycle: tuple[datetime, str] | None = None
    active_turns: set[str] = field(default_factory=set)
    completion: _AlertCandidate | None = None
    approval: _AlertCandidate | None = None
    error: _AlertCandidate | None = None
    quota: tuple[datetime, QuotaSnapshot] | None = None


_SESSION_IDENTITY_CACHE: dict[Path, _SessionIdentity] = {}


@dataclass
class LocalCodexObservation:
    status: AgentStatus
    project: str
    quota: QuotaSnapshot | None
    quota_found: bool
    alert_type: str = ""
    alert_message: str = ""
    alert_timestamp: datetime | None = None
    alert_event_key: str = ""
    latest_event_type: str = ""
    latest_event_timestamp: datetime | None = None
    latest_session_path: str = ""
    codex_online: bool = False


def observe_codex(project_root: Path) -> LocalCodexObservation:
    now = datetime.now(timezone.utc)
    codex_online = _codex_process_running()
    project = _project_name_from_env_or_root(project_root)
    latest_cwd: tuple[datetime, Path] | None = None
    latest_event: tuple[datetime, str, str] | None = None
    latest_fallback_event: tuple[datetime, str, str] | None = None
    latest_completion: _AlertCandidate | None = None
    latest_approval: _AlertCandidate | None = None
    latest_error: _AlertCandidate | None = None
    latest_quota: tuple[datetime, QuotaSnapshot] | None = None
    latest_session_path = ""
    user_session_found = False
    user_task_running = False

    for session_path, identity in _session_candidates():
        session = _observe_session(session_path, identity, now)
        if session.quota is not None and (
            latest_quota is None or session.quota[0] > latest_quota[0]
        ):
            latest_quota = session.quota

        if identity.user_initiated is not True:
            if session.latest_event is not None and (
                latest_fallback_event is None
                or session.latest_event[0] > latest_fallback_event[0]
            ):
                latest_fallback_event = session.latest_event
            continue

        user_session_found = True
        latest_session_path = latest_session_path or str(session_path)
        if session.latest_event is not None and (
            latest_event is None or session.latest_event[0] > latest_event[0]
        ):
            latest_event = session.latest_event
        if session.latest_cwd is not None and (
            latest_cwd is None or session.latest_cwd[0] > latest_cwd[0]
        ):
            latest_cwd = session.latest_cwd

        user_task_running = user_task_running or _session_is_running(session, now)
        if (
            session.completion is not None
            and now - session.completion.timestamp <= ALERT_ACTIVITY_WINDOW
            and _completion_is_confirmed(session, session.completion)
        ):
            latest_completion = _newer_alert(latest_completion, session.completion)
        if _alert_is_current(session, session.approval, now):
            latest_approval = _newer_alert(latest_approval, session.approval)
        if _alert_is_current(session, session.error, now):
            latest_error = _newer_alert(latest_error, session.error)

    if latest_cwd is not None:
        project = _project_name_from_path(latest_cwd[1])

    if latest_event is None and not user_session_found:
        latest_event = latest_fallback_event

    quota_snapshot = latest_quota[1] if latest_quota else None
    selected_alert = latest_error or latest_approval or latest_completion

    if not codex_online:
        status = AgentStatus.OFFLINE
        selected_alert = None
    elif latest_error is not None:
        status = AgentStatus.ERROR
    elif latest_approval is not None:
        status = AgentStatus.APPROVAL
    elif user_task_running:
        status = AgentStatus.RUNNING
    elif latest_completion is not None:
        status = AgentStatus.DONE
    elif (
        latest_event
        and latest_event[1].lower() not in {"task_complete", "turn_aborted"}
        and now - latest_event[0] <= RUNNING_ACTIVITY_WINDOW
    ):
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
    if selected_alert is not None:
        observation.alert_timestamp = selected_alert.timestamp
        observation.alert_type = selected_alert.kind
        observation.alert_message = selected_alert.message
        observation.alert_event_key = selected_alert.event_key
    if latest_event:
        observation.latest_event_timestamp = latest_event[0]
        observation.latest_event_type = latest_event[1]
    return observation


def _session_candidates() -> list[tuple[Path, _SessionIdentity]]:
    user_sessions: list[tuple[Path, _SessionIdentity]] = []
    unknown_sessions: list[tuple[Path, _SessionIdentity]] = []
    for path in session_files(SESSIONS_DIR, max_files=MAX_DISCOVERY_SESSION_FILES):
        identity = _session_identity(path)
        if identity.user_initiated is True and len(user_sessions) < MAX_SESSION_FILES:
            user_sessions.append((path, identity))
        elif identity.user_initiated is None and len(unknown_sessions) < MAX_UNKNOWN_SESSION_FILES:
            unknown_sessions.append((path, identity))
    return user_sessions + unknown_sessions


def _session_identity(path: Path) -> _SessionIdentity:
    cached = _SESSION_IDENTITY_CACHE.get(path)
    if cached is not None:
        return cached

    identity = _SessionIdentity(session_id="", user_initiated=None)
    try:
        with path.open("rb") as handle:
            raw_line = handle.readline(SESSION_META_BYTES)
    except OSError:
        return identity
    if not raw_line.endswith(b"\n"):
        return identity
    try:
        event = json.loads(raw_line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return identity
    if not isinstance(event, dict) or event.get("type") != "session_meta":
        return identity
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return identity

    session_id = str(payload.get("id") or "")
    if not session_id or not path.name.endswith(f"{session_id}.jsonl"):
        return identity
    source = payload.get("source")
    if isinstance(source, dict) and "subagent" in source:
        user_initiated = False
    elif source is None:
        user_initiated = None
    else:
        user_initiated = True

    identity = _SessionIdentity(session_id=session_id, user_initiated=user_initiated)
    if len(_SESSION_IDENTITY_CACHE) >= 512:
        _SESSION_IDENTITY_CACHE.clear()
    _SESSION_IDENTITY_CACHE[path] = identity
    return identity


def _observe_session(
    session_path: Path,
    identity: _SessionIdentity,
    now: datetime,
) -> _SessionObservation:
    observation = _SessionObservation(identity=identity)
    for event in _tail_json_events(session_path):
        timestamp = _parse_timestamp(event.get("timestamp"))
        if timestamp is None:
            continue

        top_type = str(event.get("type") or "")
        payload = event.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        payload_type = str(payload.get("type") or top_type)
        candidate_type = payload_type or top_type
        message = str(payload.get("message") or "")
        turn_id = str(payload.get("turn_id") or "")

        if top_type == "turn_context":
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and cwd:
                observation.latest_cwd = (timestamp, Path(cwd))

        if candidate_type and (
            observation.latest_event is None or timestamp > observation.latest_event[0]
        ):
            observation.latest_event = (timestamp, candidate_type, message)

        normalized = candidate_type.lower()
        if normalized == "task_started":
            observation.latest_lifecycle = (timestamp, normalized)
            if turn_id:
                observation.active_turns.add(turn_id)
        elif normalized in {"task_complete", "turn_aborted"}:
            observation.latest_lifecycle = (timestamp, normalized)
            if turn_id:
                observation.active_turns.discard(turn_id)

        quota = _quota_from_payload(payload, timestamp, now)
        if quota is not None and (
            observation.quota is None or timestamp > observation.quota[0]
        ):
            observation.quota = (timestamp, quota)

        alert = _alert_from_payload(candidate_type, payload)
        if alert is None:
            continue
        alert_status, alert_kind, alert_message = alert
        event_key = f"{identity.session_id}:{turn_id or timestamp.isoformat()}:{alert_kind}"
        candidate = _AlertCandidate(
            timestamp=timestamp,
            status=alert_status,
            kind=alert_kind,
            message=alert_message,
            event_key=event_key,
        )
        if alert_status == AgentStatus.DONE:
            observation.completion = _newer_alert(observation.completion, candidate)
        elif alert_status == AgentStatus.APPROVAL:
            observation.approval = _newer_alert(observation.approval, candidate)
        elif alert_status == AgentStatus.ERROR:
            observation.error = _newer_alert(observation.error, candidate)
    return observation


def _session_is_running(observation: _SessionObservation, now: datetime) -> bool:
    if observation.active_turns:
        return True
    latest_event = observation.latest_event
    latest_lifecycle = observation.latest_lifecycle
    if latest_lifecycle is not None and latest_lifecycle[1] in {"task_complete", "turn_aborted"}:
        if latest_event is None or latest_lifecycle[0] >= latest_event[0]:
            return False
    return bool(latest_event and now - latest_event[0] <= RUNNING_ACTIVITY_WINDOW)


def _alert_is_current(
    observation: _SessionObservation,
    alert: _AlertCandidate | None,
    now: datetime,
) -> bool:
    return bool(
        alert is not None
        and now - alert.timestamp <= ALERT_ACTIVITY_WINDOW
        and (
            observation.latest_event is None
            or alert.timestamp >= observation.latest_event[0]
        )
    )


def _completion_is_confirmed(
    observation: _SessionObservation,
    completion: _AlertCandidate,
) -> bool:
    if observation.latest_event is None or completion.timestamp >= observation.latest_event[0]:
        return True
    return bool(
        observation.latest_lifecycle is not None
        and observation.latest_lifecycle[1] == "task_started"
        and observation.latest_lifecycle[0] > completion.timestamp
    )


def _newer_alert(
    current: _AlertCandidate | None,
    candidate: _AlertCandidate | None,
) -> _AlertCandidate | None:
    if candidate is None:
        return current
    if current is None or candidate.timestamp > current.timestamp:
        return candidate
    return current


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
