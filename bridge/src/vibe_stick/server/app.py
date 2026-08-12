from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from vibe_stick import __version__ as BRIDGE_VERSION
from vibe_stick.audio.recorder import RecordingController
from vibe_stick.claude.usage import fetch_usage as fetch_claude_usage
from vibe_stick.claude.usage import to_quota_snapshot as claude_usage_to_quota
from vibe_stick.codex.quota import QuotaSnapshot, load_quota, save_quota
from vibe_stick.codex.rate_limits import fetch_account_quota as fetch_codex_account_quota
from vibe_stick.config.paths import CLAUDE_QUOTA_PATH, QUOTA_PATH, RECORDING_PATH, STATE_PATH, ensure_app_support
from vibe_stick.desktop.hud import hide_hud
from vibe_stick.protocol.state import (
    AlertState,
    AlertType,
    VibeStickState,
    AgentStatus,
    CodexState,
    ProviderState,
    default_state,
    event_id,
    now_time_text,
    state_from_dict,
)
from vibe_stick.providers.base import ProviderObservation
from vibe_stick.providers.claude import observe_claude
from vibe_stick.providers.codex import observe_codex
from vibe_stick.protocol.device_config import DeviceConfigurationStore
from vibe_stick.protocol.discovery import BonjourAdvertiser, BridgeIdentityStore
from vibe_stick.protocol.pairing import PairedDeviceRegistry

MANUAL_STATUS_SECONDS = 60
BRIDGE_NAME = "vibestick-bridge"
DEFAULT_MAX_RECORDING_AUDIO_BYTES = 2_000_000
DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS = 300
MIN_CLAUDE_USAGE_INTERVAL_SECONDS = 30
QUOTA_STALE_AFTER_SECONDS = 30 * 60
PLACEHOLDER_BRIDGE_TOKENS = {
    "change-this-shared-token",
    "paste-generated-token-here",
    "changeme",
    "change-me",
}


