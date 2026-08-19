from __future__ import annotations

import os
import stat
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from vibe_stick.config.managed_runtime import (
    KEYCHAIN_SERVICE,
    MANAGED_ACCOUNTS,
    ManagedRuntimeConfigurationError,
    ResolvedManagedRuntimeConfiguration,
    parse_managed_runtime_configuration,
)
from vibe_stick.config.paths import APP_SUPPORT_DIR


MANAGED_RUNTIME_PATH = APP_SUPPORT_DIR / "managed-runtime-v1.json"
MAXIMUM_MANAGED_RUNTIME_BYTES = 1024 * 1024
KEYCHAIN_AUTHORIZATION_TIMEOUT_SECONDS = 60.0
STARTUP_MODE_ENVIRONMENT_KEY = "VIBE_STICK_RUNTIME_SELECTION"
STARTUP_MODES = {"managed", "legacy"}


class ManagedRuntimeBootstrapError(RuntimeError):
    """A fixed, secret-free startup failure."""


@dataclass(frozen=True)
class ManagedRuntimeFileReader:
    path: Path = MANAGED_RUNTIME_PATH
    maximum_bytes: int = MAXIMUM_MANAGED_RUNTIME_BYTES

    def read(self) -> bytes | None:
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.path, flags)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ManagedRuntimeBootstrapError("managed-runtime-unavailable") from exc

        try:
            before = os.fstat(descriptor)
            mode = stat.S_IMODE(before.st_mode)
            if (
                not stat.S_ISREG(before.st_mode)
                or mode & 0o077
                or before.st_size <= 0
                or before.st_size > self.maximum_bytes
            ):
                raise ManagedRuntimeBootstrapError("managed-runtime-unavailable")

            chunks: list[bytes] = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(remaining, 64 * 1024))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            payload = b"".join(chunks)
            after = os.fstat(descriptor)
            if (
                remaining
                or len(payload) != before.st_size
                or before.st_dev != after.st_dev
                or before.st_ino != after.st_ino
                or before.st_size != after.st_size
                or before.st_mtime_ns != after.st_mtime_ns
            ):
                raise ManagedRuntimeBootstrapError("managed-runtime-unavailable")
            return payload
        except OSError as exc:
            raise ManagedRuntimeBootstrapError("managed-runtime-unavailable") from exc
        finally:
            os.close(descriptor)


KeychainCommandRunner = Callable[[list[str], float], subprocess.CompletedProcess[str]]


def _run_keychain_command(
    arguments: list[str],
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


@dataclass(frozen=True)
class MacOSVersionedKeychainReader:
    runner: KeychainCommandRunner = _run_keychain_command
    timeout_seconds: float = KEYCHAIN_AUTHORIZATION_TIMEOUT_SECONDS

    def __call__(self, service: str, account: str) -> str:
        if service != KEYCHAIN_SERVICE or account not in set(MANAGED_ACCOUNTS.values()):
            raise ManagedRuntimeBootstrapError("managed-credential-unavailable")
        try:
            result = self.runner(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    service,
                    "-a",
                    account,
                    "-w",
                ],
                self.timeout_seconds,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ManagedRuntimeBootstrapError("managed-credential-unavailable") from exc
        value = result.stdout.strip() if result.returncode == 0 else ""
        if not value:
            raise ManagedRuntimeBootstrapError("managed-credential-unavailable")
        return value


def load_runtime_configuration(
    *,
    expected_mode: str | None = None,
    file_reader: ManagedRuntimeFileReader | None = None,
    credential_reader: Callable[[str, str], str] | None = None,
) -> ResolvedManagedRuntimeConfiguration | None:
    """Select managed or legacy startup without ever silently crossing modes."""

    if expected_mode is not None and expected_mode not in STARTUP_MODES:
        raise ManagedRuntimeBootstrapError("runtime-selection-unavailable")
    reader = file_reader or ManagedRuntimeFileReader()
    try:
        payload = reader.read()
    except Exception as exc:
        raise ManagedRuntimeBootstrapError("managed-runtime-unavailable") from exc

    if expected_mode == "managed" and payload is None:
        raise ManagedRuntimeBootstrapError("managed-runtime-unavailable")
    if expected_mode == "legacy":
        if payload is not None:
            raise ManagedRuntimeBootstrapError("runtime-selection-changed")
        return None
    if payload is None:
        return None

    resolver = credential_reader or MacOSVersionedKeychainReader()
    try:
        return parse_managed_runtime_configuration(payload, credential_reader=resolver)
    except (ManagedRuntimeConfigurationError, ManagedRuntimeBootstrapError) as exc:
        raise ManagedRuntimeBootstrapError("managed-runtime-unavailable") from exc
    except Exception as exc:
        raise ManagedRuntimeBootstrapError("managed-runtime-unavailable") from exc


def configured_startup_mode() -> str | None:
    value = os.environ.get(STARTUP_MODE_ENVIRONMENT_KEY, "").strip().lower()
    return value or None
