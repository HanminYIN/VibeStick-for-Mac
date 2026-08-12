import unittest

from vibe_stick.protocol.state import AgentStatus, ProviderState, default_state, state_from_dict


class ProtocolStateTests(unittest.TestCase):
    def test_bridge_state_never_serializes_remote_battery(self) -> None:
        state = state_from_dict(
            {
                "wifi": True,
                "battery": 82,
                "codex": {"status": "RUNNING", "project": "VibeStick"},
                "alert": {"type": "NONE"},
            }
        )

        self.assertIsNone(state.to_jsonable()["battery"])

    def test_legacy_codex_block_populates_generic_provider(self) -> None:
        state = state_from_dict(
            {
                "codex": {
                    "status": "RUNNING",
                    "project": "VibeStick",
                    "quota_5h_remaining": 66,
                    "quota_7d_remaining": 96,
                    "quota_updated_at": "09:38",
                }
            }
        )

        payload = state.to_jsonable()
        self.assertEqual(payload["active_provider"], "codex")
        self.assertEqual(payload["provider"]["id"], "codex")
        self.assertEqual(payload["provider"]["status"], "RUNNING")
        self.assertEqual(payload["provider"]["quota_5h_remaining"], 66)
        self.assertEqual(payload["codex"]["status"], "RUNNING")

    def test_generic_provider_block_serializes_status_string(self) -> None:
        state = default_state()
        state.active_provider = "claude"
        state.provider = ProviderState(
            id="claude",
            display_name="Claude",
            implemented=True,
            status=AgentStatus.ERROR,
            project="VibeStick",
            quota_5h_remaining=None,
            quota_7d_remaining=None,
            quota_updated_at="",
            quota_stale=False,
        )

        payload = state.to_jsonable()

        self.assertEqual(payload["active_provider"], "claude")
        self.assertEqual(payload["provider"]["id"], "claude")
        self.assertEqual(payload["provider"]["status"], "ERROR")

    def test_dynamic_quota_windows_are_emitted_with_legacy_fields(self) -> None:
        state = state_from_dict(
            {
                "codex": {
                    "status": "RUNNING",
                    "project": "VibeStick",
                    "quota_5h_remaining": 64,
                    "quota_7d_remaining": 91,
                    "quota_updated_at": "09:38",
                    "quota_stale": False,
                }
            }
        )

        provider = state.to_jsonable()["provider"]
        self.assertEqual(provider["quota_5h_remaining"], 64)
        self.assertEqual(provider["quota_7d_remaining"], 91)
        self.assertEqual(
            provider["quota_windows"],
            [
                {
                    "id": "5h",
                    "label": "5H",
                    "remaining_percent": 64,
                    "updated_at": "09:38",
                    "stale": False,
                },
                {
                    "id": "7d",
                    "label": "7D",
                    "remaining_percent": 91,
                    "updated_at": "09:38",
                    "stale": False,
                },
            ],
        )

    def test_dynamic_quota_windows_omit_unknown_legacy_slots(self) -> None:
        state = state_from_dict(
            {
                "codex": {
                    "status": "RUNNING",
                    "quota_5h_remaining": None,
                    "quota_7d_remaining": 97,
                    "quota_updated_at": "04:02",
                }
            }
        )

        windows = state.to_jsonable()["provider"]["quota_windows"]
        self.assertEqual([window["id"] for window in windows], ["7d"])
        self.assertEqual(windows[0]["remaining_percent"], 97)


if __name__ == "__main__":
    unittest.main()