class BridgeStateStore:
    def __init__(
        self,
        *,
        device_registry: PairedDeviceRegistry | None = None,
        device_configuration: DeviceConfigurationStore | None = None,
        bridge_identity: BridgeIdentityStore | None = None,
    ) -> None:
        ensure_app_support()
        self._lock = threading.RLock()
        self._project_root = _resolve_project_root()
        self._manual_status_until = 0.0
        self._state = self._load_state()
        self._last_active_provider = self._state.active_provider or "codex"
        self._claude_quota = load_quota(CLAUDE_QUOTA_PATH)
        if not _has_quota(self._claude_quota):
            self._claude_quota = _claude_quota_from_state(self._state)
        self._claude_usage_last_attempt = 0.0
        self._claude_usage_last_success = 0.0
        self.device_registry = device_registry or PairedDeviceRegistry()
        self.device_configuration = device_configuration or DeviceConfigurationStore()
        self.bridge_id = (bridge_identity or BridgeIdentityStore()).bridge_id()
        self._device_runtime: dict[str, dict[str, Any]] = {}
        self._codex_quota = load_quota(QUOTA_PATH)
        self._codex_quota_refreshing = False
        self._state.codex.quota_5h_remaining = self._codex_quota.quota_5h_remaining
        self._state.codex.quota_7d_remaining = self._codex_quota.quota_7d_remaining
        self._state.codex.quota_updated_at = self._codex_quota.quota_updated_at
        self._state.codex.quota_stale = self._codex_quota.quota_stale
        self.recording = RecordingController(RECORDING_PATH)
        hide_hud()

    def note_device_request(self, device_id: str, headers: Any) -> None:
        with self._lock:
            runtime = self._device_runtime.setdefault(device_id, {})
            runtime["last_seen_epoch"] = time.time()
            runtime["firmware_name"] = str(headers.get("X-Vibe-Stick-Firmware-Name", ""))[:32]
            runtime["firmware_version"] = str(headers.get("X-Vibe-Stick-Firmware-Version", ""))[:32]

    def acknowledge_configuration(self, device_id: str, revision: int) -> dict[str, Any]:
        current_revision = int(self.device_configuration.current().get("revision", 0))
        accepted = revision == current_revision
        with self._lock:
            runtime = self._device_runtime.setdefault(device_id, {})
            runtime["last_seen_epoch"] = time.time()
            if accepted:
                runtime["last_config_revision"] = revision
        return {
            "accepted": accepted,
            "current_revision": current_revision,
        }

    def devices_status(self) -> dict[str, Any]:
        now = time.time()
        current_revision = int(self.device_configuration.current().get("revision", 0))
        with self._lock:
            runtime = {device_id: dict(value) for device_id, value in self._device_runtime.items()}
        devices = []
        for paired in self.device_registry.devices():
            live = runtime.get(paired.device_id, {})
            last_seen = live.get("last_seen_epoch")
            online = isinstance(last_seen, (int, float)) and now - float(last_seen) <= 10
            devices.append(
                {
                    "device_id": paired.device_id,
                    "name": paired.name,
                    "paired_at": paired.paired_at,
                    "firmware_version": live.get("firmware_version") or paired.firmware_version,
                    "online": online,
                    "last_seen_epoch": last_seen,
                    "last_config_revision": live.get("last_config_revision"),
                    "target_config_revision": current_revision,
                    "revoked": paired.revoked,
                }
            )
        return {
            "bridge_id": self.bridge_id,
            "protocol_version": 2,
            "devices": devices,
        }

    def get_state(self) -> VibeStickState:
        with self._lock:
            self._refresh_providers_locked()
            self._state.time = now_time_text()
            self._save_state_locked()
            return self._state

    def update_from_event(self, event: dict[str, Any]) -> VibeStickState:
        with self._lock:
            event_name = str(event.get("event") or "")
            requested_status = event.get("codex_status") or event.get("status")
            if requested_status:
                self._set_codex_status(str(requested_status), str(event.get("message") or ""))
                self._manual_status_until = time.monotonic() + MANUAL_STATUS_SECONDS
            elif event_name == "button_double":
                self.refresh_quota_locked()
            elif event_name == "button_short":
                self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")
            self._save_state_locked()
            return self._state

    def refresh_quota(self) -> VibeStickState:
        with self._lock:
            self.refresh_quota_locked()
            self._save_state_locked()
            return self._state

    def refresh_quota_locked(self) -> None:
        if self._state.active_provider == "claude":
            self._refresh_claude_usage_locked(force=True)
            self._state.provider = _provider_state_from_observation(
                self._apply_claude_quota(observe_claude(self._project_root))
            )
            return

        codex_observation = observe_codex(self._project_root)
        self._schedule_codex_quota_refresh_locked()
        self._apply_codex_quota(codex_observation)
        self._state.codex = _codex_state_from_observation(codex_observation)
        if self._state.active_provider == "codex":
            self._state.provider = _provider_state_from_observation(codex_observation)

    def start_recording(self, request: dict[str, Any] | None = None) -> dict[str, Any]:
        session = self.recording.start(request)
        with self._lock:
            self._state.alert = AlertState(
                event_id="",
                type=AlertType.NONE,
                message="",
            )
            self._save_state_locked()
        return {"recording": session.to_jsonable(), "state": self.get_state().to_jsonable()}

    def stop_recording(self, request: dict[str, Any] | None = None) -> dict[str, Any]:
        session = self.recording.stop(request)
        return {"recording": session.to_jsonable(), "state": self.get_state().to_jsonable()}

    def upload_recording_audio(
        self,
        pcm: bytes,
        *,
        session_id: str = "",
        sample_rate: int = 16000,
        channels: int = 1,
        bits_per_sample: int = 16,
    ) -> dict[str, Any]:
        session = self.recording.attach_pcm(
            pcm,
            session_id=session_id,
            sample_rate=sample_rate,
            channels=channels,
            bits_per_sample=bits_per_sample,
        )
        return {"recording": session.to_jsonable(), "state": self.get_state().to_jsonable()}

    def _refresh_providers_locked(self) -> None:
        codex_observation = observe_codex(self._project_root)
        claude_observation = observe_claude(self._project_root)
        self._apply_codex_quota(codex_observation)

        if time.monotonic() < self._manual_status_until:
            _apply_manual_codex_state(codex_observation, self._state)

        active_provider = _select_active_provider(
            _configured_provider(),
            self._last_active_provider,
            codex_observation,
            claude_observation,
        )
        self._last_active_provider = active_provider
        self._state.active_provider = active_provider

        if active_provider == "claude":
            self._refresh_claude_usage_locked(force=False)
            active_observation = self._apply_claude_quota(claude_observation)
        else:
            active_observation = codex_observation

        self._state.codex = _codex_state_from_observation(codex_observation)
        self._state.provider = _provider_state_from_observation(active_observation)
        self._apply_alert_from_observation(
            _select_alert_observation(active_observation, codex_observation, claude_observation)
        )

    def _apply_alert_from_observation(self, observation: ProviderObservation) -> None:
        try:
            alert_type = AlertType(observation.alert_type)
        except ValueError:
            alert_type = AlertType.NONE
        if alert_type in {AlertType.DONE, AlertType.APPROVAL, AlertType.ERROR} and observation.alert_event_id:
            self._state.alert = AlertState(
                event_id=observation.alert_event_id,
                type=alert_type,
                message=observation.alert_message,
            )
        else:
            self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")

    def _apply_codex_quota(self, observation: ProviderObservation) -> None:
        refreshed = self._current_codex_quota()
        if observation.quota_5h_remaining is not None or observation.quota_7d_remaining is not None:
            candidate = QuotaSnapshot(
                quota_5h_remaining=observation.quota_5h_remaining,
                quota_7d_remaining=observation.quota_7d_remaining,
                quota_updated_at=observation.quota_updated_at,
                quota_stale=observation.quota_stale,
                quota_source=observation.quota_source,
                quota_observed_at_epoch=observation.quota_observed_at_epoch,
            )
            if not _has_quota(refreshed) or _quota_is_newer(candidate, refreshed):
                refreshed = candidate
                self._codex_quota = refreshed
                save_quota(QUOTA_PATH, refreshed)

        observation.quota_5h_remaining = refreshed.quota_5h_remaining
        observation.quota_7d_remaining = refreshed.quota_7d_remaining
        observation.quota_updated_at = refreshed.quota_updated_at
        observation.quota_stale = refreshed.quota_stale
        observation.quota_source = refreshed.quota_source
        observation.quota_observed_at_epoch = refreshed.quota_observed_at_epoch

    def _schedule_codex_quota_refresh_locked(self) -> None:
        if self._codex_quota_refreshing:
            return
        self._codex_quota_refreshing = True
        threading.Thread(
            target=self._refresh_codex_quota_worker,
            name="vibestick-codex-quota",
            daemon=True,
        ).start()

    def _refresh_codex_quota_worker(self) -> None:
        refreshed = fetch_codex_account_quota()
        with self._lock:
            self._codex_quota_refreshing = False
            if refreshed is None:
                stale = self._current_codex_quota()
                if stale.quota_stale and stale != self._codex_quota:
                    self._codex_quota = stale
                    save_quota(QUOTA_PATH, stale)
                return
            if not _has_quota(self._codex_quota) or _quota_is_newer(refreshed, self._codex_quota):
                self._codex_quota = refreshed
                save_quota(QUOTA_PATH, refreshed)
            self._apply_codex_quota_to_state_locked(self._codex_quota)
            self._save_state_locked()

    def _current_codex_quota(self) -> QuotaSnapshot:
        quota = self._codex_quota
        if (
            _has_quota(quota)
            and quota.quota_observed_at_epoch > 0
            and time.time() - quota.quota_observed_at_epoch > QUOTA_STALE_AFTER_SECONDS
        ):
            return _stale_quota(quota)
        return quota

    def _apply_codex_quota_to_state_locked(self, quota: QuotaSnapshot) -> None:
        self._state.codex.quota_5h_remaining = quota.quota_5h_remaining
        self._state.codex.quota_7d_remaining = quota.quota_7d_remaining
        self._state.codex.quota_updated_at = quota.quota_updated_at
        self._state.codex.quota_stale = quota.quota_stale
        if self._state.active_provider == "codex":
            self._state.provider.quota_5h_remaining = quota.quota_5h_remaining
            self._state.provider.quota_7d_remaining = quota.quota_7d_remaining
            self._state.provider.quota_updated_at = quota.quota_updated_at
            self._state.provider.quota_stale = quota.quota_stale

    def _refresh_claude_usage_locked(self, *, force: bool) -> None:
        now = time.monotonic()
        interval = _claude_usage_interval_seconds()
        if not force and now - self._claude_usage_last_attempt < interval:
            return
        self._claude_usage_last_attempt = now

        usage = fetch_claude_usage()
        if usage is None:
            if _has_quota(self._claude_quota):
                self._claude_quota = _stale_quota(self._claude_quota)
                save_quota(CLAUDE_QUOTA_PATH, self._claude_quota)
            else:
                self._claude_quota = QuotaSnapshot()
            return

        self._claude_quota = claude_usage_to_quota(usage)
        save_quota(CLAUDE_QUOTA_PATH, self._claude_quota)
        self._claude_usage_last_success = now

    def _apply_claude_quota(self, observation: ProviderObservation) -> ProviderObservation:
        quota = self._current_claude_quota()
        observation.quota_5h_remaining = quota.quota_5h_remaining
        observation.quota_7d_remaining = quota.quota_7d_remaining
        observation.quota_updated_at = quota.quota_updated_at
        observation.quota_stale = quota.quota_stale
        return observation

    def _current_claude_quota(self) -> QuotaSnapshot:
        if (
            self._claude_quota.quota_5h_remaining is None
            and self._claude_quota.quota_7d_remaining is None
        ):
            return self._claude_quota
        if self._claude_usage_last_success and time.monotonic() - self._claude_usage_last_success > 30 * 60:
            return _stale_quota(self._claude_quota)
        return self._claude_quota

    def _set_codex_status(self, raw_status: str, message: str) -> None:
        try:
            status = AgentStatus(raw_status.upper())
        except ValueError:
            status = AgentStatus.UNKNOWN
        self._state.codex.status = status
        if self._state.active_provider == "codex":
            self._state.provider.status = status
        if status == AgentStatus.DONE:
            self._state.alert = AlertState(event_id("done"), AlertType.DONE, message or "Codex task completed")
        elif status == AgentStatus.APPROVAL:
            self._state.alert = AlertState(
                event_id("approval"),
                AlertType.APPROVAL,
                message or "Codex is waiting for approval",
            )
        elif status == AgentStatus.ERROR:
            self._state.alert = AlertState(event_id("error"), AlertType.ERROR, message or "Codex needs attention")
        else:
            self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")

    def _load_state(self) -> VibeStickState:
        try:
            return state_from_dict(json.loads(STATE_PATH.read_text()))
        except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
            return default_state()

    def _save_state_locked(self) -> None:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(json.dumps(self._state.to_jsonable(), indent=2) + "\n")


