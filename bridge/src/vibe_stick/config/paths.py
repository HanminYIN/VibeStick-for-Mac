from __future__ import annotations

from pathlib import Path


APP_SUPPORT_DIR = (
    Path.home() / "Library" / "Application Support" / "VibeStick"
)
STATE_PATH = APP_SUPPORT_DIR / "state.json"
QUOTA_PATH = APP_SUPPORT_DIR / "quota.json"
CLAUDE_QUOTA_PATH = APP_SUPPORT_DIR / "claude-quota.json"
RECORDING_PATH = APP_SUPPORT_DIR / "recording.json"
HUD_STATE_PATH = APP_SUPPORT_DIR / "hud-state.json"
RECORDINGS_DIR = APP_SUPPORT_DIR / "Recordings"
DEVICE_REGISTRY_PATH = APP_SUPPORT_DIR / "devices-v1.json"
DEVICE_CONFIGURATION_PATH = APP_SUPPORT_DIR / "device-config-v1.json"
BRIDGE_IDENTITY_PATH = APP_SUPPORT_DIR / "bridge-identity-v1.json"


def ensure_app_support() -> Path:
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    return APP_SUPPORT_DIR
