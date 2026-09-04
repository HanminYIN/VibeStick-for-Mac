from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIGURATION_TOOL = ROOT / "scripts" / "release_configuration.py"
ARTIFACT_TOOL = ROOT / "scripts" / "release_artifact.py"
RELEASE_CONFIG = ROOT / "release" / "release-config-v1.json"
DMG_BUILDER = ROOT / "scripts" / "build-macos-dmg.sh"
APP_BUILDER = ROOT / "scripts" / "build-macos-app.sh"


def load_script_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


release_configuration = load_script_module("release_configuration", CONFIGURATION_TOOL)
release_artifact = load_script_module("release_artifact", ARTIFACT_TOOL)


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.values = json.loads(RELEASE_CONFIG.read_text(encoding="utf-8"))

    def write_config(self, root: Path, values: dict | None = None) -> Path:
        destination = root / "release-config-v1.json"
        destination.write_text(
            json.dumps(values or self.values, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return destination

    def test_tracked_configuration_is_valid_and_exports_every_release_identity(self) -> None:
        configuration = release_configuration.ReleaseConfiguration.load(RELEASE_CONFIG)

        self.assertEqual(configuration.product_version, "0.2.0")
        self.assertEqual(configuration.build_version, "11")
        self.assertEqual(configuration.channel, "rc.2")
        self.assertEqual(configuration.runtime_payload_version, "0.2.0-rc.2-native")
        self.assertEqual(configuration.firmware_payload_version, "0.2.0-m4.4a")
        assignments = configuration.shell_assignments(RELEASE_CONFIG)
        for variable in (
            "VIBESTICK_PRODUCT_VERSION",
            "VIBESTICK_BUILD_VERSION",
            "VIBESTICK_RELEASE_CHANNEL",
            "VIBESTICK_RELEASE_LABEL",
            "VIBESTICK_RUNTIME_PAYLOAD_VERSION",
            "VIBESTICK_FIRMWARE_PAYLOAD_VERSION",
            "VIBESTICK_DMG_FILENAME",
            "VIBESTICK_DMG_VOLUME_NAME",
        ):
            self.assertIn(f"{variable}=", assignments)

    def test_missing_or_unknown_fields_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = dict(self.values)
            missing.pop("buildVersion")
            with self.assertRaisesRegex(
                release_configuration.ReleaseConfigurationError, "missing=.*buildVersion"
            ):
                release_configuration.ReleaseConfiguration.load(self.write_config(root, missing))

            unknown = dict(self.values)
            unknown["buildVerson"] = "11"
            with self.assertRaisesRegex(
                release_configuration.ReleaseConfigurationError, "unknown=.*buildVerson"
            ):
                release_configuration.ReleaseConfiguration.load(self.write_config(root, unknown))

    def test_inconsistent_release_identity_fails_before_building(self) -> None:
        inconsistent_values = (
            ("releaseLabel", "RC 3", "releaseLabel"),
            ("dmgFilename", "VibeStick-for-Mac-0.2.0-rc.3.dmg", "dmgFilename"),
            ("dmgVolumeName", "VibeStick for Mac 0.2.0 RC 3", "dmgVolumeName"),
            ("firmwarePayloadPath", "release/firmware/sticks3/wrong", "firmwarePayloadPath"),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for key, value, expected_error in inconsistent_values:
                values = dict(self.values)
                values[key] = value
                with self.subTest(key=key), self.assertRaisesRegex(
                    release_configuration.ReleaseConfigurationError, expected_error
                ):
                    release_configuration.ReleaseConfiguration.load(
                        self.write_config(root, values)
                    )

    def test_missing_firmware_input_fails_before_app_builder_runs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            values = dict(self.values)
            values["firmwarePayloadVersion"] = "0.2.0-missing"
            values["firmwarePayloadPath"] = "release/firmware/sticks3/0.2.0-missing"
            configuration = self.write_config(root, values)
            marker = root / "xcodebuild-used"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_xcodebuild = fake_bin / "xcodebuild"
            fake_xcodebuild.write_text(
                f"#!/bin/sh\nprintf used > {marker!s}\n",
                encoding="utf-8",
            )
            fake_xcodebuild.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "VIBESTICK_RELEASE_CONFIG": str(configuration),
                }
            )

            completed = subprocess.run(
                ["sh", str(APP_BUILDER)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("firmwarePayloadPath", completed.stderr)
            self.assertFalse(marker.exists())

    def test_invalid_firmware_override_fails_before_app_builder_runs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "xcodebuild-used"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_xcodebuild = fake_bin / "xcodebuild"
            fake_xcodebuild.write_text(
                f"#!/bin/sh\nprintf used > {marker!s}\n",
                encoding="utf-8",
            )
            fake_xcodebuild.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "VIBESTICK_RELEASE_CONFIG": str(RELEASE_CONFIG),
                    "VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD": str(
                        root / "missing-override"
                    ),
                }
            )

            completed = subprocess.run(
                ["sh", str(APP_BUILDER)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD", completed.stderr)
            self.assertFalse(marker.exists())

    def test_bridge_runtime_identity_comes_from_bundle_metadata(self) -> None:
        sources = (
            ROOT / "app/macos/VibeStickBridge/NativeBridgeRuntimeStore.swift",
            ROOT / "app/macos/VibeStickBridge/NativeBridgeCodexQuota.swift",
            ROOT / "app/macos/VibeStickBridge/main.swift",
        )
        combined = "\n".join(path.read_text(encoding="utf-8") for path in sources)
        self.assertIn('forInfoDictionaryKey: "CFBundleShortVersionString"', combined)
        self.assertGreaterEqual(combined.count("NativeBridgeReleaseIdentity.version"), 3)
        self.assertNotIn('"version": "0.2.0"', combined)
        self.assertNotIn("VibeStick Bridge 0.2.0 listening", combined)

    def test_all_shipped_user_agents_come_from_bundle_metadata(self) -> None:
        sources = (
            ROOT / "app/macos/VibeStickApp/Core/TestableLogic.swift",
            ROOT / "app/macos/VibeStickApp/Core/M3CInfrastructure.swift",
            ROOT / "app/macos/VibeStickApp/Core/M4FlashingTool.swift",
            ROOT / "app/macos/VibeStickBridge/NativeBridgeRuntimeStore.swift",
            ROOT / "app/macos/VibeStickBridge/NativeBridgeVoiceAdapters.swift",
        )
        combined = "\n".join(path.read_text(encoding="utf-8") for path in sources)
        self.assertIn('forInfoDictionaryKey: "CFBundleShortVersionString"', combined)
        self.assertGreaterEqual(combined.count("AppReleaseIdentity.userAgent"), 2)
        self.assertIn("NativeBridgeReleaseIdentity.version", combined)
        self.assertNotIn("VibeStick-for-Mac/0.2", combined)
        self.assertNotIn("VibeStick-for-Mac-M4-3", combined)
        self.assertNotIn("VibeStick/0.2 macOS", combined)

    def test_stable_configuration_uses_release_neutral_artifact_names(self) -> None:
        values = dict(self.values)
        values.update(
            {
                "channel": "stable",
                "releaseLabel": "Stable",
                "appReleaseSummary": "这是 VibeStick for Mac 0.2.0 Stable 的最终发布构建。",
                "dmgFilename": "VibeStick-for-Mac-0.2.0.dmg",
                "dmgVolumeName": "VibeStick for Mac 0.2.0",
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            configuration = release_configuration.ReleaseConfiguration.load(
                self.write_config(Path(directory), values)
            )

        self.assertEqual(configuration.channel, "stable")
        self.assertEqual(configuration.dmg_filename, "VibeStick-for-Mac-0.2.0.dmg")
        self.assertEqual(configuration.dmg_volume_name, "VibeStick for Mac 0.2.0")


class ReleaseArtifactTests(unittest.TestCase):
    def make_app(self, root: Path, configuration: Path = RELEASE_CONFIG) -> Path:
        app = root / "VibeStick for Mac.app"
        resources = app / "Contents" / "Resources"
        executable = app / "Contents" / "MacOS" / "VibeStick for Mac"
        resources.mkdir(parents=True)
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"test-app")
        executable.chmod(0o755)
        shutil.copyfile(configuration, resources / "ReleaseConfiguration-v1.json")
        return app

    def make_hdiutil(self, root: Path) -> Path:
        fake_hdiutil = root / "hdiutil"
        fake_hdiutil.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, shutil, sys\n"
            "command = sys.argv[1]\n"
            "if command == 'create':\n"
            "    source = pathlib.Path(sys.argv[sys.argv.index('-srcfolder') + 1])\n"
            "    image = pathlib.Path(sys.argv[-1])\n"
            "    contents = pathlib.Path(str(image) + '.contents')\n"
            "    shutil.copytree(source, contents, symlinks=True)\n"
            "    if os.environ.get('VIBESTICK_TEST_MUTATE_PACKAGED_APP') == '1':\n"
            "        binary = contents / 'VibeStick for Mac.app/Contents/MacOS/VibeStick for Mac'\n"
            "        binary.write_bytes(b'packaged-mutation')\n"
            "    image.write_bytes(b'dmg')\n"
            "elif command == 'verify':\n"
            "    if not pathlib.Path(sys.argv[-1]).is_file(): raise SystemExit(1)\n"
            "elif command == 'attach':\n"
            "    image = pathlib.Path(sys.argv[-1])\n"
            "    mount = pathlib.Path(sys.argv[sys.argv.index('-mountpoint') + 1])\n"
            "    for child in pathlib.Path(str(image) + '.contents').iterdir():\n"
            "        destination = mount / child.name\n"
            "        if child.is_symlink(): destination.symlink_to(os.readlink(child))\n"
            "        elif child.is_dir(): shutil.copytree(child, destination, symlinks=True)\n"
            "        else: shutil.copy2(child, destination)\n"
            "elif command == 'detach':\n"
            "    mount = pathlib.Path(sys.argv[-1])\n"
            "    for child in mount.iterdir():\n"
            "        if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)\n"
            "        else: child.unlink()\n",
            encoding="utf-8",
        )
        fake_hdiutil.chmod(0o755)
        return fake_hdiutil

    def test_sealed_app_round_trips_and_detects_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            receipt = root / "app-receipt.json"

            release_artifact.seal(app, RELEASE_CONFIG, receipt)
            release_artifact.verify(app, RELEASE_CONFIG, receipt)
            (app / "Contents" / "MacOS" / "VibeStick for Mac").write_bytes(b"changed")

            with self.assertRaisesRegex(
                release_artifact.ReleaseArtifactError, "changed after"
            ):
                release_artifact.verify(app, RELEASE_CONFIG, receipt)

    def test_receipt_is_bound_to_the_exact_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            receipt = root / "app-receipt.json"
            release_artifact.seal(app, RELEASE_CONFIG, receipt)
            changed_config = root / "changed-config.json"
            values = json.loads(RELEASE_CONFIG.read_text(encoding="utf-8"))
            values["appReleaseTitle"] = "另一个标题"
            changed_config.write_text(
                json.dumps(values, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )

            with self.assertRaisesRegex(
                release_artifact.ReleaseArtifactError, "configuration"
            ):
                release_artifact.verify(app, changed_config, receipt)

    def test_dmg_builder_consumes_a_sealed_app_without_rebuilding(self) -> None:
        self.assertNotIn("build-macos-app.sh", DMG_BUILDER.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            receipt = root / "VibeStick for Mac.app.build-receipt-v1.json"
            release_artifact.seal(app, RELEASE_CONFIG, receipt)
            fake_ditto = root / "ditto"
            fake_hdiutil = self.make_hdiutil(root)
            fake_ditto.write_text(
                "#!/usr/bin/env python3\n"
                "import shutil, sys\n"
                "shutil.copytree(sys.argv[-2], sys.argv[-1], symlinks=True)\n",
                encoding="utf-8",
            )
            fake_ditto.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "VIBESTICK_BUILD_ROOT": str(root),
                    "VIBESTICK_DITTO_PATH": str(fake_ditto),
                    "VIBESTICK_HDIUTIL_PATH": str(fake_hdiutil),
                    "VIBESTICK_RELEASE_CONFIG": str(RELEASE_CONFIG),
                }
            )

            completed = subprocess.run(
                ["sh", str(DMG_BUILDER)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue((root / "VibeStick-for-Mac-0.2.0-rc.2.dmg").is_file())

    def test_dmg_builder_rejects_adapter_mutation_inside_the_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            receipt = root / "VibeStick for Mac.app.build-receipt-v1.json"
            release_artifact.seal(app, RELEASE_CONFIG, receipt)
            fake_ditto = root / "ditto"
            fake_ditto.write_text(
                "#!/usr/bin/env python3\n"
                "import shutil, sys\n"
                "shutil.copytree(sys.argv[-2], sys.argv[-1], symlinks=True)\n",
                encoding="utf-8",
            )
            fake_ditto.chmod(0o755)
            fake_hdiutil = self.make_hdiutil(root)
            environment = os.environ.copy()
            environment.update(
                {
                    "VIBESTICK_BUILD_ROOT": str(root),
                    "VIBESTICK_DITTO_PATH": str(fake_ditto),
                    "VIBESTICK_HDIUTIL_PATH": str(fake_hdiutil),
                    "VIBESTICK_RELEASE_CONFIG": str(RELEASE_CONFIG),
                    "VIBESTICK_TEST_MUTATE_PACKAGED_APP": "1",
                }
            )

            completed = subprocess.run(
                ["sh", str(DMG_BUILDER)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("changed after", completed.stderr)

    def test_dmg_builder_rejects_app_mutation_before_adapter_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            receipt = root / "VibeStick for Mac.app.build-receipt-v1.json"
            release_artifact.seal(app, RELEASE_CONFIG, receipt)
            (app / "Contents" / "MacOS" / "VibeStick for Mac").write_bytes(b"mutated")
            marker = root / "adapter-used"
            fake_adapter = root / "adapter"
            fake_adapter.write_text(
                f"#!/bin/sh\nprintf used > {marker!s}\n",
                encoding="utf-8",
            )
            fake_adapter.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "VIBESTICK_BUILD_ROOT": str(root),
                    "VIBESTICK_DITTO_PATH": str(fake_adapter),
                    "VIBESTICK_HDIUTIL_PATH": str(fake_adapter),
                    "VIBESTICK_RELEASE_CONFIG": str(RELEASE_CONFIG),
                }
            )

            completed = subprocess.run(
                ["sh", str(DMG_BUILDER)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("changed after", completed.stderr)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
