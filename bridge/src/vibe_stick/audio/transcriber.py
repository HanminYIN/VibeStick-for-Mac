from __future__ import annotations

import json
import os
import subprocess
import time
import tomllib
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from uuid import uuid4

from vibe_stick.config.paths import APP_SUPPORT_DIR

GROQ_ASR_BASE_URL = "https://api.groq.com/openai/v1"
SILICONFLOW_ASR_BASE_URL = "https://api.siliconflow.cn/v1"
DEFAULT_ASR_MODEL = "whisper-large-v3-turbo"
DEFAULT_ASR_LANGUAGE = "zh"
KEYCHAIN_SERVICE = "io.github.hanminyin.vibestick"
KEYCHAIN_ASR_ACCOUNT = "asr-api-key"
KEYCHAIN_AUTHORIZATION_TIMEOUT_SECONDS = 60.0


@dataclass
class TranscriptionResult:
    text: str = ""
    success: bool = False
    message: str = ""
    source: str = "none"


class TranscriptionAdapter:
    """project-owned boundary for speech-to-text providers.

    V1 does not bake any cloud ASR provider or secret into the bridge. A local
    command can be configured with VIBE_STICK_TRANSCRIBE_CMD and should print
    the final transcript to stdout.
    """

    def __init__(
        self,
        *,
        managed_asr: dict[str, Any] | None = None,
        managed_asr_api_key: str = "",
    ) -> None:
        self._managed_asr = dict(managed_asr) if managed_asr is not None else None
        self._managed_asr_api_key = managed_asr_api_key

    def transcribe(
        self,
        session_payload: dict[str, Any],
        explicit_text: str = "",
    ) -> TranscriptionResult:
        explicit_text = explicit_text.strip()
        if explicit_text:
            return TranscriptionResult(
                text=explicit_text,
                success=True,
                message="Transcript supplied by request",
                source="request",
            )

        if self._managed_asr is None:
            configured_text = os.environ.get("VIBE_STICK_TRANSCRIPT_TEXT", "").strip()
            if configured_text:
                return TranscriptionResult(
                    text=configured_text,
                    success=True,
                    message="Transcript supplied by local development override",
                    source="env",
                )

            command = os.environ.get("VIBE_STICK_TRANSCRIBE_CMD", "").strip()
            if command:
                return _transcribe_with_command(command, session_payload)

        result = self._transcribe_with_configured_asr(session_payload)
        if self._managed_asr is not None:
            result.message = _without_secret(result.message, self._managed_asr_api_key)
        return result

    def _transcribe_with_configured_asr(self, session_payload: dict[str, Any]) -> TranscriptionResult:
        config = (
            _config_from_managed_runtime(self._managed_asr, self._managed_asr_api_key)
            if self._managed_asr is not None
            else _load_asr_config()
        )
        if config.get("provider") == "local-command":
            command = config.get("command", "").strip()
            if not command:
                return TranscriptionResult(
                    success=False,
                    message="No transcription adapter configured",
                    source="none",
                )
            return _transcribe_with_command(command, session_payload)

        audio_file_raw = str(session_payload.get("audio_file") or "").strip()
        if not audio_file_raw:
            return TranscriptionResult(
                success=False,
                message="No audio file available for transcription",
                source="none",
            )
        audio_file = Path(audio_file_raw)
        if not audio_file.is_file():
            return TranscriptionResult(
                success=False,
                message="No audio file available for transcription",
                source="none",
            )

        if config.get("provider") not in {"groq", "siliconflow", "openai-compatible"}:
            return TranscriptionResult(
                success=False,
                message="No transcription adapter configured",
                source="none",
            )
        if not config.get("api_key") and not _is_loopback_url(config.get("base_url", "")):
            return TranscriptionResult(
                success=False,
                message="No transcription adapter configured",
                source="none",
            )
        return _transcribe_openai_compatible(audio_file, config)


