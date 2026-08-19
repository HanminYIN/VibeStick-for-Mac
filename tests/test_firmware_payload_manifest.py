from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "firmware-payload-manifest.py"
SPEC = importlib.util.spec_from_file_location("firmware_payload_manifest", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manifest)


class FirmwarePayloadManifestTests(unittest.TestCase):
    def make_payload(self, root: Path) -> None:
        for index, name in enumerate(manifest.EXPECTED_FILES, start=1):
            path = root / name
            path.write_bytes(bytes([index]) * (128 + index))
            os.chmod(path, 0o644)
        manifest.generate(root, "0.2.0-m4.4a", "a" * 40, "b" * 64)

    def test_round_trip_pins_geometry_offsets_and_nvs_preservation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_payload(root)
            manifest.verify(root)
            document = json.loads((root / manifest.MANIFEST_NAME).read_text(encoding="utf-8"))

        self.assertEqual(document["target"], "esp32s3")
        self.assertEqual(document["flash"]["size"], 8 * 1024 * 1024)
        self.assertEqual(document["preservedRanges"], manifest.PRESERVED_RANGES)
        self.assertEqual(
            {entry["path"]: entry["offset"] for entry in document["files"]},
            manifest.EXPECTED_FILES,
        )

    def test_rejects_tampering_extra_files_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_payload(root)
            (root / "vibe-stick.bin").write_bytes(b"changed")
            with self.assertRaises(SystemExit):
                manifest.verify(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_payload(root)
            (root / "extra.bin").write_bytes(b"extra")
            with self.assertRaises(SystemExit):
                manifest.verify(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_payload(root)
            (root / "bootloader.bin").unlink()
            (root / "bootloader.bin").symlink_to(root / "vibe-stick.bin")
            with self.assertRaises(SystemExit):
                manifest.verify(root)

    def test_rejects_changed_offsets_modes_and_preserved_ranges(self) -> None:
        for mutation in ("offset", "mode", "preserved"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_payload(root)
                path = root / manifest.MANIFEST_NAME
                document = json.loads(path.read_text(encoding="utf-8"))
                if mutation == "offset":
                    document["files"][0]["offset"] = 0x9000
                elif mutation == "mode":
                    document["files"][0]["mode"] = 0o600
                else:
                    document["preservedRanges"][0]["start"] = 0xA000
                path.write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaises(SystemExit):
                    manifest.verify(root)

    def test_verify_source_binds_payload_to_secret_free_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            payload = root / "payload"
            payload.mkdir()
            for directory_name in manifest.SOURCE_DIRECTORIES:
                (source / directory_name).mkdir(parents=True, exist_ok=True)
            for file_name in manifest.SOURCE_FILES:
                (source / file_name).write_text(file_name, encoding="utf-8")
            (source / "include" / "vibe_stick_secrets.h").write_text(
                '#define VIBE_STICK_WIFI_PASSWORD "excluded"\n',
                encoding="utf-8",
            )
            digest = manifest.source_digest(source)
            for index, name in enumerate(manifest.EXPECTED_FILES, start=1):
                path = payload / name
                path.write_bytes(bytes([index]) * (128 + index))
                os.chmod(path, 0o644)
            manifest.generate(payload, "0.2.0-m4.4a", "a" * 40, digest)

            manifest.verify_source(payload, source)
            (source / "src" / "changed.c").write_text("changed", encoding="utf-8")
            with self.assertRaises(SystemExit):
                manifest.verify_source(payload, source)

    def test_local_secret_scan_never_needs_to_print_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "payload"
            root.mkdir()
            self.make_payload(root)
            header = Path(directory) / "local-secrets.h"
            header.write_text(
                '#define VIBE_STICK_WIFI_SSID "private-network"\n'
                '#define VIBE_STICK_WIFI_PASSWORD "private-password"\n',
                encoding="utf-8",
            )
            manifest.assert_no_secrets(root, header)
            (root / "vibe-stick.bin").write_bytes(b"prefix-private-password-suffix")
            with self.assertRaises(SystemExit) as raised:
                manifest.assert_no_secrets(root, header)
            self.assertNotIn("private-password", str(raised.exception))

    def test_build_layout_requires_exact_idf_flash_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (
                "bootloader/bootloader.bin",
                "partition_table/partition-table.bin",
                "vibe_stick_sticks3.bin",
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"image")
            layout = {
                "flash_settings": {"flash_mode": "dio", "flash_size": "8MB", "flash_freq": "80m"},
                "flash_files": {
                    "0x0": "bootloader/bootloader.bin",
                    "0x8000": "partition_table/partition-table.bin",
                    "0x10000": "vibe_stick_sticks3.bin",
                },
                "extra_esptool_args": {"chip": "esp32s3"},
            }
            (root / "flasher_args.json").write_text(json.dumps(layout), encoding="utf-8")
            manifest.assert_build_layout(root)
            layout["flash_files"]["0x9000"] = layout["flash_files"].pop("0x8000")
            (root / "flasher_args.json").write_text(json.dumps(layout), encoding="utf-8")
            with self.assertRaises(SystemExit):
                manifest.assert_build_layout(root)


if __name__ == "__main__":
    unittest.main()