def make_handler(store: BridgeStateStore) -> type[BaseHTTPRequestHandler]:
    class VibeStickHandler(BaseHTTPRequestHandler):
        server_version = "VibeStick/0.1"

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/state":
                if not self._is_loopback_request() and not self._is_runtime_authorized():
                    self._send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
                    return
                self._send_json(_with_bridge_metadata(store.get_state().to_jsonable()))
            elif parsed.path == "/health":
                self._send_json(
                    {
                        "ok": True,
                        "bridge_name": BRIDGE_NAME,
                        "bridge_version": BRIDGE_VERSION,
                        "protocol_version": 2,
                        "bridge_id": store.bridge_id,
                    }
                )
            elif parsed.path == "/v1/devices":
                if not self._is_loopback_request():
                    self._send_error(HTTPStatus.FORBIDDEN, "Local management endpoint")
                    return
                self._send_json(store.devices_status())
            elif parsed.path == "/v1/device/config":
                device_id = self._paired_device_id()
                if device_id is None:
                    self._send_error(HTTPStatus.UNAUTHORIZED, "Paired device required")
                    return
                store.note_device_request(device_id, self.headers)
                self._send_json(store.device_configuration.current())
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Unknown endpoint")

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path in _protected_paths() and not self._is_runtime_authorized():
                self._send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
                return

            if parsed.path == "/event":
                body = self._read_json_body()
                self._send_json(store.update_from_event(body).to_jsonable())
            elif parsed.path == "/quota/refresh":
                state = store.refresh_quota()
                self._send_json({"refreshed": True, "state": state.to_jsonable()})
            elif parsed.path == "/recording/start":
                body = self._read_json_body()
                self._send_json(store.start_recording(body))
            elif parsed.path == "/recording/audio":
                query = parse_qs(parsed.query)
                content_length = self._content_length()
                max_audio_bytes = _max_recording_audio_bytes()
                if content_length > max_audio_bytes:
                    self._send_error(
                        HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                        f"Recording audio exceeds {max_audio_bytes} bytes",
                    )
                    return
                pcm = self._read_raw_body(content_length)
                self._send_json(
                    store.upload_recording_audio(
                        pcm,
                        session_id=_first(query, "session_id"),
                        sample_rate=_int_header(self.headers.get("X-Vibe-Stick-Sample-Rate"), 16000),
                        channels=_int_header(self.headers.get("X-Vibe-Stick-Channels"), 1),
                        bits_per_sample=_int_header(self.headers.get("X-Vibe-Stick-Bits-Per-Sample"), 16),
                    )
                )
            elif parsed.path == "/recording/stop":
                body = self._read_json_body()
                self._send_json(store.stop_recording(body))
            elif parsed.path == "/v1/device/config/ack":
                device_id = self._paired_device_id()
                if device_id is None:
                    self._send_error(HTTPStatus.UNAUTHORIZED, "Paired device required")
                    return
                body = self._read_json_body()
                revision = body.get("revision")
                if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
                    self._send_error(HTTPStatus.BAD_REQUEST, "Invalid revision")
                    return
                store.note_device_request(device_id, self.headers)
                self._send_json(store.acknowledge_configuration(device_id, revision))
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Unknown endpoint")

        def log_message(self, fmt: str, *args: object) -> None:
            firmware_name = self.headers.get("X-Vibe-Stick-Firmware-Name", "-")
            firmware_version = self.headers.get("X-Vibe-Stick-Firmware-Version", "-")
            firmware_transport = self.headers.get("X-Vibe-Stick-Firmware-Transport", "-")
            print(
                f"{self.address_string()} - {fmt % args} "
                f"firmware={firmware_name}/{firmware_version} transport={firmware_transport}",
                flush=True,
            )

        def _read_json_body(self) -> dict[str, Any]:
            length = self._content_length()
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                data = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                return {}
            return data if isinstance(data, dict) else {}

        def _read_raw_body(self, length: int) -> bytes:
            if length <= 0:
                return b""
            return self.rfile.read(length)

        def _content_length(self) -> int:
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
            except ValueError:
                return 0
            return max(0, length)

        def _is_runtime_authorized(self) -> bool:
            paired_device_id = self._paired_device_id()
            if paired_device_id is not None:
                store.note_device_request(paired_device_id, self.headers)
                return True
            expected = _bridge_token()
            if not expected:
                return self._is_loopback_request()
            supplied = self.headers.get("X-Vibe-Stick-Token", "")
            return hmac.compare_digest(supplied, expected)

        def _paired_device_id(self) -> str | None:
            device_id = self.headers.get("X-Vibe-Stick-Device-ID", "").strip()
            supplied = self.headers.get("X-Vibe-Stick-Token", "")
            if store.device_registry.authenticate(device_id, supplied):
                return device_id
            return None

        def _is_loopback_request(self) -> bool:
            try:
                return ipaddress.ip_address(self.client_address[0]).is_loopback
            except ValueError:
                return False

        def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                # StickS3 may time out or reset after sending a request but
                # before reading the response. The request has already been
                # handled, so a disconnected response socket is not a Bridge
                # failure and should not emit a server traceback.
                return

        def _send_error(self, status: HTTPStatus, message: str) -> None:
            self._send_json({"error": message}, status=status)

    return VibeStickHandler