def _transcribe_with_command(command: str, session_payload: dict[str, Any]) -> TranscriptionResult:
    try:
        result = subprocess.run(
            command,
            input=json.dumps(session_payload),
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=_command_timeout_seconds(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return TranscriptionResult(
            success=False,
            message=f"Transcription command failed: {exc}",
            source="command",
        )

    transcript = result.stdout.strip()
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Transcription command failed").strip()
        return TranscriptionResult(success=False, message=message, source="command")
    if not transcript:
        return TranscriptionResult(success=False, message="Transcription command returned no text", source="command")
    return TranscriptionResult(
        text=transcript,
        success=True,
        message="Transcript supplied by local command",
        source="command",
    )


def _command_timeout_seconds() -> int:
    raw = os.environ.get("VIBE_STICK_TRANSCRIBE_TIMEOUT_SECONDS", "120")
    try:
        value = int(raw)
    except ValueError:
        return 120
    return max(5, min(600, value))


def _asr_timeout_seconds() -> int:
    raw = (
        os.environ.get("VIBE_STICK_ASR_TIMEOUT_SECONDS")
        or os.environ.get("VIBE_STICK_GROQ_TIMEOUT_SECONDS")
        or "15"
    )
    try:
        value = int(raw)
    except ValueError:
        return 15
    return max(3, min(60, value))


def _asr_attempt_count() -> int:
    raw = (
        os.environ.get("VIBE_STICK_ASR_ATTEMPTS")
        or os.environ.get("VIBE_STICK_GROQ_ATTEMPTS")
        or "2"
    )
    try:
        value = int(raw)
    except ValueError:
        return 2
    return max(1, min(5, value))


def _load_asr_config() -> dict[str, str]:
    mac_config = _load_mac_app_asr_config()
    if mac_config:
        return mac_config

    generic_env = _config_from_generic_env()
    if generic_env:
        return generic_env

    env_key = os.environ.get("VIBE_STICK_GROQ_API_KEY", "").strip()
    if env_key:
        return {
            "provider": "groq",
            "base_url": GROQ_ASR_BASE_URL,
            "api_key": env_key,
            "model": os.environ.get("VIBE_STICK_GROQ_MODEL", DEFAULT_ASR_MODEL).strip(),
            "language": os.environ.get("VIBE_STICK_GROQ_LANGUAGE", DEFAULT_ASR_LANGUAGE).strip(),
        }

    for path in _asr_config_paths():
        try:
            data = tomllib.loads(path.read_text())
        except (FileNotFoundError, OSError, tomllib.TOMLDecodeError):
            continue
        config = _config_from_toml(data)
        if config:
            return config
    return {}


def _config_from_generic_env() -> dict[str, str]:
    provider = _normalize_asr_provider(os.environ.get("VIBE_STICK_ASR_PROVIDER", ""))
    api_key = os.environ.get("VIBE_STICK_ASR_API_KEY", "").strip()
    base_url = os.environ.get("VIBE_STICK_ASR_BASE_URL", "").strip()
    model = os.environ.get("VIBE_STICK_ASR_MODEL", "").strip()
    language = os.environ.get("VIBE_STICK_ASR_LANGUAGE", "").strip()
    if not any((provider, api_key, base_url)):
        return {}
    if not provider:
        provider = "openai-compatible"
    if provider == "groq":
        api_key = api_key or os.environ.get("VIBE_STICK_GROQ_API_KEY", "").strip()
        base_url = base_url or GROQ_ASR_BASE_URL
        model = model or os.environ.get("VIBE_STICK_GROQ_MODEL", DEFAULT_ASR_MODEL).strip()
        language = language or os.environ.get("VIBE_STICK_GROQ_LANGUAGE", DEFAULT_ASR_LANGUAGE).strip()
    else:
        model = model or DEFAULT_ASR_MODEL
        language = language or DEFAULT_ASR_LANGUAGE
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key,
        model=model,
        language=language,
    )


def _config_from_toml(data: dict[str, Any]) -> dict[str, str]:
    provider = _normalize_asr_provider(data.get("asr_provider") or data.get("provider") or "")
    api_key = str(data.get("api_key") or "").strip()
    base_url = str(data.get("base_url") or "").strip()
    model = str(data.get("model") or "").strip()
    language = str(data.get("language") or "").strip()
    groq_api_key = str(data.get("groq_api_key") or "").strip()
    if not provider and (api_key or base_url):
        provider = "openai-compatible"
    if provider == "groq":
        api_key = groq_api_key or api_key
        base_url = base_url or GROQ_ASR_BASE_URL
        model = str(data.get("groq_model") or model or DEFAULT_ASR_MODEL).strip()
        language = str(data.get("groq_language") or language or DEFAULT_ASR_LANGUAGE).strip()
    elif provider == "openai-compatible":
        model = model or DEFAULT_ASR_MODEL
        language = language or DEFAULT_ASR_LANGUAGE
    else:
        return {}
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key,
        model=model,
        language=language,
    )


