from __future__ import annotations

import json
import os
import subprocess
import uuid
from pathlib import Path

from vibe_stick.config.paths import BRIDGE_IDENTITY_PATH


BRIDGE_IDENTITY_SCHEMA_VERSION = 1
BONJOUR_SERVICE_TYPE = "_vibestick._tcp"


class BridgeIdentityStore:
    def __init__(self, path: Path = BRIDGE_IDENTITY_PATH) -> None:
        self.path = path

    def bridge_id(self) -> str:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            payload = {}
        existing = str(payload.get("bridge_id") or "") if isinstance(payload, dict) else ""
        try:
            return str(uuid.UUID(existing))
        except ValueError:
            pass

        bridge_id = str(uuid.uuid4())
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".{self.path.name}.tmp-{uuid.uuid4()}")
        temporary.write_text(
            json.dumps(
                {"schema_version": BRIDGE_IDENTITY_SCHEMA_VERSION, "bridge_id": bridge_id},
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.path)
        os.chmod(self.path, 0o600)
        return bridge_id


class BonjourAdvertiser:
    def __init__(self, *, bridge_id: str, port: int) -> None:
        self.bridge_id = bridge_id
        self.port = port
        self._process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        if self._process is not None:
            return
        try:
            self._process = subprocess.Popen(
                [
                    "/usr/bin/dns-sd",
                    "-R",
                    "VibeStick Bridge",
                    BONJOUR_SERVICE_TYPE,
                    "local.",
                    str(self.port),
                    f"bridge_id={self.bridge_id}",
                    "protocol=2",
                    "auth=paired",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
        except OSError:
            self._process = None

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
