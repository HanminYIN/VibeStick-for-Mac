from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from vibe_stick.config.paths import DEVICE_REGISTRY_PATH


DEVICE_REGISTRY_SCHEMA_VERSION = 1
DEVICE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{5,63}$")
PAIRING_TOKEN_MINIMUM_LENGTH = 32


@dataclass(frozen=True)
class PairedDevice:
    device_id: str
    name: str
    token_salt: str
    token_hash: str
    paired_at: str
    firmware_version: str
    revoked: bool = False


class PairedDeviceRegistry:
    """Read the Mac-owned registry without ever persisting plaintext device keys."""

    def __init__(self, path: Path = DEVICE_REGISTRY_PATH) -> None:
        self.path = path

    def devices(self) -> list[PairedDevice]:
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return []
        if not isinstance(payload, dict) or payload.get("schema_version") != DEVICE_REGISTRY_SCHEMA_VERSION:
            return []
        raw_devices = payload.get("devices")
        if not isinstance(raw_devices, list):
            return []
        devices: list[PairedDevice] = []
        for item in raw_devices:
            parsed = _device_from_dict(item)
            if parsed is not None:
                devices.append(parsed)
        return devices

    def find(self, device_id: str) -> PairedDevice | None:
        if not valid_device_id(device_id):
            return None
        return next((device for device in self.devices() if device.device_id == device_id), None)

    def authenticate(self, device_id: str, token: str) -> bool:
        if len(token) < PAIRING_TOKEN_MINIMUM_LENGTH:
            return False
        device = self.find(device_id)
        if device is None or device.revoked:
            return False
        actual = pairing_token_hash(device.token_salt, token)
        return hmac.compare_digest(actual, device.token_hash)


def valid_device_id(device_id: str) -> bool:
    return bool(DEVICE_ID_PATTERN.fullmatch(device_id))


def pairing_token_hash(salt: str, token: str) -> str:
    try:
        salt_bytes = bytes.fromhex(salt)
    except ValueError:
        return ""
    digest = hashlib.sha256(b"vibestick-pairing-v1\0" + salt_bytes + token.encode("utf-8")).hexdigest()
    return digest


def _device_from_dict(value: Any) -> PairedDevice | None:
    if not isinstance(value, dict):
        return None
    device_id = str(value.get("device_id") or "").strip()
    token_salt = str(value.get("token_salt") or "").strip().lower()
    token_hash = str(value.get("token_hash") or "").strip().lower()
    if not valid_device_id(device_id):
        return None
    if len(token_salt) != 32 or not _is_lower_hex(token_salt):
        return None
    if len(token_hash) != 64 or not _is_lower_hex(token_hash):
        return None
    return PairedDevice(
        device_id=device_id,
        name=str(value.get("name") or "StickS3")[:64],
        token_salt=token_salt,
        token_hash=token_hash,
        paired_at=str(value.get("paired_at") or "")[:64],
        firmware_version=str(value.get("firmware_version") or "")[:32],
        revoked=bool(value.get("revoked", False)),
    )


def _is_lower_hex(value: str) -> bool:
    return all(character in "0123456789abcdef" for character in value)