def _load_mac_app_asr_config() -> dict[str, str]:
    path = APP_SUPPORT_DIR / "config-v1.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict) or not isinstance(data.get("asr"), dict):
        return {}
    return _config_from_mac_app(data["asr"], keychain_reader=_keychain_asr_api_key)


def _config_from_mac_app(
    data: dict[str, Any],
    *,
    keychain_reader: Callable[[], str] | None = None,
) -> dict[str, str]:
    provider = _normalize_asr_provider(data.get("provider"))
    if provider == "local-command":
        command = str(data.get("localCommand") or "").strip()
        return {"provider": provider, "command": command} if command else {}
    if provider not in {"groq", "siliconflow", "openai-compatible"}:
        return {}
    base_url = str(data.get("baseURL") or "").strip()
    model = str(data.get("model") or "").strip()
    language = str(data.get("language") or "").strip()
    if provider == "groq":
        base_url = base_url or GROQ_ASR_BASE_URL
        model = model or DEFAULT_ASR_MODEL
    elif provider == "siliconflow":
        base_url = base_url or SILICONFLOW_ASR_BASE_URL
        model = model or "FunAudioLLM/SenseVoiceSmall"
    if not base_url or not model:
        return {}
    reader = keychain_reader or _keychain_asr_api_key
    api_key = "" if _is_loopback_url(base_url) else reader()
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key,
        model=model,
        language=language,
    )


def _config_from_managed_runtime(
    data: dict[str, Any],
    api_key: str,
) -> dict[str, str]:
    provider = _normalize_asr_provider(data.get("provider"))
    if provider == "local-command":
        command = str(data.get("localCommand") or "").strip()
        return {"provider": provider, "command": command} if command else {}
    if provider not in {"groq", "siliconflow", "openai-compatible"}:
        return {}
    base_url = str(data.get("baseURL") or "").strip()
    model = str(data.get("model") or "").strip()
    language = str(data.get("language") or "").strip()
    if not base_url or not model or not language:
        return {}
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key.strip(),
        model=model,
        language=language,
    )


def _without_secret(message: str, secret: str) -> str:
    value = secret.strip()
    return message.replace(value, "[redacted]") if value else message


def _asr_config(
    *,
    provider: str,
    base_url: str,
    api_key: str,
    model: str,
    language: str,
) -> dict[str, str]:
    return {
        "provider": provider,
        "base_url": base_url,
        "api_key": api_key,
        "model": model,
        "language": language,
    }


def _normalize_asr_provider(raw: object) -> str:
    value = str(raw or "").strip().lower()
    if value in {"groq", "siliconflow", "openai-compatible", "local-command"}:
        return value
    if value == "openai":
        return "openai-compatible"
    return ""


def _keychain_asr_api_key() -> str:
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ASR_ACCOUNT,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=KEYCHAIN_AUTHORIZATION_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def _is_loopback_url(value: str) -> bool:
    try:
        host = (urlparse(value).hostname or "").lower()
    except ValueError:
        return False
    return host in {"localhost", "127.0.0.1", "::1"}


def _asr_config_paths() -> list[Path]:
    return [
        APP_SUPPORT_DIR / "asr.toml",
        APP_SUPPORT_DIR / "config.toml",
    ]


def _transcribe_openai_compatible(audio_file: Path, config: dict[str, str]) -> TranscriptionResult:
    source = config.get("provider") or "openai-compatible"
    label = _asr_label(source)
    base_url = config.get("base_url", "")
    if not base_url or (not config.get("api_key") and not _is_loopback_url(base_url)):
        return TranscriptionResult(success=False, message="No transcription adapter configured", source="none")
    last_result = TranscriptionResult(success=False, message=f"{label} transcription failed", source=source)
    attempts = _asr_attempt_count()
    for attempt in range(1, attempts + 1):
        result = _transcribe_openai_compatible_once(audio_file, config, attempt)
        if result.success:
            return result
        last_result = result
        if attempt >= attempts or not _is_retryable_asr_error(result.message):
            return result
        time.sleep(min(2.0, 0.4 * attempt))
    return last_result


