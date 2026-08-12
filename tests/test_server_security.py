import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick.server import app
from vibe_stick.protocol.pairing import PairedDeviceRegistry


class ServerSecurityTests(unittest.TestCase):
    def test_loopback_host_does_not_require_token(self) -> None:
        self.assertFalse(app._host_requires_token("127.0.0.1"))
        self.assertFalse(app._host_requires_token("localhost"))
        self.assertFalse(app._host_requires_token("::1"))

    def test_non_loopback_host_requires_token(self) -> None:
        self.assertTrue(app._host_requires_token("0.0.0.0"))
        self.assertTrue(app._host_requires_token(""))
        self.assertTrue(app._host_requires_token("192.168.1.10"))

    def test_placeholder_token_is_treated_as_missing(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": "change-this-shared-token"}):
            self.assertEqual(app._bridge_token(), "")

    def test_real_token_is_used(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": "abc123-secret"}):
            self.assertEqual(app._bridge_token(), "abc123-secret")

    def test_paired_registry_allows_non_loopback_without_legacy_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry_path = Path(directory) / "devices-v1.json"
            registry_path.write_text(
                '{"schema_version":1,"devices":[{'
                '"device_id":"vs-14c19fd56070",'
                '"token_salt":"0123456789abcdef0123456789abcdef",'
                '"token_hash":"' + ("0" * 64) + '",'
                '"paired_at":"","firmware_version":"","revoked":false}]}',
                encoding="utf-8",
            )
            with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": ""}):
                app._enforce_bind_security("0.0.0.0", PairedDeviceRegistry(registry_path))

    def test_non_loopback_without_pairing_or_token_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = PairedDeviceRegistry(Path(directory) / "missing.json")
            with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": ""}):
                with self.assertRaises(SystemExit):
                    app._enforce_bind_security("0.0.0.0", registry)


if __name__ == "__main__":
    unittest.main()
