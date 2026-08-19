from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any


class AgentStatus(StrEnum):
    IDLE = "IDLE"
    RUNNING = "RUNNING"
    DONE = "DONE"
    APPROVAL = "APPROVAL"
    ERROR = "ERROR"
    OFFLINE = "OFFLINE"
    UNKNOWN = "UNKNOWN"


class AlertType(StrEnum):
    NONE = "NONE"
    DONE = "DONE"
    APPROVAL = "APPROVAL"
    ERROR = "ERROR"


@dataclass
class QuotaWindow:
    id: str
    label: str
    remaining_percent: int | None
    updated_at: str = ""
    stale: bool = False


@dataclass
class CodexState:
    status: AgentStatus = AgentStatus.IDLE
    project: str = "vibestick"
    quota_5h_remaining: int | None = None
    quota_7d_remaining: int | None = None
    quota_updated_at: str = ""
    quota_stale: bool = False
    quota_windows: list[QuotaWindow] = field(default_factory=list)


@dataclass
class ProviderState:
    id: str = "codex"
    display_name: str = "Codex"
    implemented: bool = True
    status: AgentStatus = AgentStatus.IDLE
    project: str = "vibestick"
    quota_5h_remaining: int | None = None
    quota_7d_remaining: int | None = None
    quota_updated_at: str = ""
    quota_stale: bool = False
    quota_windows: list[QuotaWindow] = field(default_factory=list)


@dataclass
class AlertState:
    event_id: str = ""
    type: AlertType = AlertType.NONE
    message: str = ""


@dataclass
class VibeStickState:
    time: str
    wifi: bool
    ble: bool
    battery: int | None
    active_provider: str
    provider: ProviderState
    codex: CodexState
    alert: AlertState

    def to_jsonable(self) -> dict[str, Any]:
        data = asdict(self)
        data["battery"] = None
        data["provider"]["status"] = self.provider.status.value
        data["codex"]["status"] = self.codex.status.value
        data["alert"]["type"] = self.alert.type.value
        data["provider"]["quota_windows"] = _quota_windows_json(
            self.provider.quota_windows,
            quota_5h=self.provider.quota_5h_remaining,
            quota_7d=self.provider.quota_7d_remaining,
            updated_at=self.provider.quota_updated_at,
            stale=self.provider.quota_stale,
        )
        data["codex"]["quota_windows"] = _quota_windows_json(
            self.codex.quota_windows,
            quota_5h=self.codex.quota_5h_remaining,
            quota_7d=self.codex.quota_7d_remaining,
            updated_at=self.codex.quota_updated_at,
            stale=self.codex.quota_stale,
        )
        return data


def now_time_text() -> str:
    return datetime.now().strftime("%H:%M")


def event_id(prefix: str) -> str:
    return f"evt_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{prefix}"


def state_from_dict(data: dict[str, Any]) -> VibeStickState:
    provider_data = data.get("provider", {})
    codex_data = data.get("codex", {})
    codex_data = codex_data if isinstance(codex_data, dict) else {}
    alert_data = data.get("alert", {})
    alert_data = alert_data if isinstance(alert_data, dict) else {}
    provider_state = _provider_state_from_dict(provider_data if isinstance(provider_data, dict) else {}, codex_data)
    return VibeStickState(
        time=now_time_text(),
        wifi=bool(data.get("wifi", True)),
        ble=bool(data.get("ble", False)),
        battery=data.get("battery"),
        active_provider=str(data.get("active_provider") or provider_state.id),
        provider=provider_state,
        codex=CodexState(
            status=AgentStatus(codex_data.get("status", AgentStatus.IDLE.value)),
            project=str(codex_data.get("project") or "vibestick"),
            quota_5h_remaining=codex_data.get("quota_5h_remaining"),
            quota_7d_remaining=codex_data.get("quota_7d_remaining"),
            quota_updated_at=str(codex_data.get("quota_updated_at") or ""),
            quota_stale=bool(codex_data.get("quota_stale", False)),
            quota_windows=_quota_windows_from_dict(codex_data.get("quota_windows")),
        ),
        alert=AlertState(
            event_id=str(alert_data.get("event_id") or ""),
            type=AlertType(alert_data.get("type", AlertType.NONE.value)),
            message=str(alert_data.get("message") or ""),
        ),
    )


