from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from vibe_stick.config.paths import DEVICE_CONFIGURATION_PATH


DEVICE_CONFIGURATION_SCHEMA_VERSION = 1
MAX_CONFIGURATION_BYTES = 16_384
ALLOWED_MODULES = {"codex", "claude", "connection"}
ALLOWED_DOUBLE_PRESS_ACTIONS = {"refresh_quota", "show_status", "home", "toggle_mute"}
ALLOWED_SIDE_PRESS_ACTIONS = {"next_page", "none"}
MAX_PROJECT_NAME_CHARACTERS = 18
MAX_PROJECT_NAME_BYTES = 39


def default_device_configuration() -> dict[str, Any]:
    return {
        "schema_version": DEVICE_CONFIGURATION_SCHEMA_VERSION,
        "revision": 0,
        "modules": ["codex", "connection"],
        "default_page": "codex",
        "project": {"visible": True, "name": ""},
        "buttons": {
            "front_double": "refresh_quota",
            "side_single": "next_page",
        },
    }


class DeviceConfigurationStore:
    def __init__(self, path: Path = DEVICE_CONFIGURATION_PATH) -> None:
        self.path = path

    def current(self) -> dict[str, Any]:
        try:
            raw = self.path.read_bytes()
        except (FileNotFoundError, OSError):
            return default_device_configuration()
        if len(raw) > MAX_CONFIGURATION_BYTES:
            return default_device_configuration()
        try:
            payload = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return default_device_configuration()
        return normalize_device_configuration(payload)


def normalize_device_configuration(value: Any) -> dict[str, Any]:
    default = default_device_configuration()
    if not isinstance(value, dict) or value.get("schema_version") != DEVICE_CONFIGURATION_SCHEMA_VERSION:
        return default

    revision = value.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        revision = 0

    requested_modules = value.get("modules")
    modules: list[str] = []
    if isinstance(requested_modules, list):
        for module in requested_modules:
            if isinstance(module, str) and module in ALLOWED_MODULES and module not in modules:
                modules.append(module)
    if "codex" not in modules:
        modules.insert(0, "codex")
    if "connection" not in modules:
        modules.append("connection")

    default_page = value.get("default_page")
    if not isinstance(default_page, str) or default_page not in modules:
        default_page = "codex"

    project_value = value.get("project")
    project = project_value if isinstance(project_value, dict) else {}
    project_name = project.get("name")
    if not isinstance(project_name, str):
        project_name = ""
    project_name = project_name.strip()[:MAX_PROJECT_NAME_CHARACTERS]
    while len(project_name.encode("utf-8")) > MAX_PROJECT_NAME_BYTES:
        project_name = project_name[:-1]

    buttons_value = value.get("buttons")
    buttons = buttons_value if isinstance(buttons_value, dict) else {}
    front_double = buttons.get("front_double")
    if front_double not in ALLOWED_DOUBLE_PRESS_ACTIONS:
        front_double = "refresh_quota"
    side_single = buttons.get("side_single")
    if side_single not in ALLOWED_SIDE_PRESS_ACTIONS:
        side_single = "next_page"

    return {
        "schema_version": DEVICE_CONFIGURATION_SCHEMA_VERSION,
        "revision": revision,
        "modules": modules,
        "default_page": default_page,
        "project": {
            "visible": bool(project.get("visible", True)),
            "name": project_name,
        },
        "buttons": {
            "front_double": front_double,
            "side_single": side_single,
        },
    }
