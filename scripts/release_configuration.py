#!/usr/bin/env python3
"""Validate and expose the single VibeStick release configuration."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any


class ReleaseConfigurationError(ValueError):
    """Raised when a release configuration is unsafe or inconsistent."""


_EXPECTED_KEYS = {
    "appBundleName",
    "appReleaseSummary",
    "appReleaseTitle",
    "buildVersion",
    "channel",
    "dmgFilename",
    "dmgVolumeName",
    "firmwarePayloadPath",
    "firmwarePayloadVersion",
    "productName",
    "productVersion",
    "releaseLabel",
    "runtimePayloadVersion",
    "schemaVersion",
}
_SAFE_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
_SAFE_PAYLOAD_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_SAFE_BUILD = re.compile(r"^[1-9][0-9]*$")
_SAFE_RC_CHANNEL = re.compile(r"^rc\.([1-9][0-9]*)$")


def _required_string(values: dict[str, Any], key: str, maximum: int = 160) -> str:
    value = values.get(key)
    if not isinstance(value, str) or not value or value != value.strip():
        raise ReleaseConfigurationError(f"{key} must be a nonempty trimmed string")
    if len(value) > maximum:
        raise ReleaseConfigurationError(f"{key} exceeds {maximum} characters")
    if any(ord(character) < 0x20 for character in value):
        raise ReleaseConfigurationError(f"{key} contains a control character")
    return value


def _safe_relative_path(value: str, key: str) -> None:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise ReleaseConfigurationError(f"{key} must be a normalized repository-relative path")


def validate_release_inputs(
    configuration: "ReleaseConfiguration",
    repository_root: Path,
    firmware_payload_override: Path | None = None,
) -> None:
    payload_root = repository_root / configuration.firmware_payload_path
    current = repository_root
    for part in PurePosixPath(configuration.firmware_payload_path).parts:
        current /= part
        if current.is_symlink():
            raise ReleaseConfigurationError(
                "firmwarePayloadPath must not traverse symbolic links"
            )
    if not payload_root.is_dir():
        raise ReleaseConfigurationError(
            "firmwarePayloadPath does not identify a tracked payload directory"
        )

    manifest_path = payload_root / "manifest-v1.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ReleaseConfigurationError(
            "firmwarePayloadPath is missing a regular manifest-v1.json"
        )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseConfigurationError(
            f"cannot read firmware payload manifest: {error}"
        ) from error
    if not isinstance(manifest, dict):
        raise ReleaseConfigurationError("firmware payload manifest root must be an object")
    if manifest.get("payloadVersion") != configuration.firmware_payload_version:
        raise ReleaseConfigurationError(
            "firmware payload manifest identity differs from firmwarePayloadVersion"
        )
    if firmware_payload_override is None:
        return
    override_root = firmware_payload_override
    if not override_root.is_absolute():
        override_root = repository_root / override_root
    if override_root.is_symlink() or not override_root.is_dir():
        raise ReleaseConfigurationError(
            "VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD does not identify a real payload directory"
        )
    override_manifest = override_root / "manifest-v1.json"
    if override_manifest.is_symlink() or not override_manifest.is_file():
        raise ReleaseConfigurationError(
            "VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD is missing a regular manifest-v1.json"
        )
    try:
        override_values = json.loads(override_manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseConfigurationError(
            f"cannot read overridden firmware payload manifest: {error}"
        ) from error
    if not isinstance(override_values, dict) or override_values.get(
        "payloadVersion"
    ) != configuration.firmware_payload_version:
        raise ReleaseConfigurationError(
            "VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD identity differs from firmwarePayloadVersion"
        )


@dataclass(frozen=True)
class ReleaseConfiguration:
    schema_version: int
    product_name: str
    product_version: str
    build_version: str
    channel: str
    release_label: str
    app_bundle_name: str
    app_release_title: str
    app_release_summary: str
    runtime_payload_version: str
    firmware_payload_version: str
    firmware_payload_path: str
    dmg_filename: str
    dmg_volume_name: str

    @classmethod
    def load(cls, path: Path) -> "ReleaseConfiguration":
        try:
            raw = path.read_text(encoding="utf-8")
            values = json.loads(raw)
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ReleaseConfigurationError(f"cannot read {path}: {error}") from error
        if not isinstance(values, dict):
            raise ReleaseConfigurationError("configuration root must be an object")

        keys = set(values)
        missing = sorted(_EXPECTED_KEYS - keys)
        unknown = sorted(keys - _EXPECTED_KEYS)
        if missing or unknown:
            raise ReleaseConfigurationError(
                f"configuration keys differ; missing={missing}, unknown={unknown}"
            )
        if values["schemaVersion"] != 1:
            raise ReleaseConfigurationError("schemaVersion must be 1")

        product_name = _required_string(values, "productName")
        if product_name != "VibeStick for Mac":
            raise ReleaseConfigurationError("productName is not the supported product identity")
        product_version = _required_string(values, "productVersion")
        if not _SAFE_VERSION.fullmatch(product_version):
            raise ReleaseConfigurationError("productVersion must be a three-part numeric version")
        build_version = _required_string(values, "buildVersion")
        if not _SAFE_BUILD.fullmatch(build_version):
            raise ReleaseConfigurationError("buildVersion must be a positive integer string")

        channel = _required_string(values, "channel")
        rc_match = _SAFE_RC_CHANNEL.fullmatch(channel)
        if channel not in {"development", "stable"} and rc_match is None:
            raise ReleaseConfigurationError("channel must be development, stable, or rc.N")
        expected_label = (
            f"RC {rc_match.group(1)}"
            if rc_match is not None
            else "Stable" if channel == "stable" else "Development"
        )
        release_label = _required_string(values, "releaseLabel", maximum=32)
        if release_label != expected_label:
            raise ReleaseConfigurationError(
                f"releaseLabel must be {expected_label!r} for channel {channel!r}"
            )

        app_bundle_name = _required_string(values, "appBundleName")
        if app_bundle_name != f"{product_name}.app":
            raise ReleaseConfigurationError("appBundleName must match productName")
        app_release_title = _required_string(values, "appReleaseTitle", maximum=80)
        app_release_summary = _required_string(values, "appReleaseSummary", maximum=600)
        expected_display = f"{product_name} {product_version} {release_label}"
        if expected_display not in app_release_summary:
            raise ReleaseConfigurationError(
                "appReleaseSummary must contain the configured product, version, and release label"
            )

        runtime_payload_version = _required_string(values, "runtimePayloadVersion")
        firmware_payload_version = _required_string(values, "firmwarePayloadVersion")
        for key, value in (
            ("runtimePayloadVersion", runtime_payload_version),
            ("firmwarePayloadVersion", firmware_payload_version),
        ):
            if not _SAFE_PAYLOAD_VERSION.fullmatch(value) or not value.startswith(
                f"{product_version}-"
            ):
                raise ReleaseConfigurationError(
                    f"{key} must be a safe identifier rooted at productVersion"
                )

        firmware_payload_path = _required_string(values, "firmwarePayloadPath")
        _safe_relative_path(firmware_payload_path, "firmwarePayloadPath")
        expected_firmware_path = f"release/firmware/sticks3/{firmware_payload_version}"
        if firmware_payload_path != expected_firmware_path:
            raise ReleaseConfigurationError(
                "firmwarePayloadPath must identify firmwarePayloadVersion under release/firmware/sticks3"
            )

        product_slug = product_name.replace(" ", "-")
        channel_suffix = "" if channel == "stable" else f"-{channel}"
        expected_dmg_filename = f"{product_slug}-{product_version}{channel_suffix}.dmg"
        dmg_filename = _required_string(values, "dmgFilename")
        if dmg_filename != expected_dmg_filename:
            raise ReleaseConfigurationError(
                f"dmgFilename must be {expected_dmg_filename!r}"
            )
        dmg_volume_name = _required_string(values, "dmgVolumeName")
        expected_volume_name = (
            f"{product_name} {product_version}"
            if channel == "stable"
            else f"{product_name} {product_version} {release_label}"
        )
        if dmg_volume_name != expected_volume_name:
            raise ReleaseConfigurationError(
                f"dmgVolumeName must be {expected_volume_name!r}"
            )

        return cls(
            schema_version=1,
            product_name=product_name,
            product_version=product_version,
            build_version=build_version,
            channel=channel,
            release_label=release_label,
            app_bundle_name=app_bundle_name,
            app_release_title=app_release_title,
            app_release_summary=app_release_summary,
            runtime_payload_version=runtime_payload_version,
            firmware_payload_version=firmware_payload_version,
            firmware_payload_path=firmware_payload_path,
            dmg_filename=dmg_filename,
            dmg_volume_name=dmg_volume_name,
        )

    def shell_assignments(self, configuration_path: Path) -> str:
        values = {
            "VIBESTICK_RELEASE_CONFIG_PATH": str(configuration_path.resolve()),
            "VIBESTICK_PRODUCT_NAME": self.product_name,
            "VIBESTICK_PRODUCT_VERSION": self.product_version,
            "VIBESTICK_BUILD_VERSION": self.build_version,
            "VIBESTICK_RELEASE_CHANNEL": self.channel,
            "VIBESTICK_RELEASE_LABEL": self.release_label,
            "VIBESTICK_APP_BUNDLE_NAME": self.app_bundle_name,
            "VIBESTICK_APP_RELEASE_TITLE": self.app_release_title,
            "VIBESTICK_APP_RELEASE_SUMMARY": self.app_release_summary,
            "VIBESTICK_RUNTIME_PAYLOAD_VERSION": self.runtime_payload_version,
            "VIBESTICK_FIRMWARE_PAYLOAD_VERSION": self.firmware_payload_version,
            "VIBESTICK_FIRMWARE_PAYLOAD_PATH": self.firmware_payload_path,
            "VIBESTICK_DMG_FILENAME": self.dmg_filename,
            "VIBESTICK_DMG_VOLUME_NAME": self.dmg_volume_name,
        }
        return "\n".join(f"{key}={shlex.quote(value)}" for key, value in values.items())


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "validate-inputs", "shell"))
    parser.add_argument("configuration", type=Path)
    parser.add_argument("repository_root", nargs="?", type=Path)
    parser.add_argument("firmware_payload_override", nargs="?", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_arguments()
    try:
        configuration = ReleaseConfiguration.load(arguments.configuration)
    except ReleaseConfigurationError as error:
        print(f"release configuration error: {error}", file=sys.stderr)
        return 2
    if arguments.command == "validate-inputs":
        if arguments.repository_root is None:
            print("release configuration error: validate-inputs requires repository_root", file=sys.stderr)
            return 2
        try:
            validate_release_inputs(
                configuration,
                arguments.repository_root,
                arguments.firmware_payload_override,
            )
        except ReleaseConfigurationError as error:
            print(f"release configuration error: {error}", file=sys.stderr)
            return 2
    elif arguments.command == "shell":
        print(configuration.shell_assignments(arguments.configuration))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
