from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


SCHEMA_VERSION = 1
KEYCHAIN_STORAGE = "macos-keychain"
KEYCHAIN_SERVICE = "io.github.hanminyin.vibestick"
MANAGED_ACCOUNTS = {
    "bridge-token": "bridge-token-v1",
    "asr-api-key": "asr-api-key-v1",
}
DISALLOWED_BRIDGE_TOKENS = {
    "change-this-shared-token",
    "paste-generated-token-here",
    "changeme",
    "change-me",
}


class ManagedRuntimeConfigurationError(ValueError):
    """Typed, secret-free failure for the M4-5C runtime document."""


@dataclass(frozen=True)
class ManagedCredentialReference:
    purpose: str
    service: str
    account: str


@dataclass(frozen=True)
class ResolvedManagedRuntimeConfiguration:
    bridge_token: str
    asr_api_key: str
    asr: dict[str, Any] | None
    agent_provider: str | None
    project_presentation: dict[str, Any] | None
    voice_delivery: dict[str, Any] | None
    sound_enabled: bool | None


def parse_managed_runtime_configuration(
    payload: bytes | str,
    *,
    credential_reader: Callable[[str, str], str],
) -> ResolvedManagedRuntimeConfiguration:
    """Parse one managed runtime document using an injected credential reader.

    M4-5I keeps parsing independent from filesystem and Keychain APIs. The live
    startup adapter is a separate narrow boundary and supplies only fixed,
    versioned credential references to this function.
    """

    try:
        document = json.loads(payload)
    except (TypeError, UnicodeError, json.JSONDecodeError) as exc:
        raise ManagedRuntimeConfigurationError("unreadable-managed-configuration") from exc
    if not isinstance(document, dict) or document.get("schemaVersion") != SCHEMA_VERSION:
        raise ManagedRuntimeConfigurationError("unsupported-managed-configuration")

    references = _credential_references(document.get("credentialReferences"))
    asr = _optional_dict(document.get("asr"), "invalid-asr-configuration")
    if asr is not None:
        _validate_asr(asr)
    agent_provider = document.get("agentProvider")
    if agent_provider is not None and agent_provider not in {"codex", "claude", "auto"}:
        raise ManagedRuntimeConfigurationError("invalid-agent-provider")
    project_presentation = _optional_dict(
        document.get("projectPresentation"),
        "invalid-project-presentation",
    )
    if project_presentation is not None:
        _validate_project_presentation(project_presentation)
    voice_delivery = _optional_dict(document.get("voiceDelivery"), "invalid-voice-delivery")
    if voice_delivery is not None and voice_delivery.get("sendMode") not in {
        "paste_only",
        "confirm",
        "auto_send",
    }:
        raise ManagedRuntimeConfigurationError("invalid-voice-delivery")
    sound_enabled = document.get("soundEnabled")
    if sound_enabled is not None and not isinstance(sound_enabled, bool):
        raise ManagedRuntimeConfigurationError("invalid-sound-preference")

    bridge_token = _resolve(
        "bridge-token",
        references,
        credential_reader,
        missing_error="missing-bridge-credential",
    )
    if bridge_token.lower() in DISALLOWED_BRIDGE_TOKENS:
        raise ManagedRuntimeConfigurationError("missing-bridge-credential")
    asr_api_key = ""
    if asr is not None and asr.get("provider") != "local-command":
        asr_api_key = _resolve(
            "asr-api-key",
            references,
            credential_reader,
            missing_error="missing-asr-credential",
        )

    return ResolvedManagedRuntimeConfiguration(
        bridge_token=bridge_token,
        asr_api_key=asr_api_key,
        asr=asr,
        agent_provider=agent_provider,
        project_presentation=project_presentation,
        voice_delivery=voice_delivery,
        sound_enabled=sound_enabled,
    )


def _credential_references(raw: object) -> dict[str, ManagedCredentialReference]:
    if not isinstance(raw, list):
        raise ManagedRuntimeConfigurationError("invalid-credential-references")
    references: dict[str, ManagedCredentialReference] = {}
    for item in raw:
        if not isinstance(item, dict):
            raise ManagedRuntimeConfigurationError("invalid-credential-reference")
        purpose = item.get("purpose")
        if not isinstance(purpose, str):
            raise ManagedRuntimeConfigurationError("invalid-credential-reference")
        expected_account = MANAGED_ACCOUNTS.get(purpose)
        if (
            item.get("schemaVersion") != SCHEMA_VERSION
            or item.get("storage") != KEYCHAIN_STORAGE
            or item.get("service") != KEYCHAIN_SERVICE
            or item.get("account") != expected_account
            or purpose in references
        ):
            raise ManagedRuntimeConfigurationError("invalid-credential-reference")
        references[purpose] = ManagedCredentialReference(
            purpose=purpose,
            service=KEYCHAIN_SERVICE,
            account=expected_account,
        )
    return references


def _resolve(
    purpose: str,
    references: dict[str, ManagedCredentialReference],
    credential_reader: Callable[[str, str], str],
    *,
    missing_error: str,
) -> str:
    reference = references.get(purpose)
    if reference is None:
        raise ManagedRuntimeConfigurationError(missing_error)
    value = credential_reader(reference.service, reference.account)
    if not isinstance(value, str) or not value.strip():
        raise ManagedRuntimeConfigurationError(missing_error)
    return value.strip()


def _optional_dict(value: object, error: str) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ManagedRuntimeConfigurationError(error)
    return value


def _validate_asr(asr: dict[str, Any]) -> None:
    provider = asr.get("provider")
    if provider not in {"groq", "siliconflow", "openai-compatible", "local-command"}:
        raise ManagedRuntimeConfigurationError("invalid-asr-configuration")
    language = asr.get("language")
    if not isinstance(language, str) or not language or len(language) > 12:
        raise ManagedRuntimeConfigurationError("invalid-asr-configuration")
    if provider == "local-command":
        if not isinstance(asr.get("localCommand"), str) or not asr["localCommand"].strip():
            raise ManagedRuntimeConfigurationError("invalid-asr-configuration")
    elif not all(isinstance(asr.get(key), str) and asr[key].strip() for key in ("baseURL", "model")):
        raise ManagedRuntimeConfigurationError("invalid-asr-configuration")


def _validate_project_presentation(project: dict[str, Any]) -> None:
    if not isinstance(project.get("projectName"), str) or not isinstance(
        project.get("showProjectName"),
        bool,
    ):
        raise ManagedRuntimeConfigurationError("invalid-project-presentation")
