from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass
class QuotaSnapshot:
    quota_5h_remaining: int | None = None
    quota_7d_remaining: int | None = None
    quota_updated_at: str = ""
    quota_stale: bool = False
    quota_source: str = ""
    quota_observed_at_epoch: float = 0.0

    def to_jsonable(self) -> dict[str, Any]:
        return asdict(self)


def load_quota(path: Path) -> QuotaSnapshot:
    try:
        data = json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return QuotaSnapshot()
    return QuotaSnapshot(
        quota_5h_remaining=_percent_or_none(data.get("quota_5h_remaining")),
        quota_7d_remaining=_percent_or_none(data.get("quota_7d_remaining")),
        quota_updated_at=str(data.get("quota_updated_at") or ""),
        quota_stale=bool(data.get("quota_stale", False)),
        quota_source=str(data.get("quota_source") or "")[:64],
        quota_observed_at_epoch=_epoch_or_zero(data.get("quota_observed_at_epoch")),
    )


def save_quota(path: Path, snapshot: QuotaSnapshot) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot.to_jsonable(), indent=2) + "\n")


def _percent_or_none(value: object) -> int | None:
    if value is None:
        return None
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return max(0, min(100, number))


def _epoch_or_zero(value: object) -> float:
    if isinstance(value, bool):
        return 0.0
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, number)
