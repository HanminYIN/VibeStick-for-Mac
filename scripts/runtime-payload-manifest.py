#!/usr/bin/env python3
"""Generate or verify the deterministic M4 runtime payload manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

SCHEMA_VERSION = 1
MANIFEST_NAME = "manifest-v1.json"
REQUIRED_FILES = {
    "Components.noindex/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge",
    "Components.noindex/VibeStick HUD.app/Contents/MacOS/VibeStickHUD",
    "Components.noindex/VibeStick Paste.app/Contents/MacOS/VibeStickPaste",
    "Components.noindex/VibeStick Paste.app/Contents/Resources/VibeStickPaste.build",
    "runtime/bridge/pyproject.toml",
    "runtime/bridge/src/vibe_stick/__main__.py",
}


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"runtime payload: {message}")


def safe_relative_path(value: str) -> bool:
    path = PurePosixPath(value)
    return (
        bool(value)
        and not value.startswith(("/", "~"))
        and "\\" not in value
        and all(part not in ("", ".", "..") for part in path.parts)
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def payload_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in sorted(directory_names):
            candidate = directory_path / name
            if candidate.is_symlink():
                fail(f"symlink is not allowed: {candidate.relative_to(root).as_posix()}")
        for name in sorted(file_names):
            candidate = directory_path / name
            relative = candidate.relative_to(root).as_posix()
            if relative == MANIFEST_NAME:
                continue
            if candidate.is_symlink() or not candidate.is_file():
                fail(f"non-regular file is not allowed: {relative}")
            files.append(candidate)
    return sorted(files, key=lambda item: item.relative_to(root).as_posix())


def entry(root: Path, path: Path) -> dict[str, object]:
    relative = path.relative_to(root).as_posix()
    if not safe_relative_path(relative):
        fail(f"unsafe path: {relative}")
    metadata = path.stat()
    return {
        "mode": stat.S_IMODE(metadata.st_mode),
        "path": relative,
        "sha256": sha256(path),
        "size": metadata.st_size,
    }


def generate(root: Path, version: str) -> None:
    if not root.is_dir():
        fail(f"payload root does not exist: {root}")
    entries = [entry(root, path) for path in payload_files(root)]
    actual = {str(item["path"]) for item in entries}
    missing = sorted(REQUIRED_FILES - actual)
    if missing:
        fail(f"required files are missing: {', '.join(missing)}")
    manifest = {
        "files": entries,
        "payloadVersion": version,
        "schemaVersion": SCHEMA_VERSION,
    }
    destination = root / MANIFEST_NAME
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.chmod(destination, 0o644)


def verify(root: Path) -> None:
    manifest_path = root / MANIFEST_NAME
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {MANIFEST_NAME}: {error}")
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        fail("unsupported schema version")
    if not isinstance(manifest.get("payloadVersion"), str) or not manifest["payloadVersion"].strip():
        fail("payloadVersion is empty")
    declared_entries = manifest.get("files")
    if not isinstance(declared_entries, list):
        fail("files is not an array")

    declared: dict[str, dict[str, object]] = {}
    for raw in declared_entries:
        if not isinstance(raw, dict) or not isinstance(raw.get("path"), str):
            fail("manifest contains an invalid file entry")
        relative = raw["path"]
        if not safe_relative_path(relative):
            fail(f"unsafe path: {relative}")
        if relative in declared:
            fail(f"duplicate path: {relative}")
        declared[relative] = raw

    actual_paths = payload_files(root)
    actual = {path.relative_to(root).as_posix(): path for path in actual_paths}
    if set(actual) != set(declared):
        missing = sorted(set(declared) - set(actual))
        extra = sorted(set(actual) - set(declared))
        fail(f"file set mismatch; missing={missing}, extra={extra}")
    required_missing = sorted(REQUIRED_FILES - set(declared))
    if required_missing:
        fail(f"required files are missing: {', '.join(required_missing)}")

    for relative, path in actual.items():
        expected = declared[relative]
        metadata = path.stat()
        if expected.get("size") != metadata.st_size:
            fail(f"size mismatch: {relative}")
        if expected.get("mode") != stat.S_IMODE(metadata.st_mode):
            fail(f"mode mismatch: {relative}")
        if expected.get("sha256") != sha256(path):
            fail(f"SHA-256 mismatch: {relative}")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("root", type=Path)
    generate_parser.add_argument("version")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("root", type=Path)
    arguments = parser.parse_args()

    if arguments.command == "generate":
        generate(arguments.root.resolve(), arguments.version)
    else:
        verify(arguments.root.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
