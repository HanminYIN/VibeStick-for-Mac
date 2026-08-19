from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from vibe_stick.protocol.state import AgentStatus


@dataclass
class ProviderObservation:
    provider_id: str
    display_name: str
    online: bool
    status: AgentStatus
    project: str
    quota_5h_remaining: int | None
    quota_7d_remaining: int | None
    quota_updated_at: str
    quota_stale: bool
    alert_type: str
    alert_message: str
    alert_event_id: str
    latest_event_timestamp: datetime | None = None
    quota_source: str = ""
    quota_observed_at_epoch: float = 0.0


class Provider(Protocol):
    provider_id: str
    display_name: str

    def observe(self) -> ProviderObservation:
        ...
