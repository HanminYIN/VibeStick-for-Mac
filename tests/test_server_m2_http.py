from __future__ import annotations

import http.client
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Any
from unittest import mock

from vibe_stick.protocol.pairing import PairedDeviceRegistry, pairing_token_hash
from vibe_stick.server.app import make_handler


class _Configuration:
    def current(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "revision": 3,
            "modules": ["codex", "connection"],
            "default_page": "codex",
            "project": {"visible": True, "name": "M5StickS3"},
            "buttons": {"front_double": "refresh_quota", "side_single": "next_page"},
        }


class _Store:
    bridge_id = "90d71007-7734-44f7-8987-b2980437e6c6"

    def __init__(self, registry: PairedDeviceRegistry) -> None:
        self.device_registry = registry
        self.device_configuration = _Configuration()
        self.seen: list[str] = []
        self.acknowledged: list[tuple[str, int]] = []
        self.confirmed_send_sessions: list[str] = []

    def note_device_request(self, device_id: str, headers: Any) -> None:
        self.seen.append(device_id)

    def acknowledge_configuration(self, device_id: str, revision: int) -> dict[str, Any]:
        self.acknowledged.append((device_id, revision))
        return {"accepted": revision == 3, "current_revision": 3}

    def devices_status(self) -> dict[str, Any]:
        return {
            "bridge_id": self.bridge_id,
            "protocol_version": 2,
            "devices": [{"device_id": "vs-001122334455", "online": False}],
        }

    def confirm_recording_send(self, request: dict[str, Any]) -> dict[str, Any]:
        session_id = str(request.get("session_id") or "")
        self.confirmed_send_sessions.append(session_id)
        return {
            "voice_interaction_version": 2,
            "recording": {
                "session_id": session_id,
                "status": "sent",
                "transcript": "recognized text " * 1000,
                "audio_file": "/private/recording.wav",
            },
            "send_session": {
                "session_id": session_id,
                "phase": "sent",
                "target": {
                    "bundle_id": "com.openai.codex",
                    "process_id": 42,
                    "focus_fingerprint": "a" * 64,
                },
            },
            "confirmation": {
                "accepted": True,
                "reason": "sent",
                "send_session": {"session_id": session_id, "phase": "sent"},
            },
            "state": {"provider": {"project": "M5StickS3"}},
        }


class ServerM2HTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.token = "device-token-abcdefghijklmnopqrstuvwxyz-123456"
        salt = "0123456789abcdef0123456789abcdef"
        registry_path = Path(self.temporary.name) / "devices-v1.json"
        registry_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "devices": [
                        {
                            "device_id": "vs-001122334455",
                            "name": "StickS3",
                            "token_salt": salt,
                            "token_hash": pairing_token_hash(salt, self.token),
                            "paired_at": "2026-08-12T00:00:00Z",
                            "firmware_version": "0.2.0-dev",
                            "revoked": False,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.store = _Store(PairedDeviceRegistry(registry_path))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.store))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        paired: bool = False,
        firmware: bool = False,
    ) -> tuple[int, dict[str, Any]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        headers: dict[str, str] = {}
        raw_body: str | None = None
        if paired:
            headers["X-Vibe-Stick-Device-ID"] = "vs-001122334455"
            headers["X-Vibe-Stick-Token"] = self.token
        if firmware:
            headers["X-Vibe-Stick-Firmware-Name"] = "VibeStick"
        if body is not None:
            raw_body = json.dumps(body)
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body=raw_body, headers=headers)
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        return response.status, payload

    def test_configuration_requires_valid_paired_device(self) -> None:
        unauthorized_status, _ = self.request("GET", "/v1/device/config")
        authorized_status, payload = self.request("GET", "/v1/device/config", paired=True)

        self.assertEqual(unauthorized_status, 401)
        self.assertEqual(authorized_status, 200)
        self.assertEqual(payload["revision"], 3)
        self.assertEqual(self.store.seen, ["vs-001122334455"])

    def test_configuration_ack_is_tied_to_authenticated_device(self) -> None:
        status, payload = self.request(
            "POST",
            "/v1/device/config/ack",
            body={"revision": 3},
            paired=True,
        )

        self.assertEqual(status, 200)
        self.assertTrue(payload["accepted"])
        self.assertEqual(self.store.acknowledged, [("vs-001122334455", 3)])

    def test_loopback_device_status_never_contains_token_material(self) -> None:
        status, payload = self.request("GET", "/v1/devices")
        serialized = json.dumps(payload).lower()

        self.assertEqual(status, 200)
        self.assertNotIn("token", serialized)
        self.assertNotIn("hash", serialized)

    def test_disconnected_client_does_not_emit_a_server_error(self) -> None:
        handler_type = make_handler(self.store)
        handler = object.__new__(handler_type)
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()
        handler.wfile = mock.Mock()
        handler.wfile.write.side_effect = BrokenPipeError()

        handler._send_json({"ok": True})

        handler.send_response.assert_called_once()
        handler.wfile.write.assert_called_once()

    def test_send_confirmation_requires_runtime_authentication(self) -> None:
        unauthorized_status, _ = self.request(
            "POST",
            "/recording/send/confirm",
            body={"session_id": "0123456789abcdef0123456789abcdef"},
        )
        authorized_status, payload = self.request(
            "POST",
            "/recording/send/confirm",
            body={"session_id": "0123456789abcdef0123456789abcdef"},
            paired=True,
        )

        self.assertEqual(unauthorized_status, 401)
        self.assertEqual(authorized_status, 200)
        self.assertEqual(payload["send_session"]["phase"], "sent")
        self.assertEqual(
            self.store.confirmed_send_sessions,
            ["0123456789abcdef0123456789abcdef"],
        )

    def test_firmware_confirmation_response_is_bounded_and_omits_private_detail(self) -> None:
        session_id = "0123456789abcdef0123456789abcdef"
        status, payload = self.request(
            "POST",
            "/recording/send/confirm",
            body={"session_id": session_id},
            paired=True,
            firmware=True,
        )
        serialized = json.dumps(payload, ensure_ascii=False).encode("utf-8")

        self.assertEqual(status, 200)
        self.assertLess(len(serialized), 2048)
        self.assertEqual(
            payload,
            {
                "voice_interaction_version": 2,
                "recording": {"session_id": session_id, "status": "sent"},
                "send_session": {"session_id": session_id, "phase": "sent"},
            },
        )
        self.assertNotIn("recognized text", serialized.decode("utf-8"))

    def test_non_firmware_confirmation_response_retains_desktop_detail(self) -> None:
        status, payload = self.request(
            "POST",
            "/recording/send/confirm",
            body={"session_id": "0123456789abcdef0123456789abcdef"},
            paired=True,
        )

        self.assertEqual(status, 200)
        self.assertIn("transcript", payload["recording"])
        self.assertIn("state", payload)
        self.assertIn("send_session", payload["confirmation"])

    def test_health_advertises_m3b_voice_capability_without_changing_protocol_v2(self) -> None:
        status, payload = self.request("GET", "/health")

        self.assertEqual(status, 200)
        self.assertEqual(payload["protocol_version"], 2)
        self.assertEqual(payload["voice_interaction_version"], 2)


if __name__ == "__main__":
    unittest.main()
