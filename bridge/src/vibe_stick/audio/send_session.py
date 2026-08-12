from __future__ import annotations

import json
import math
import os
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Callable


DEFAULT_PENDING_SEND_TTL_SECONDS = 30.0
MIN_PENDING_SEND_TTL_SECONDS = 5.0
MAX_PENDING_SEND_TTL_SECONDS = 300.0
FOCUS_FINGERPRINT_LENGTH = 64


class SendSessionPhase(str, Enum):
    IDLE = "idle"
    PENDING = "pending"
    CONFIRMING = "confirming"
    SENT = "sent"
    FAILED = "failed"
    INVALIDATED = "invalidated"
    EXPIRED = "expired"


@dataclass(frozen=True)
class SendTarget:
    bundle_id: str
    process_id: int
    focus_fingerprint: str

    @classmethod
    def normalized(
        cls,
        *,
        bundle_id: str,
        process_id: int,
        focus_fingerprint: str,
    ) -> SendTarget | None:
        normalized_bundle_id = str(bundle_id).strip()[:255]
        normalized_fingerprint = str(focus_fingerprint).strip().lower()
        if not normalized_bundle_id or not all(
            character.isalnum() or character in {"-", "_", "."}
            for character in normalized_bundle_id
        ):
            return None
        if isinstance(process_id, bool) or not isinstance(process_id, int) or process_id <= 0:
            return None
        if len(normalized_fingerprint) != FOCUS_FINGERPRINT_LENGTH or not all(
            character in "0123456789abcdef" for character in normalized_fingerprint
        ):
            return None
        return cls(
            bundle_id=normalized_bundle_id,
            process_id=process_id,
            focus_fingerprint=normalized_fingerprint,
        )


@dataclass(frozen=True)
class SendSessionSnapshot:
    session_id: str
    phase: SendSessionPhase
    target: SendTarget | None
    created_at_epoch: float
    expires_at_epoch: float
    updated_at_epoch: float
    reason: str

    @classmethod
    def idle(cls) -> SendSessionSnapshot:
        return cls(
            session_id="",
            phase=SendSessionPhase.IDLE,
            target=None,
            created_at_epoch=0.0,
            expires_at_epoch=0.0,
            updated_at_epoch=0.0,
            reason="",
        )

    def to_jsonable(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "session_id": self.session_id,
            "phase": self.phase.value,
            "target": asdict(self.target) if self.target is not None else None,
            "created_at_epoch": self.created_at_epoch,
            "expires_at_epoch": self.expires_at_epoch,
            "updated_at_epoch": self.updated_at_epoch,
            "reason": self.reason,
        }


@dataclass(frozen=True)
class SendSessionTransition:
    accepted: bool
    should_press_enter: bool
    reason: str
    snapshot: SendSessionSnapshot

    def to_jsonable(self) -> dict[str, object]:
        return {
            "accepted": self.accepted,
            "should_press_enter": self.should_press_enter,
            "reason": self.reason,
            "send_session": self.snapshot.to_jsonable(),
        }


