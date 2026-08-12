from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vibe_stick.protocol.pairing import PairedDeviceRegistry, pairing_token_hash, valid_device_id


class PairingProtocolTests(unittest.TestCase):
    def test_registry_authenticates_only_matching_device_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "devices-v1.json"
            token = "a" * 43
            salt = "0123456789abcdef0123456789abcdef"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "devices": [
                            {
                                "device_id": "vs-14c19fd56070",
                                "name": "StickS3",
                                "token_salt": salt,
                                "token_hash": pairing_token_hash(salt, token),
                                "paired_at": "2026-08-12T00:00:00Z",
                                "firmware_version": "0.2.0-dev",
                                "revoked": False,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            registry = PairedDeviceRegistry(path)

            self.assertTrue(registry.authenticate("vs-14c19fd56070", token))
            self.assertFalse(registry.authenticate("vs-14c19fd56070", "b" * 43))
            self.assertFalse(registry.authenticate("vs-other-device", token))

    def test_revoked_or_malformed_entries_never_authenticate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "devices-v1.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "devices": [
                            {
                                "device_id": "vs-14c19fd56070",
                                "token_salt": "not-hex",
                                "token_hash": "0" * 64,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            self.assertFalse(PairedDeviceRegistry(path).authenticate("vs-14c19fd56070", "a" * 43))

    def test_device_id_validation_is_narrow(self) -> None:
        self.assertTrue(valid_device_id("vs-14c19fd56070"))
        self.assertFalse(valid_device_id("../../secrets"))
        self.assertFalse(valid_device_id("short"))


if __name__ == "__main__":
    unittest.main()
