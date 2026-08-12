from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vibe_stick.protocol.device_config import DeviceConfigurationStore, normalize_device_configuration


class DeviceConfigurationTests(unittest.TestCase):
    def test_normalizes_modules_project_and_buttons(self) -> None:
        normalized = normalize_device_configuration(
            {
                "schema_version": 1,
                "revision": 7,
                "modules": ["claude", "unknown", "claude"],
                "default_page": "unknown",
                "project": {"visible": False, "name": "  M5StickS3  "},
                "buttons": {"front_double": "home", "side_single": "none"},
            }
        )

        self.assertEqual(normalized["revision"], 7)
        self.assertEqual(normalized["modules"], ["codex", "claude", "connection"])
        self.assertEqual(normalized["default_page"], "codex")
        self.assertEqual(normalized["project"], {"visible": False, "name": "M5StickS3"})
        self.assertEqual(normalized["buttons"]["front_double"], "home")
        self.assertEqual(normalized["buttons"]["side_single"], "none")

    def test_invalid_or_oversized_file_falls_back_without_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device-config-v1.json"
            path.write_text("{" + "x" * 20_000, encoding="utf-8")
            configuration = DeviceConfigurationStore(path).current()

        self.assertEqual(configuration["schema_version"], 1)
        self.assertEqual(configuration["revision"], 0)
        self.assertEqual(configuration["modules"], ["codex", "connection"])
        serialized = json.dumps(configuration).lower()
        self.assertNotIn("token", serialized)
        self.assertNotIn("password", serialized)
        self.assertNotIn("api_key", serialized)


if __name__ == "__main__":
    unittest.main()
