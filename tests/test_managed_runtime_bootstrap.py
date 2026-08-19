from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick.audio import recorder, transcriber
from vibe_stick.config.managed_runtime import KEYCHAIN_SERVICE
from vibe_stick.config.runtime_bootstrap import (
    MacOSVersionedKeychainReader,
    ManagedRuntimeBootstrapError,
    ManagedRuntimeFileReader,
    load_runtime_configuration,
)
from vibe_stick.server import app


def _fixture_document() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "credentialReferences": [
            {
                "schemaVersion": 1,
                "purpose": "bridge-token",
                "storage": "macos-keychain",
                "service": KEYCHAIN_SERVICE,
                "account": "bridge-token-v1",
            },
            {
                "schemaVersion": 1,
                "purpose": "asr-api-key",
                "storage": "macos-keychain",
                "service": KEYCHAIN_SERVICE,
                "account": "asr-api-key-v1",
            },
        ],
        "asr": {
            "provider": "groq",
            "baseURL": "https://fixture.invalid/v1",
            "model": "fixture-model",
            "language": "zh",
            "localCommand": "",
        },
        "agentProvider": "claude",
        "projectPresentation": {
            "projectName": "Fictional Workspace",
            "showProjectName": True,
        },
        "voiceDelivery": {"sendMode": "confirm"},
        "soundEnabled": True,
    }


def _write_private(path: Path, document: object) -> None:
    path.write_text(json.dumps(document), encoding="utf-8")
    path.chmod(0o600)