def run_server(host: str, port: int) -> None:
    store = BridgeStateStore()
    _enforce_bind_security(host, store.device_registry)
    server = ThreadingHTTPServer((host, port), make_handler(store))
    advertiser = BonjourAdvertiser(bridge_id=store.bridge_id, port=port)
    advertiser.start()
    if not _bridge_token() and not store.device_registry.devices():
        print(
            "WARNING: VIBE_STICK_BRIDGE_TOKEN is not set; POST endpoints are unauthenticated on loopback only.",
            flush=True,
        )
    print(f"VibeStick Bridge listening on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    finally:
        advertiser.stop()
        server.server_close()


def _protected_paths() -> set[str]:
    return {
        "/event",
        "/quota/refresh",
        "/recording/start",
        "/recording/audio",
        "/recording/stop",
    }


def _bridge_token() -> str:
    token = os.environ.get("VIBE_STICK_BRIDGE_TOKEN", "").strip()
    if token.lower() in PLACEHOLDER_BRIDGE_TOKENS:
        return ""
    return token


def _enforce_bind_security(host: str, registry: PairedDeviceRegistry | None = None) -> None:
    paired_devices = (registry or PairedDeviceRegistry()).devices()
    if _host_requires_token(host) and not _bridge_token() and not paired_devices:
        raise SystemExit(
            "Refusing to bind VibeStick Bridge outside loopback without "
            "a paired device or VIBE_STICK_BRIDGE_TOKEN. Pair over USB, set a strong legacy token, "
            "or use --host 127.0.0.1."
        )


def _host_requires_token(host: str) -> bool:
    normalized = host.strip().strip("[]").lower()
    if normalized == "localhost":
        return False
    if not normalized:
        return True
    try:
        address = ipaddress.ip_address(normalized)
    except ValueError:
        return True
    return not address.is_loopback


def _max_recording_audio_bytes() -> int:
    raw = os.environ.get("VIBE_STICK_MAX_RECORDING_AUDIO_BYTES", "").strip()
    if not raw:
        return DEFAULT_MAX_RECORDING_AUDIO_BYTES
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_MAX_RECORDING_AUDIO_BYTES
    return max(256_000, min(8_000_000, value))


def _resolve_project_root() -> Path:
    configured = os.environ.get("VIBE_STICK_PROJECT_ROOT", "").strip()
    root = Path(configured).expanduser() if configured else Path.cwd()
    if root.name in {"bridge", "firmware", "app", "scripts"} and (root.parent / "README.md").exists():
        root = root.parent
    return root.resolve()


def _stale_quota(existing: QuotaSnapshot) -> QuotaSnapshot:
    return QuotaSnapshot(
        quota_5h_remaining=existing.quota_5h_remaining,
        quota_7d_remaining=existing.quota_7d_remaining,
        quota_updated_at=existing.quota_updated_at,
        quota_stale=True,
        quota_source=existing.quota_source,
        quota_observed_at_epoch=existing.quota_observed_at_epoch,
    )


def _has_quota(snapshot: QuotaSnapshot) -> bool:
    return snapshot.quota_5h_remaining is not None or snapshot.quota_7d_remaining is not None


def _quota_is_newer(candidate: QuotaSnapshot, current: QuotaSnapshot) -> bool:
    if candidate.quota_observed_at_epoch != current.quota_observed_at_epoch:
        return candidate.quota_observed_at_epoch > current.quota_observed_at_epoch
    return candidate.quota_source == "codex-app-server" and current.quota_source != "codex-app-server"


def _claude_quota_from_state(state: VibeStickState) -> QuotaSnapshot:
    provider = state.provider
    if provider.id != "claude":
        return QuotaSnapshot()
    snapshot = QuotaSnapshot(
        quota_5h_remaining=provider.quota_5h_remaining,
        quota_7d_remaining=provider.quota_7d_remaining,
        quota_updated_at=provider.quota_updated_at,
        quota_stale=True,
    )
    return snapshot if _has_quota(snapshot) else QuotaSnapshot()


def _first(query: dict[str, list[str]], key: str) -> str:
    values = query.get(key) or []
    return values[0] if values else ""


def _with_bridge_metadata(payload: dict[str, Any]) -> dict[str, Any]:
    payload["bridge_name"] = BRIDGE_NAME
    payload["bridge_version"] = BRIDGE_VERSION
    return payload


def _configured_provider() -> str:
    value = os.environ.get("VIBE_STICK_PROVIDER", "auto").strip().lower()
    return value if value in {"codex", "claude", "auto"} else "auto"


def _select_active_provider(
    configured: str,
    last_active: str,
    codex_observation: ProviderObservation,
    claude_observation: ProviderObservation,
) -> str:
    if configured in {"codex", "claude"}:
        return configured

    if codex_observation.online and not claude_observation.online:
        return "codex"
    if claude_observation.online and not codex_observation.online:
        return "claude"
    if codex_observation.online and claude_observation.online:
        codex_time = codex_observation.latest_event_timestamp
        claude_time = claude_observation.latest_event_timestamp
        if codex_time is not None and claude_time is not None:
            return "claude" if claude_time > codex_time else "codex"
        if claude_time is not None:
            return "claude"
        if codex_time is not None:
            return "codex"
        return last_active if last_active in {"codex", "claude"} else "codex"

    return last_active if last_active in {"codex", "claude"} else "codex"


def _select_alert_observation(
    active_observation: ProviderObservation,
    *observations: ProviderObservation,
) -> ProviderObservation:
    if _observation_has_alert(active_observation):
        return active_observation
    for observation in observations:
        if observation is active_observation:
            continue
        if _observation_has_alert(observation):
            return observation
    return active_observation


def _observation_has_alert(observation: ProviderObservation) -> bool:
    try:
        alert_type = AlertType(observation.alert_type)
    except ValueError:
        return False
    return alert_type in {AlertType.DONE, AlertType.APPROVAL, AlertType.ERROR} and bool(observation.alert_event_id)


def _claude_usage_interval_seconds() -> int:
    try:
        value = int(os.environ.get("VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS", ""))
    except ValueError:
        value = DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS
    if value <= 0:
        value = DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS
    return max(MIN_CLAUDE_USAGE_INTERVAL_SECONDS, value)


def _codex_state_from_observation(observation: ProviderObservation) -> CodexState:
    return CodexState(
        status=observation.status,
        project=observation.project,
        quota_5h_remaining=observation.quota_5h_remaining,
        quota_7d_remaining=observation.quota_7d_remaining,
        quota_updated_at=observation.quota_updated_at,
        quota_stale=observation.quota_stale,
    )


def _provider_state_from_observation(observation: ProviderObservation) -> ProviderState:
    return ProviderState(
        id=observation.provider_id,
        display_name=observation.display_name,
        implemented=True,
        status=observation.status,
        project=observation.project,
        quota_5h_remaining=observation.quota_5h_remaining,
        quota_7d_remaining=observation.quota_7d_remaining,
        quota_updated_at=observation.quota_updated_at,
        quota_stale=observation.quota_stale,
    )


def _apply_manual_codex_state(observation: ProviderObservation, state: VibeStickState) -> None:
    observation.status = state.codex.status
    observation.alert_type = state.alert.type.value
    observation.alert_message = state.alert.message
    observation.alert_event_id = state.alert.event_id


def _int_header(raw: str | None, default: int) -> int:
    try:
        value = int(raw or "")
    except ValueError:
        return default
    return value if value > 0 else default


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run VibeStick Bridge.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    run_server(args.host, args.port)
