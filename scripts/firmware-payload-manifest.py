#!/usr/bin/env python3
"""Generate and verify the deterministic M4 StickS3 firmware payload manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import NoReturn

SCHEMA_VERSION = 1
MANIFEST_NAME = "manifest-v1.json"
FLASH_SIZE = 8 * 1024 * 1024
EXPECTED_FILES = {
    "bootloader.bin": 0x0000,
    "partition-table.bin": 0x8000,
    "vibe-stick.bin": 0x10000,
}
PRESERVED_RANGES = [{"name": "nvs", "start": 0x9000, "endExclusive": 0xF000}]
SOURCE_DIRECTORIES = {"assets", "generated", "include", "src"}
SOURCE_FILES = {
    "CMakeLists.txt",
    "dependencies.lock",
    "partitions_vibestick.csv",
    "sdkconfig.defaults",
}
SECRET_MACROS = {
    "VIBE_STICK_WIFI_SSID",
    "VIBE_STICK_WIFI_PASSWORD",
    "VIBE_STICK_BRIDGE_HOST",
    "VIBE_STICK_BRIDGE_TOKEN",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"firmware payload: {message}")


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


def source_files(root: Path) -> list[Path]:
    files = [root / name for name in SOURCE_FILES]
    for directory_name in sorted(SOURCE_DIRECTORIES):
        directory = root / directory_name
        if not directory.is_dir():
            fail(f"source directory is missing: {directory_name}")
        for directory_path, directory_names, file_names in os.walk(directory, followlinks=False):
            directory_names[:] = sorted(directory_names)
            for name in sorted(file_names):
                candidate = Path(directory_path) / name
                if candidate.name == "vibe_stick_secrets.h":
                    continue
                if candidate.is_symlink() or not candidate.is_file():
                    fail(f"invalid source file: {candidate.relative_to(root).as_posix()}")
                files.append(candidate)
    missing = [path.name for path in files if not path.is_file()]
    if missing:
        fail(f"source files are missing: {', '.join(sorted(set(missing)))}")
    return sorted(files, key=lambda item: item.relative_to(root).as_posix())


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in source_files(root):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return digest.hexdigest()


def payload_files(root: Path) -> dict[str, Path]:
    entries: dict[str, Path] = {}
    for candidate in sorted(root.iterdir(), key=lambda item: item.name):
        if candidate.name == MANIFEST_NAME:
            continue
        if candidate.is_symlink() or not candidate.is_file():
            fail(f"only regular root files are allowed: {candidate.name}")
        entries[candidate.name] = candidate
    if set(entries) != set(EXPECTED_FILES):
        missing = sorted(set(EXPECTED_FILES) - set(entries))
        extra = sorted(set(entries) - set(EXPECTED_FILES))
        fail(f"file set mismatch; missing={missing}, extra={extra}")
    return entries


def validate_file_layout(entries: list[dict[str, object]]) -> None:
    ordered: list[tuple[int, int, str]] = []
    for entry in entries:
        path = entry.get("path")
        offset = entry.get("offset")
        size = entry.get("size")
        if not isinstance(path, str) or not safe_relative_path(path) or "/" in path:
            fail("manifest contains an unsafe file path")
        if EXPECTED_FILES.get(path) != offset:
            fail(f"unexpected flash offset: {path}")
        if not isinstance(size, int) or size <= 0:
            fail(f"invalid size: {path}")
        if not isinstance(offset, int) or offset < 0 or offset + size > FLASH_SIZE:
            fail(f"file is outside flash bounds: {path}")
        ordered.append((offset, offset + size, path))
    ordered.sort()
    for previous, current in zip(ordered, ordered[1:]):
        if previous[1] > current[0]:
            fail(f"flash ranges overlap: {previous[2]} and {current[2]}")
    for start, end, path in ordered:
        for preserved in PRESERVED_RANGES:
            if start < preserved["endExclusive"] and end > preserved["start"]:
                fail(f"{path} overlaps preserved {preserved['name']} range")


def generate(root: Path, version: str, revision: str, digest: str) -> None:
    if not root.is_dir():
        fail(f"payload root does not exist: {root}")
    if not version.strip():
        fail("payload version is empty")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        fail("source revision must be a 40-character lowercase Git object id")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("source digest must be a lowercase SHA-256")
    files = payload_files(root)
    entries = []
    for relative, path in files.items():
        metadata = path.stat()
        entries.append(
            {
                "mode": stat.S_IMODE(metadata.st_mode),
                "offset": EXPECTED_FILES[relative],
                "path": relative,
                "sha256": sha256(path),
                "size": metadata.st_size,
            }
        )
    entries.sort(key=lambda item: int(item["offset"]))
    validate_file_layout(entries)
    manifest = {
        "board": "M5Stack StickS3",
        "files": entries,
        "flash": {"frequency": "80m", "mode": "dio", "size": FLASH_SIZE},
        "payloadVersion": version,
        "preservedRanges": PRESERVED_RANGES,
        "schemaVersion": SCHEMA_VERSION,
        "source": {"digest": digest, "revision": revision},
        "target": "esp32s3",
    }
    destination = root / MANIFEST_NAME
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.chmod(destination, 0o644)


def verify(root: Path) -> None:
    manifest_path = root / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        fail(f"{MANIFEST_NAME} must be a regular file")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {MANIFEST_NAME}: {error}")
    expected_top_level = {
        "board", "files", "flash", "payloadVersion", "preservedRanges",
        "schemaVersion", "source", "target",
    }
    if set(manifest) != expected_top_level:
        fail("manifest top-level fields do not match schema 1")
    if manifest["schemaVersion"] != SCHEMA_VERSION:
        fail("unsupported schema version")
    if manifest["target"] != "esp32s3" or manifest["board"] != "M5Stack StickS3":
        fail("unexpected firmware target")
    if not isinstance(manifest["payloadVersion"], str) or not manifest["payloadVersion"].strip():
        fail("payload version is empty")
    if manifest["flash"] != {"frequency": "80m", "mode": "dio", "size": FLASH_SIZE}:
        fail("flash geometry does not match the StickS3 contract")
    if manifest["preservedRanges"] != PRESERVED_RANGES:
        fail("preserved NVS range does not match the contract")
    source = manifest["source"]
    if not isinstance(source, dict) or set(source) != {"digest", "revision"}:
        fail("source identity is invalid")
    if not isinstance(source["revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
        fail("source revision is invalid")
    if not isinstance(source["digest"], str) or not re.fullmatch(r"[0-9a-f]{64}", source["digest"]):
        fail("source digest is invalid")
    entries = manifest["files"]
    if not isinstance(entries, list) or len(entries) != len(EXPECTED_FILES):
        fail("files do not match the required image set")
    if {entry.get("path") for entry in entries if isinstance(entry, dict)} != set(EXPECTED_FILES):
        fail("files do not match the required image set")
    files = payload_files(root)
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"mode", "offset", "path", "sha256", "size"}:
            fail("manifest contains an invalid file entry")
        path = files.get(entry["path"])
        if path is None:
            fail("manifest references an undeclared file")
        metadata = path.stat()
        if entry["mode"] != stat.S_IMODE(metadata.st_mode) or entry["mode"] != 0o644:
            fail(f"mode mismatch: {entry['path']}")
        if entry["size"] != metadata.st_size:
            fail(f"size mismatch: {entry['path']}")
        if entry["sha256"] != sha256(path):
            fail(f"SHA-256 mismatch: {entry['path']}")
    validate_file_layout(entries)


def verify_source(root: Path, source_root: Path) -> None:
    verify(root)
    manifest_path = root / MANIFEST_NAME
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {MANIFEST_NAME}: {error}")
    expected = manifest["source"]["digest"]
    actual = source_digest(source_root)
    if actual != expected:
        fail("payload source digest does not match the secret-free firmware source")


def secret_values(header: Path) -> list[bytes]:
    if not header.exists():
        return []
    values: list[bytes] = []
    pattern = re.compile(r'^\s*#define\s+([A-Z0-9_]+)\s+"((?:[^"\\]|\\.)*)"\s*$')
    for line in header.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match is None or match.group(1) not in SECRET_MACROS:
            continue
        try:
            decoded = bytes(match.group(2), "utf-8").decode("unicode_escape").encode("utf-8")
        except UnicodeError:
            fail("local secret header contains an unsupported escaped value")
        if len(decoded) >= 4 and decoded not in {b"127.0.0.1"}:
            values.append(decoded)
    return values


def assert_no_secrets(root: Path, header: Path) -> None:
    values = secret_values(header)
    for path in payload_files(root).values():
        content = path.read_bytes()
        if any(value in content for value in values):
            fail("a local configuration value was found in a firmware image")


def assert_build_layout(build_root: Path) -> None:
    path = build_root / "flasher_args.json"
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read flasher_args.json: {error}")
    expected_settings = {"flash_mode": "dio", "flash_size": "8MB", "flash_freq": "80m"}
    expected_files = {
        "0x0": "bootloader/bootloader.bin",
        "0x8000": "partition_table/partition-table.bin",
        "0x10000": "vibe_stick_sticks3.bin",
    }
    if document.get("flash_settings") != expected_settings:
        fail("ESP-IDF flash settings do not match the payload contract")
    if document.get("flash_files") != expected_files:
        fail("ESP-IDF flash files or offsets do not match the payload contract")
    extra = document.get("extra_esptool_args")
    if not isinstance(extra, dict) or extra.get("chip") != "esp32s3":
        fail("ESP-IDF target is not esp32s3")
    for relative in expected_files.values():
        candidate = build_root / relative
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size <= 0:
            fail(f"ESP-IDF output is missing: {relative}")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("root", type=Path)
    generate_parser.add_argument("version")
    generate_parser.add_argument("source_revision")
    generate_parser.add_argument("source_digest")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("root", type=Path)
    verify_source_parser = subparsers.add_parser("verify-source")
    verify_source_parser.add_argument("root", type=Path)
    verify_source_parser.add_argument("source_root", type=Path)
    digest_parser = subparsers.add_parser("source-digest")
    digest_parser.add_argument("root", type=Path)
    secret_parser = subparsers.add_parser("assert-no-secrets")
    secret_parser.add_argument("root", type=Path)
    secret_parser.add_argument("header", type=Path)
    layout_parser = subparsers.add_parser("assert-build-layout")
    layout_parser.add_argument("root", type=Path)
    arguments = parser.parse_args()

    if arguments.command == "generate":
        generate(
            arguments.root.resolve(),
            arguments.version,
            arguments.source_revision,
            arguments.source_digest,
        )
    elif arguments.command == "verify":
        verify(arguments.root.resolve())
    elif arguments.command == "verify-source":
        verify_source(arguments.root.resolve(), arguments.source_root.resolve())
    elif arguments.command == "source-digest":
        print(source_digest(arguments.root.resolve()))
    elif arguments.command == "assert-no-secrets":
        assert_no_secrets(arguments.root.resolve(), arguments.header.resolve())
    else:
        assert_build_layout(arguments.root.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
