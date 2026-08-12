import json
import tempfile
import unittest
from pathlib import Path

from vibe_stick.codex.quota import QuotaSnapshot, load_quota, save_quota


class QuotaTests(unittest.TestCase):
    def test_load_quota_clamps_percentages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            path.write_text(
                json.dumps(
                    {
                        "quota_5h_remaining": 150,
                        "quota_7d_remaining": -20,
                        "quota_updated_at": "12:00",
                    }
                )
            )

            quota = load_quota(path)

        self.assertEqual(quota.quota_5h_remaining, 100)
        self.assertEqual(quota.quota_7d_remaining, 0)
        self.assertEqual(quota.quota_updated_at, "12:00")

    def test_save_and_load_quota_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            save_quota(
                path,
                QuotaSnapshot(
                    53,
                    93,
                    "13:01",
                    False,
                    "codex-app-server",
                    1_786_520_460.0,
                ),
            )
            quota = load_quota(path)

        self.assertEqual(
            quota,
            QuotaSnapshot(53, 93, "13:01", False, "codex-app-server", 1_786_520_460.0),
        )


if __name__ == "__main__":
    unittest.main()
