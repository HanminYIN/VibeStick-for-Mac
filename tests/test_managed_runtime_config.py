import json
import unittest

from vibe_stick.config.managed_runtime import (
    KEYCHAIN_SERVICE,
    ManagedRuntimeConfigurationError,
    parse_managed_runtime_configuration,
)


def _fixture_document() -> dict:
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
            "baseURL": "https://api.groq.com/openai/v1",
            "model": "whisper-large-v3-turbo",
            "language": "zh",
            "localCommand": "",
        },
        "agentProvider": "auto",
        "projectPresentation": {
            "projectName": "Fictional Workspace",
            "showProjectName": True,
        },
        "voiceDelivery": {"sendMode": "confirm"},
        "soundEnabled": True,
    }


class ManagedRuntimeConfigurationTests(unittest.TestCase):
    def test_resolves_only_fixed_versioned_accounts_through_injected_reader(self) -> None:
        calls: list[tuple[str, str]] = []

        def reader(service: str, account: str) -> str:
            calls.append((service, account))
            return {"bridge-token-v1": "fixture-bridge", "asr-api-key-v1": "fixture-asr"}[account]

        result = parse_managed_runtime_configuration(
            json.dumps(_fixture_document()),
            credential_reader=reader,
        )

        self.assertEqual(result.bridge_token, "fixture-bridge")
        self.assertEqual(result.asr_api_key, "fixture-asr")
        self.assertEqual(result.agent_provider, "auto")
        self.assertEqual(
            result.project_presentation,
            {"projectName": "Fictional Workspace", "showProjectName": True},
        )
        self.assertEqual(result.voice_delivery, {"sendMode": "confirm"})
        self.assertIs(result.sound_enabled, True)
        self.assertEqual(calls, [
            (KEYCHAIN_SERVICE, "bridge-token-v1"),
            (KEYCHAIN_SERVICE, "asr-api-key-v1"),
        ])

    def test_rejects_legacy_or_arbitrary_credential_accounts(self) -> None:
        document = _fixture_document()
        document["credentialReferences"][0]["account"] = "bridge-token"

        with self.assertRaisesRegex(ManagedRuntimeConfigurationError, "invalid-credential-reference"):
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, _account: "must-not-resolve",
            )

    def test_local_command_does_not_request_asr_credential(self) -> None:
        document = _fixture_document()
        document["credentialReferences"] = document["credentialReferences"][:1]
        document["asr"] = {
            "provider": "local-command",
            "baseURL": "",
            "model": "",
            "language": "zh",
            "localCommand": "/fixture/transcribe",
        }
        calls: list[str] = []

        result = parse_managed_runtime_configuration(
            json.dumps(document),
            credential_reader=lambda _service, account: calls.append(account) or "fixture",
        )

        self.assertEqual(result.asr_api_key, "")
        self.assertEqual(calls, ["bridge-token-v1"])

    def test_missing_cloud_asr_credential_fails_closed(self) -> None:
        document = _fixture_document()
        document["credentialReferences"] = document["credentialReferences"][:1]

        with self.assertRaisesRegex(ManagedRuntimeConfigurationError, "missing-asr-credential"):
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, _account: "fixture-bridge",
            )

    def test_missing_bridge_credential_fails_closed_before_asr_resolution(self) -> None:
        document = _fixture_document()
        document["credentialReferences"] = document["credentialReferences"][1:]
        calls: list[str] = []

        with self.assertRaisesRegex(ManagedRuntimeConfigurationError, "missing-bridge-credential"):
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, account: calls.append(account) or "fixture",
            )

        self.assertEqual(calls, [])

    def test_placeholder_managed_bridge_credential_fails_closed(self) -> None:
        document = _fixture_document()
        calls: list[str] = []

        with self.assertRaisesRegex(ManagedRuntimeConfigurationError, "missing-bridge-credential"):
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, account: calls.append(account)
                or (
                    "change-this-shared-token"
                    if account == "bridge-token-v1"
                    else "must-not-read-asr"
                ),
            )

        self.assertEqual(calls, ["bridge-token-v1"])

    def test_error_text_never_contains_resolved_secret(self) -> None:
        document = _fixture_document()
        document["voiceDelivery"] = {"sendMode": "unsafe-mode"}
        secret = "fixture-secret-must-not-appear"

        with self.assertRaises(ManagedRuntimeConfigurationError) as raised:
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, _account: secret,
            )

        self.assertNotIn(secret, str(raised.exception))

    def test_invalid_project_presentation_fails_before_credentials_are_read(self) -> None:
        document = _fixture_document()
        document["projectPresentation"] = {
            "projectName": "Fictional Workspace",
            "showProjectName": "yes",
        }
        calls: list[str] = []

        with self.assertRaisesRegex(
            ManagedRuntimeConfigurationError,
            "invalid-project-presentation",
        ):
            parse_managed_runtime_configuration(
                json.dumps(document),
                credential_reader=lambda _service, account: calls.append(account) or "fixture",
            )

        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