class PendingSendCoordinator:
    """Fail-closed, at-most-once state for M3-B blue-button confirmation.

    This object never stores transcript text or a window title. The target is
    represented only by a bundle ID, process ID, and a SHA-256 focus fingerprint.
    """

    def __init__(
        self,
        path: Path,
        *,
        clock: Callable[[], float] = time.time,
        ttl_seconds: float = DEFAULT_PENDING_SEND_TTL_SECONDS,
    ) -> None:
        if (
            not isinstance(ttl_seconds, (int, float))
            or isinstance(ttl_seconds, bool)
            or not math.isfinite(float(ttl_seconds))
            or not MIN_PENDING_SEND_TTL_SECONDS <= float(ttl_seconds) <= MAX_PENDING_SEND_TTL_SECONDS
        ):
            raise ValueError("Pending send TTL must be between 5 and 300 seconds")
        self.path = path
        self._clock = clock
        self._ttl_seconds = float(ttl_seconds)
        self._lock = threading.RLock()
        self._snapshot = self._load()
        with self._lock:
            changed = self._recover_or_expire_locked()
            if changed:
                self._save_locked()

    def snapshot(self) -> SendSessionSnapshot:
        with self._lock:
            if self._expire_locked():
                self._save_locked()
            return replace(self._snapshot)

    def arm(self, *, session_id: str, target: SendTarget) -> SendSessionTransition:
        normalized_session_id = _clean_session_id(session_id)
        if not normalized_session_id or SendTarget.normalized(**asdict(target)) != target:
            return self._transition(False, False, "invalid_pending_send_context")

        with self._lock:
            if self._expire_locked():
                self._save_locked()
            if self._snapshot.session_id == normalized_session_id:
                if (
                    self._snapshot.phase == SendSessionPhase.PENDING
                    and self._snapshot.target == target
                ):
                    return self._transition(True, False, "pending_send_already_armed")
                if self._snapshot.phase != SendSessionPhase.IDLE:
                    return self._transition(False, False, "pending_send_session_already_consumed")
            if self._snapshot.phase in {SendSessionPhase.PENDING, SendSessionPhase.CONFIRMING}:
                return self._transition(False, False, "another_pending_send_exists")
            now = self._now()
            self._snapshot = SendSessionSnapshot(
                session_id=normalized_session_id,
                phase=SendSessionPhase.PENDING,
                target=target,
                created_at_epoch=now,
                expires_at_epoch=now + self._ttl_seconds,
                updated_at_epoch=now,
                reason="awaiting_blue_button_confirmation",
            )
            self._save_locked()
            return self._transition(True, False, "pending_send_armed")

    def begin_recording(self, *, session_id: str) -> SendSessionTransition:
        normalized_session_id = _clean_session_id(session_id)
        if not normalized_session_id:
            return self._transition(False, False, "invalid_recording_session")

        with self._lock:
            if self._expire_locked():
                self._save_locked()
            if self._snapshot.phase == SendSessionPhase.CONFIRMING:
                return self._transition(False, False, "confirmation_in_progress")
            if self._snapshot.phase == SendSessionPhase.PENDING:
                self._snapshot = replace(
                    self._snapshot,
                    phase=SendSessionPhase.INVALIDATED,
                    updated_at_epoch=self._now(),
                    reason="invalidated_by_new_recording",
                )
                self._save_locked()
                return self._transition(True, False, "previous_pending_send_invalidated")
            return self._transition(True, False, "recording_may_start")

    def begin_confirmation(
        self,
        *,
        session_id: str,
        current_target: SendTarget,
    ) -> SendSessionTransition:
        normalized_session_id = _clean_session_id(session_id)
        with self._lock:
            if self._expire_locked():
                self._save_locked()
            if not normalized_session_id:
                return self._transition(False, False, "invalid_confirmation_session")
            if self._snapshot.session_id != normalized_session_id:
                return self._transition(False, False, "pending_send_session_mismatch")
            if self._snapshot.phase in {SendSessionPhase.CONFIRMING, SendSessionPhase.SENT}:
                return self._transition(False, False, "confirmation_already_consumed")
            if self._snapshot.phase != SendSessionPhase.PENDING:
                return self._transition(False, False, f"pending_send_{self._snapshot.phase.value}")
            if current_target != self._snapshot.target:
                self._snapshot = replace(
                    self._snapshot,
                    phase=SendSessionPhase.INVALIDATED,
                    updated_at_epoch=self._now(),
                    reason="focused_target_changed",
                )
                self._save_locked()
                return self._transition(False, False, "focused_target_changed")

            self._snapshot = replace(
                self._snapshot,
                phase=SendSessionPhase.CONFIRMING,
                updated_at_epoch=self._now(),
                reason="confirmation_consumed",
            )
            self._save_locked()
            return self._transition(True, True, "press_enter_once")

    def invalidate(self, *, session_id: str, reason: str) -> SendSessionTransition:
        normalized_session_id = _clean_session_id(session_id)
        normalized_reason = _clean_reason(reason)
        with self._lock:
            if not normalized_session_id or self._snapshot.session_id != normalized_session_id:
                return self._transition(False, False, "pending_send_session_mismatch")
            if self._snapshot.phase != SendSessionPhase.PENDING:
                return self._transition(False, False, "pending_send_not_pending")
            self._snapshot = replace(
                self._snapshot,
                phase=SendSessionPhase.INVALIDATED,
                updated_at_epoch=self._now(),
                reason=normalized_reason,
            )
            self._save_locked()
            return self._transition(True, False, normalized_reason)

    def finish_confirmation(
        self,
        *,
        session_id: str,
        success: bool,
    ) -> SendSessionTransition:
        normalized_session_id = _clean_session_id(session_id)
        with self._lock:
            if not normalized_session_id or self._snapshot.session_id != normalized_session_id:
                return self._transition(False, False, "confirmation_session_mismatch")
            if self._snapshot.phase == SendSessionPhase.SENT:
                return self._transition(False, False, "confirmation_already_sent")
            if self._snapshot.phase != SendSessionPhase.CONFIRMING:
                return self._transition(False, False, "confirmation_not_in_progress")

            phase = SendSessionPhase.SENT if success else SendSessionPhase.FAILED
            reason = "sent" if success else "return_key_failed"
            self._snapshot = replace(
                self._snapshot,
                phase=phase,
                updated_at_epoch=self._now(),
                reason=reason,
            )
            self._save_locked()
            return self._transition(True, False, reason)

    def _transition(
        self,
        accepted: bool,
        should_press_enter: bool,
        reason: str,
    ) -> SendSessionTransition:
        return SendSessionTransition(
            accepted=accepted,
            should_press_enter=should_press_enter,
            reason=reason,
            snapshot=replace(self._snapshot),
        )

    def _recover_or_expire_locked(self) -> bool:
        if self._snapshot.phase == SendSessionPhase.CONFIRMING:
            self._snapshot = replace(
                self._snapshot,
                phase=SendSessionPhase.INVALIDATED,
                updated_at_epoch=self._now(),
                reason="bridge_restarted_during_confirmation",
            )
            return True
        return self._expire_locked()

    def _expire_locked(self) -> bool:
        if (
            self._snapshot.phase == SendSessionPhase.PENDING
            and self._snapshot.expires_at_epoch <= self._now()
        ):
            self._snapshot = replace(
                self._snapshot,
                phase=SendSessionPhase.EXPIRED,
                updated_at_epoch=self._now(),
                reason="pending_send_expired",
            )
            return True
        return False

    def _load(self) -> SendSessionSnapshot:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            if payload.get("schema_version") != 1:
                return SendSessionSnapshot.idle()
            phase = SendSessionPhase(str(payload.get("phase") or "idle"))
            if phase == SendSessionPhase.IDLE:
                return SendSessionSnapshot.idle()
            session_id = _clean_session_id(str(payload.get("session_id") or ""))
            target_payload = payload.get("target")
            target = None
            if isinstance(target_payload, dict):
                target = SendTarget.normalized(
                    bundle_id=str(target_payload.get("bundle_id") or ""),
                    process_id=target_payload.get("process_id"),
                    focus_fingerprint=str(target_payload.get("focus_fingerprint") or ""),
                )
            if phase != SendSessionPhase.IDLE and (not session_id or target is None):
                return SendSessionSnapshot.idle()
            return SendSessionSnapshot(
                session_id=session_id,
                phase=phase,
                target=target,
                created_at_epoch=_finite_epoch(payload.get("created_at_epoch")),
                expires_at_epoch=_finite_epoch(payload.get("expires_at_epoch")),
                updated_at_epoch=_finite_epoch(payload.get("updated_at_epoch")),
                reason=str(payload.get("reason") or "")[:96],
            )
        except (FileNotFoundError, json.JSONDecodeError, OSError, TypeError, ValueError):
            return SendSessionSnapshot.idle()

    def _save_locked(self) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            dir=self.path.parent,
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(self._snapshot.to_jsonable(), handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, self.path)
        except Exception:
            try:
                os.close(descriptor)
            except OSError:
                pass
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise

    def _now(self) -> float:
        now = float(self._clock())
        if not math.isfinite(now):
            raise ValueError("Pending send clock returned a non-finite value")
        return now


def _clean_session_id(raw: str) -> str:
    value = str(raw).strip()
    if not 8 <= len(value) <= 64:
        return ""
    if not all(character.isalnum() or character in {"-", "_"} for character in value):
        return ""
    return value


def _finite_epoch(raw: object) -> float:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return 0.0
    value = float(raw)
    return value if math.isfinite(value) and value >= 0 else 0.0


def _clean_reason(raw: str) -> str:
    value = str(raw).strip().lower().replace("-", "_")[:64]
    if not value or not all(character.isalnum() or character == "_" for character in value):
        return "pending_send_invalidated"
    return value