def _transcribe_openai_compatible_once(
    audio_file: Path,
    config: dict[str, str],
    attempt: int,
    opener=urllib.request.urlopen,  # noqa: ANN001
) -> TranscriptionResult:
    source = config.get("provider") or "openai-compatible"
    label = _asr_label(source)
    boundary = f"VibeStickASR-{uuid4().hex}"
    try:
        body = _multipart_body(
            boundary=boundary,
            audio_file=audio_file,
            provider=source,
            model=config.get("model") or DEFAULT_ASR_MODEL,
            language=config.get("language") or DEFAULT_ASR_LANGUAGE,
        )
    except OSError as exc:
        return TranscriptionResult(success=False, message=f"Could not read audio file: {exc}", source=source)

    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "VibeStick/0.1 macOS",
        "Connection": "close",
    }
    if api_key := config.get("api_key", ""):
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        _transcription_url(config.get("base_url", "")),
        data=body,
        method="POST",
        headers=headers,
    )
    try:
        with opener(request, timeout=_asr_timeout_seconds()) as response:
            response_data = response.read()
    except urllib.error.HTTPError as exc:
        _discard_http_error_body(exc)
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription failed on attempt {attempt}: HTTP {exc.code}",
            source=source,
        )
    except (OSError, TimeoutError) as exc:
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription failed on attempt {attempt}: {exc}",
            source=source,
        )

    try:
        payload = json.loads(response_data.decode("utf-8"))
    except json.JSONDecodeError:
        return TranscriptionResult(success=False, message=f"{label} returned unreadable JSON", source=source)
    text = str(payload.get("text") or "").strip()
    if not text:
        return TranscriptionResult(success=False, message=f"{label} returned no transcript", source=source)
    return TranscriptionResult(
        text=text,
        success=True,
        message=f"Transcript supplied by {label} ASR",
        source=source,
    )


def _transcription_url(base_url: str) -> str:
    cleaned = base_url.rstrip("/")
    if cleaned.endswith("/audio/transcriptions"):
        return cleaned
    return f"{cleaned}/audio/transcriptions"


def _asr_label(provider: str) -> str:
    if provider == "groq":
        return "Groq"
    if provider == "siliconflow":
        return "SiliconFlow"
    return "OpenAI-compatible"


def _discard_http_error_body(exc: urllib.error.HTTPError) -> None:
    try:
        exc.read()
    except OSError:
        pass


def _is_retryable_asr_error(message: str) -> bool:
    retryable_fragments = (
        "HTTP 408",
        "HTTP 409",
        "HTTP 425",
        "HTTP 429",
        "HTTP 500",
        "HTTP 502",
        "HTTP 503",
        "HTTP 504",
        "UNEXPECTED_EOF",
        "EOF occurred",
        "Remote end closed",
        "Connection reset",
        "Temporary failure",
        "timed out",
        "timeout",
        "SSL",
    )
    return any(fragment in message for fragment in retryable_fragments)


def _multipart_body(
    boundary: str,
    audio_file: Path,
    provider: str,
    model: str,
    language: str,
) -> bytes:
    body = bytearray()

    def add_field(name: str, value: str) -> None:
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode())
        body.extend(b"\r\n")

    add_field("model", model)
    if provider != "siliconflow":
        add_field("response_format", "json")
        add_field("temperature", "0")
        if language:
            add_field("language", language)

    body.extend(f"--{boundary}\r\n".encode())
    body.extend(
        f'Content-Disposition: form-data; name="file"; filename="{audio_file.name}"\r\n'.encode()
    )
    body.extend(f"Content-Type: {_content_type(audio_file)}\r\n\r\n".encode())
    body.extend(audio_file.read_bytes())
    body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode())
    return bytes(body)


def _content_type(audio_file: Path) -> str:
    suffix = audio_file.suffix.lower()
    if suffix == ".wav":
        return "audio/wav"
    if suffix == ".ogg":
        return "audio/ogg"
    if suffix == ".mp3":
        return "audio/mpeg"
    return "audio/mp4"
