import os
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick.audio import transcriber


class _FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc: object) -> bool:
        return False

    def read(self) -> bytes:
        return self._body


class TranscriberConfigTests(unittest.TestCase):
    def test_load_asr_config_reads_vibestick_asr_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "groq"',
                        'groq_api_key = "local-key"',
                        'groq_model = "whisper-large-v3-turbo"',
                        'groq_language = "zh"',
                    ]
                )
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "groq")
        self.assertEqual(config["base_url"], "https://api.groq.com/openai/v1")
        self.assertEqual(config["api_key"], "local-key")
        self.assertEqual(config["model"], "whisper-large-v3-turbo")
        self.assertEqual(config["language"], "zh")

    def test_environment_api_key_takes_precedence_over_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "config.toml").write_text(
                'asr_provider = "groq"\ngroq_api_key = "local-key"\n'
            )

            with mock.patch.dict(os.environ, {"VIBE_STICK_GROQ_API_KEY": "env-key"}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["api_key"], "env-key")

    def test_groq_key_without_generic_provider_uses_groq_preset(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "VIBE_STICK_GROQ_API_KEY": "env-key",
                "VIBE_STICK_ASR_PROVIDER": "",
                "VIBE_STICK_ASR_MODEL": transcriber.DEFAULT_ASR_MODEL,
            },
            clear=True,
        ):
            with mock.patch.object(transcriber, "APP_SUPPORT_DIR", Path("/tmp/does-not-exist-vibestick")):
                config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "groq")
        self.assertEqual(config["api_key"], "env-key")
        self.assertEqual(config["base_url"], transcriber.GROQ_ASR_BASE_URL)

    def test_openai_compatible_toml_config_parses_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "openai-compatible"',
                        'base_url = "https://asr.example.test/openai/v1/"',
                        'api_key = "local-key"',
                        'model = "whisper-test"',
                        'language = "en"',
                    ]
                )
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "openai-compatible")
        self.assertEqual(config["base_url"], "https://asr.example.test/openai/v1/")
        self.assertEqual(config["api_key"], "local-key")
        self.assertEqual(config["model"], "whisper-test")
        self.assertEqual(config["language"], "en")

    def test_mac_app_config_reads_provider_and_keychain_without_plaintext_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_support = Path(tmp) / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "config-v1.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "asr": {
                            "provider": "groq",
                            "baseURL": "https://api.groq.com/openai/v1",
                            "model": "whisper-large-v3-turbo",
                            "language": "zh",
                            "localCommand": "",
                        },
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    with mock.patch.object(transcriber, "_keychain_asr_api_key", return_value="keychain-key"):
                        config = transcriber._load_asr_config()
            persisted = (app_support / "config-v1.json").read_text(encoding="utf-8")

        self.assertEqual(config["provider"], "groq")
        self.assertEqual(config["api_key"], "keychain-key")
        self.assertNotIn("keychain-key", persisted)

    def test_explicit_mac_app_config_takes_precedence_over_legacy_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_support = Path(tmp) / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "config-v1.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "asr": {
                            "provider": "siliconflow",
                            "baseURL": "https://api.siliconflow.cn/v1",
                            "model": "FunAudioLLM/SenseVoiceSmall",
                            "language": "zh",
                            "localCommand": "",
                        },
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.dict(
                os.environ,
                {
                    "VIBE_STICK_ASR_PROVIDER": "groq",
                    "VIBE_STICK_ASR_API_KEY": "legacy-key",
                    "VIBE_STICK_ASR_BASE_URL": transcriber.GROQ_ASR_BASE_URL,
                },
                clear=True,
            ):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    with mock.patch.object(transcriber, "_keychain_asr_api_key", return_value="native-key"):
                        config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "siliconflow")
        self.assertEqual(config["api_key"], "native-key")

    def test_mac_app_local_command_config_does_not_read_keychain(self) -> None:
        reader = mock.Mock(return_value="must-not-be-read")
        config = transcriber._config_from_mac_app(
            {
                "provider": "local-command",
                "localCommand": "/usr/local/bin/transcribe-test",
            },
            keychain_reader=reader,
        )

        self.assertEqual(config, {
            "provider": "local-command",
            "command": "/usr/local/bin/transcribe-test",
        })
        reader.assert_not_called()

    def test_siliconflow_mac_config_uses_current_official_preset(self) -> None:
        config = transcriber._config_from_mac_app(
            {
                "provider": "siliconflow",
                "baseURL": "",
                "model": "",
                "language": "zh",
            },
            keychain_reader=lambda: "keychain-key",
        )

        self.assertEqual(config["base_url"], transcriber.SILICONFLOW_ASR_BASE_URL)
        self.assertEqual(config["model"], "FunAudioLLM/SenseVoiceSmall")
        self.assertEqual(config["api_key"], "keychain-key")

    def test_openai_compatible_url_joins_trailing_slash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            seen: dict[str, str] = {}

            def opener(request, timeout=None):  # noqa: ANN001
                seen["url"] = request.full_url
                seen["authorization"] = request.headers.get("Authorization", "")
                return _FakeResponse(b'{"text":"hello"}')

            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "openai-compatible",
                    "base_url": "https://asr.example.test/openai/v1/",
                    "api_key": "secret-key",
                    "model": "whisper-test",
                    "language": "en",
                },
                attempt=1,
                opener=opener,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.source, "openai-compatible")
        self.assertEqual(seen["url"], "https://asr.example.test/openai/v1/audio/transcriptions")
        self.assertEqual(seen["authorization"], "Bearer secret-key")

    def test_legacy_groq_config_uses_openai_compatible_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            seen: dict[str, str] = {}

            def opener(request, timeout=None):  # noqa: ANN001
                seen["url"] = request.full_url
                return _FakeResponse(b'{"text":"hello"}')

            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "groq",
                    "base_url": transcriber.GROQ_ASR_BASE_URL,
                    "api_key": "secret-key",
                    "model": "whisper-large-v3-turbo",
                    "language": "zh",
                },
                attempt=1,
                opener=opener,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.source, "groq")
        self.assertEqual(seen["url"], "https://api.groq.com/openai/v1/audio/transcriptions")

    def test_complete_transcription_url_is_not_appended_twice(self) -> None:
        self.assertEqual(
            transcriber._transcription_url("https://asr.example.test/v1/audio/transcriptions"),
            "https://asr.example.test/v1/audio/transcriptions",
        )

    def test_missing_openai_compatible_key_fails_gracefully(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "openai-compatible"',
                        'base_url = "https://asr.example.test/openai/v1"',
                    ]
                )
            )
            audio = root / "sample.wav"
            audio.write_bytes(b"RIFFtest")

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    result = transcriber.TranscriptionAdapter().transcribe({"audio_file": str(audio)})

        self.assertFalse(result.success)
        self.assertEqual(result.source, "none")
        self.assertEqual(result.message, "No transcription adapter configured")

    def test_loopback_openai_compatible_endpoint_does_not_require_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            seen: dict[str, str | None] = {}

            def opener(request, timeout=None):  # noqa: ANN001
                seen["url"] = request.full_url
                seen["authorization"] = request.headers.get("Authorization")
                return _FakeResponse(b'{"text":"local hello"}')

            config = {
                "provider": "openai-compatible",
                "base_url": "http://127.0.0.1:8080/v1",
                "api_key": "",
                "model": "local-whisper",
                "language": "zh",
            }
            transcribe_once = transcriber._transcribe_openai_compatible_once
            with mock.patch.object(
                transcriber,
                "_transcribe_openai_compatible_once",
                wraps=lambda audio_file, current_config, attempt: transcribe_once(
                    audio_file,
                    current_config,
                    attempt,
                    opener=opener,
                ),
            ):
                result = transcriber._transcribe_openai_compatible(audio, config)

        self.assertTrue(result.success)
        self.assertEqual(result.text, "local hello")
        self.assertEqual(seen["url"], "http://127.0.0.1:8080/v1/audio/transcriptions")
        self.assertIsNone(seen["authorization"])


if __name__ == "__main__":
    unittest.main()