def _provider_state_from_dict(provider_data: dict[str, Any], codex_data: dict[str, Any]) -> ProviderState:
    if provider_data:
        return ProviderState(
            id=str(provider_data.get("id") or "codex"),
            display_name=str(provider_data.get("display_name") or "Codex"),
            implemented=bool(provider_data.get("implemented", True)),
            status=AgentStatus(provider_data.get("status", AgentStatus.IDLE.value)),
            project=str(provider_data.get("project") or "vibestick"),
            quota_5h_remaining=provider_data.get("quota_5h_remaining"),
            quota_7d_remaining=provider_data.get("quota_7d_remaining"),
            quota_updated_at=str(provider_data.get("quota_updated_at") or ""),
            quota_stale=bool(provider_data.get("quota_stale", False)),
            quota_windows=_quota_windows_from_dict(provider_data.get("quota_windows")),
        )

    return ProviderState(
        id="codex",
        display_name="Codex",
        implemented=True,
        status=AgentStatus(codex_data.get("status", AgentStatus.IDLE.value)),
        project=str(codex_data.get("project") or "vibestick"),
        quota_5h_remaining=codex_data.get("quota_5h_remaining"),
        quota_7d_remaining=codex_data.get("quota_7d_remaining"),
        quota_updated_at=str(codex_data.get("quota_updated_at") or ""),
        quota_stale=bool(codex_data.get("quota_stale", False)),
        quota_windows=_quota_windows_from_dict(codex_data.get("quota_windows")),
    )


def _quota_windows_from_dict(value: Any) -> list[QuotaWindow]:
    if not isinstance(value, list):
        return []
    windows: list[QuotaWindow] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        window_id = str(item.get("id") or "").strip()
        label = str(item.get("label") or "").strip()
        if not window_id or not label:
            continue
        remaining = item.get("remaining_percent")
        if not isinstance(remaining, (int, float)):
            remaining = None
        elif isinstance(remaining, bool):
            remaining = None
        else:
            remaining = max(0, min(100, int(round(remaining))))
        windows.append(
            QuotaWindow(
                id=window_id[:32],
                label=label[:16],
                remaining_percent=remaining,
                updated_at=str(item.get("updated_at") or "")[:32],
                stale=bool(item.get("stale", False)),
            )
        )
    return windows[:4]


def _quota_windows_json(
    windows: list[QuotaWindow],
    *,
    quota_5h: int | None,
    quota_7d: int | None,
    updated_at: str,
    stale: bool,
) -> list[dict[str, Any]]:
    normalized = list(windows)
    if not windows:
        if quota_5h is not None:
            normalized.append(QuotaWindow("5h", "5H", quota_5h, updated_at, stale))
        if quota_7d is not None:
            normalized.append(QuotaWindow("7d", "7D", quota_7d, updated_at, stale))
    return [asdict(window) for window in normalized]


def default_state() -> VibeStickState:
    codex = CodexState(
        status=AgentStatus.RUNNING,
        project="vibestick",
        quota_5h_remaining=None,
        quota_7d_remaining=None,
        quota_updated_at="",
        quota_stale=False,
    )
    return VibeStickState(
        time=now_time_text(),
        wifi=True,
        ble=False,
        battery=None,
        active_provider="codex",
        provider=ProviderState(
            id="codex",
            display_name="Codex",
            implemented=True,
            status=codex.status,
            project=codex.project,
            quota_5h_remaining=codex.quota_5h_remaining,
            quota_7d_remaining=codex.quota_7d_remaining,
            quota_updated_at=codex.quota_updated_at,
            quota_stale=codex.quota_stale,
        ),
        codex=codex,
        alert=AlertState(event_id="", type=AlertType.NONE, message=""),
    )