class ManagedRuntimeBootstrapTests(unittest.TestCase):
    def test_missing_document_is_the_only_legacy_fallback_and_makes_zero_keychain_calls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            calls: list[tuple[str, str]] = []
            result = load_runtime_configuration(
                expected_mode="legacy",
                file_reader=ManagedRuntimeFileReader(Path(directory) / "missing.json"),
                credential_reader=lambda service, account: calls.append((service, account)) or "unused",
            )

        self.assertIsNone(result)
        self.assertEqual(calls, [])

    def test_valid_managed_document_resolves_only_fixed_accounts_without_mutating_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "managed-runtime-v1.json"
            _write_private(path, _fixture_document())
            calls: list[tuple[str, str]] = []
            secrets = {
                "bridge-token-v1": "fixture-managed-bridge-secret",
                "asr-api-key-v1": "fixture-managed-asr-secret",
            }
            environment_before = dict(os.environ)

            result = load_runtime_configuration(
                expected_mode="managed",
                file_reader=ManagedRuntimeFileReader(path),
                credential_reader=lambda service, account: calls.append((service, account))
                or secrets[account],
            )

        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.bridge_token, secrets["bridge-token-v1"])
        self.assertEqual(result.asr_api_key, secrets["asr-api-key-v1"])
        self.assertEqual(result.agent_provider, "claude")
        self.assertEqual(
            result.project_presentation,
            {"projectName": "Fictional Workspace", "showProjectName": True},
        )
        self.assertEqual(result.voice_delivery, {"sendMode": "confirm"})
        self.assertIs(result.sound_enabled, True)
        with mock.patch.dict(os.environ, {"VIBE_STICK_PROVIDER": "codex"}):
            self.assertEqual(app._managed_agent_provider(result), "claude")
        self.assertEqual(calls, [
            (KEYCHAIN_SERVICE, "bridge-token-v1"),
            (KEYCHAIN_SERVICE, "asr-api-key-v1"),
        ])
        self.assertEqual(dict(os.environ), environment_before)
        self.assertFalse(any(secret in os.environ.values() for secret in secrets.values()))

    def test_existing_invalid_document_never_falls_back_or_reads_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "managed-runtime-v1.json"
            document = _fixture_document()
            document["voiceDelivery"] = {"sendMode": "unsafe"}
            _write_private(path, document)
            calls: list[str] = []

            with self.assertRaisesRegex(
                ManagedRuntimeBootstrapError,
                "managed-runtime-unavailable",
            ) as raised:
                load_runtime_configuration(
                    file_reader=ManagedRuntimeFileReader(path),
                    credential_reader=lambda _service, account: calls.append(account)
                    or "fixture-secret-must-not-appear",
                )

        self.assertEqual(calls, [])
        self.assertNotIn("fixture-secret", str(raised.exception))
        self.assertNotIn(str(path), str(raised.exception))

    def test_missing_managed_credential_is_secret_free_and_never_uses_legacy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "managed-runtime-v1.json"
            _write_private(path, _fixture_document())
            bridge_secret = "fixture-bridge-secret-must-not-appear"

            with self.assertRaisesRegex(
                ManagedRuntimeBootstrapError,
                "managed-runtime-unavailable",
            ) as raised:
                load_runtime_configuration(
                    expected_mode="managed",
                    file_reader=ManagedRuntimeFileReader(path),
                    credential_reader=lambda _service, account: bridge_secret
                    if account == "bridge-token-v1"
                    else "",
                )

        self.assertNotIn(bridge_secret, str(raised.exception))

    def test_frozen_legacy_selection_rejects_a_newly_appeared_managed_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "managed-runtime-v1.json"
            _write_private(path, _fixture_document())

            with self.assertRaisesRegex(
                ManagedRuntimeBootstrapError,
                "runtime-selection-changed",
            ):
                load_runtime_configuration(
                    expected_mode="legacy",
                    file_reader=ManagedRuntimeFileReader(path),
                    credential_reader=lambda _service, _account: self.fail(
                        "credential reader must not run"
                    ),
                )

    def test_reader_rejects_overexposed_symlink_directory_and_oversized_input_before_keychain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = root / "valid.json"
            _write_private(valid, _fixture_document())
            overexposed = root / "overexposed.json"
            _write_private(overexposed, _fixture_document())
            overexposed.chmod(0o644)
            symbolic = root / "symbolic.json"
            symbolic.symlink_to(valid)
            directory_input = root / "directory.json"
            directory_input.mkdir()
            oversized = root / "oversized.json"
            oversized.write_bytes(b"x" * 65)
            oversized.chmod(0o600)
            calls: list[str] = []

            readers = [
                ManagedRuntimeFileReader(overexposed),
                ManagedRuntimeFileReader(symbolic),
                ManagedRuntimeFileReader(directory_input),
                ManagedRuntimeFileReader(oversized, maximum_bytes=64),
            ]
            for reader in readers:
                with self.subTest(path=reader.path.name):
                    with self.assertRaisesRegex(
                        ManagedRuntimeBootstrapError,
                        "managed-runtime-unavailable",
                    ):
                        load_runtime_configuration(
                            file_reader=reader,
                            credential_reader=lambda _service, account: calls.append(account)
                            or "must-not-read",
                        )

        self.assertEqual(calls, [])

    def test_keychain_adapter_uses_only_fixed_lookup_arguments_and_keeps_secret_out_of_command(self) -> None:
        calls: list[tuple[list[str], float]] = []
        secret = "fixture-keychain-secret"

        def runner(arguments: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
            calls.append((list(arguments), timeout))
            return subprocess.CompletedProcess(arguments, 0, stdout=secret + "\n", stderr="")

        reader = MacOSVersionedKeychainReader(runner=runner, timeout_seconds=7.0)
        self.assertEqual(reader(KEYCHAIN_SERVICE, "bridge-token-v1"), secret)
        self.assertEqual(calls, [(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                "bridge-token-v1",
                "-w",
            ],
            7.0,
        )])
        self.assertNotIn(secret, calls[0][0])

        with self.assertRaisesRegex(
            ManagedRuntimeBootstrapError,
            "managed-credential-unavailable",
        ):
            reader(KEYCHAIN_SERVICE, "bridge-token")
        self.assertEqual(len(calls), 1)

    def test_keychain_failure_does_not_expose_command_output(self) -> None:
        secret = "fixture-stderr-secret"
        reader = MacOSVersionedKeychainReader(
            runner=lambda arguments, _timeout: subprocess.CompletedProcess(
                arguments,
                44,
                stdout="",
                stderr=secret,
            )
        )

        with self.assertRaisesRegex(
            ManagedRuntimeBootstrapError,
            "managed-credential-unavailable",
        ) as raised:
            reader(KEYCHAIN_SERVICE, "asr-api-key-v1")

        self.assertNotIn(secret, str(raised.exception))

    def test_managed_asr_send_mode_and_bridge_token_ignore_legacy_environment(self) -> None:
        managed_asr = {
            "provider": "local-command",
            "baseURL": "",
            "model": "",
            "language": "zh",
            "localCommand": "/fixture/managed-transcriber",
        }
        with mock.patch.dict(
            os.environ,
            {
                "VIBE_STICK_TRANSCRIBE_CMD": "/fixture/legacy-transcriber",
                "VIBE_STICK_SEND_MODE": "auto_send",
                "VIBE_STICK_BRIDGE_TOKEN": "legacy-token",
            },
            clear=True,
        ):
            adapter = transcriber.TranscriptionAdapter(managed_asr=managed_asr)
            with mock.patch.object(
                transcriber,
                "_transcribe_with_command",
                return_value=transcriber.TranscriptionResult(success=True, source="command"),
            ) as command:
                result = adapter.transcribe({"audio_file": "/fixture/not-read"})

            self.assertTrue(result.success)
            command.assert_called_once_with("/fixture/managed-transcriber", {"audio_file": "/fixture/not-read"})
            self.assertEqual(
                recorder._configured_send_mode(2, managed_send_mode="confirm"),
                "confirm",
            )
            self.assertEqual(app._bridge_token("managed-token"), "managed-token")

    def test_managed_cloud_asr_does_not_read_legacy_config_and_redacts_secret_errors(self) -> None:
        managed_asr = {
            "provider": "openai-compatible",
            "baseURL": "https://fixture.invalid/v1",
            "model": "fixture-model",
            "language": "zh",
            "localCommand": "",
        }
        secret = "fixture-managed-asr-secret"
        adapter = transcriber.TranscriptionAdapter(
            managed_asr=managed_asr,
            managed_asr_api_key=secret,
        )
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "fixture.wav"
            audio.write_bytes(b"fictional-audio")
            with mock.patch.object(
                transcriber,
                "_load_asr_config",
                side_effect=AssertionError("legacy ASR configuration must not be read"),
            ), mock.patch.object(
                transcriber,
                "_transcribe_openai_compatible",
                return_value=transcriber.TranscriptionResult(
                    success=False,
                    message=f"simulated provider failure {secret}",
                    source="openai-compatible",
                ),
            ) as cloud:
                result = adapter.transcribe({"audio_file": str(audio)})

        self.assertFalse(result.success)
        self.assertNotIn(secret, result.message)
        cloud.assert_called_once()

    def test_bridge_main_fails_closed_with_fixed_text_before_server_start(self) -> None:
        underlying = "fixture-secret-must-not-appear"
        with mock.patch.object(
            app,
            "load_runtime_configuration",
            side_effect=ManagedRuntimeBootstrapError(underlying),
        ), mock.patch.object(app, "run_server") as run_server:
            with self.assertRaises(SystemExit) as raised:
                app.main(["--host", "127.0.0.1", "--port", "9876"])

        self.assertEqual(
            str(raised.exception),
            "VibeStick Bridge: managed runtime configuration is unavailable",
        )
        self.assertNotIn(underlying, str(raised.exception))
        run_server.assert_not_called()


if __name__ == "__main__":
    unittest.main()
