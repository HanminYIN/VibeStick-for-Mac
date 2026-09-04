#!/usr/bin/env python3
"""Seal and verify the exact App consumed by the release packager."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterator

from release_configuration import ReleaseConfiguration, ReleaseConfigurationError


class ReleaseArtifactError(ValueError):
    """Raised when an App or its build receipt is unsafe or inconsistent."""


_RECEIPT_KEYS = {
    "appBundleName",
    "artifactKind",
    "artifactTreeSHA256",
    "buildVersion",
    "channel",
    "configurationSHA256",
    "productVersion",
    "schemaVersion",
}


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _tree_entries(root: Path) -> Iterator[tuple[str, str, int, str]]:
    if root.is_symlink() or not root.is_dir():
        raise ReleaseArtifactError("App bundle must be a real directory")
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directory_names.sort()
        file_names.sort()
        traversable: list[str] = []
        for name in directory_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if path.is_symlink():
                yield ("symlink", relative, mode, os.readlink(path))
            else:
                yield ("directory", relative, mode, "")
                traversable.append(name)
        directory_names[:] = traversable
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if path.is_symlink():
                yield ("symlink", relative, mode, os.readlink(path))
            elif path.is_file():
                yield ("file", relative, mode, f"{metadata.st_size}:{_sha256_file(path)}")
            else:
                raise ReleaseArtifactError(f"unsupported App entry: {relative}")


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for entry in _tree_entries(root):
        for value in entry:
            encoded = str(value).encode("utf-8")
            digest.update(len(encoded).to_bytes(8, "big"))
            digest.update(encoded)
    return digest.hexdigest()


def _configuration_sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ReleaseArtifactError("release configuration must be a regular file")
    return _sha256_file(path)


def _verify_embedded_configuration(app: Path, configuration_path: Path) -> None:
    embedded = app / "Contents" / "Resources" / "ReleaseConfiguration-v1.json"
    if embedded.is_symlink() or not embedded.is_file():
        raise ReleaseArtifactError("App is missing its embedded release configuration")
    if embedded.read_bytes() != configuration_path.read_bytes():
        raise ReleaseArtifactError("embedded release configuration differs from the build input")


def seal(app: Path, configuration_path: Path, receipt_path: Path) -> dict[str, Any]:
    configuration = ReleaseConfiguration.load(configuration_path)
    if app.name != configuration.app_bundle_name:
        raise ReleaseArtifactError("App bundle name differs from the release configuration")
    _verify_embedded_configuration(app, configuration_path)
    receipt = {
        "appBundleName": configuration.app_bundle_name,
        "artifactKind": "macos-app-bundle",
        "artifactTreeSHA256": tree_sha256(app),
        "buildVersion": configuration.build_version,
        "channel": configuration.channel,
        "configurationSHA256": _configuration_sha256(configuration_path),
        "productVersion": configuration.product_version,
        "schemaVersion": 1,
    }
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(receipt, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=receipt_path.parent, delete=False) as stream:
            temporary_name = stream.name
            stream.write(payload)
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, receipt_path)
    finally:
        if temporary_name is not None and os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return receipt


def verify(app: Path, configuration_path: Path, receipt_path: Path) -> dict[str, Any]:
    configuration = ReleaseConfiguration.load(configuration_path)
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise ReleaseArtifactError("App build receipt is missing or is not a regular file")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseArtifactError(f"cannot read App build receipt: {error}") from error
    if not isinstance(receipt, dict) or set(receipt) != _RECEIPT_KEYS:
        raise ReleaseArtifactError("App build receipt has an unexpected schema")
    expected_identity = {
        "appBundleName": configuration.app_bundle_name,
        "artifactKind": "macos-app-bundle",
        "buildVersion": configuration.build_version,
        "channel": configuration.channel,
        "configurationSHA256": _configuration_sha256(configuration_path),
        "productVersion": configuration.product_version,
        "schemaVersion": 1,
    }
    for key, expected in expected_identity.items():
        if receipt.get(key) != expected:
            raise ReleaseArtifactError(f"App build receipt {key} differs from the release configuration")
    if app.name != configuration.app_bundle_name:
        raise ReleaseArtifactError("App bundle name differs from the release configuration")
    _verify_embedded_configuration(app, configuration_path)
    observed_digest = tree_sha256(app)
    if receipt.get("artifactTreeSHA256") != observed_digest:
        raise ReleaseArtifactError("App changed after its build receipt was sealed")
    return receipt


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("seal", "verify"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("app", type=Path)
        command_parser.add_argument("configuration", type=Path)
        command_parser.add_argument("receipt", type=Path)
    digest_parser = subparsers.add_parser("digest")
    digest_parser.add_argument("app", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_arguments()
    try:
        if arguments.command == "seal":
            seal(arguments.app, arguments.configuration, arguments.receipt)
        elif arguments.command == "verify":
            verify(arguments.app, arguments.configuration, arguments.receipt)
        else:
            print(tree_sha256(arguments.app))
    except (ReleaseArtifactError, ReleaseConfigurationError, OSError) as error:
        print(f"release artifact error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
