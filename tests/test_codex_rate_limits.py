import unittest
from datetime import datetime, timezone

from vibe_stick.codex.rate_limits import quota_from_rate_limits_result


class CodexRateLimitsTests(unittest.TestCase):
    def test_prefers_account_wide_codex_bucket(self) -> None:
        result = {
            "rateLimits": {
                "limitId": "codex_bengalfox",
                "primary": {"usedPercent": 0, "windowDurationMins": 10080},
            },
            "rateLimitsByLimitId": {
                "codex_bengalfox": {
                    "limitId": "codex_bengalfox",
                    "primary": {"usedPercent": 0, "windowDurationMins": 10080},
                },
                "codex": {
                    "limitId": "codex",
                    "primary": {"usedPercent": 7, "windowDurationMins": 10080},
                },
            },
        }
        observed_at = datetime(2026, 8, 12, 8, 15, tzinfo=timezone.utc)

        quota = quota_from_rate_limits_result(result, observed_at=observed_at)

        self.assertIsNotNone(quota)
        self.assertEqual(quota.quota_7d_remaining, 93)
        self.assertIsNone(quota.quota_5h_remaining)
        self.assertEqual(quota.quota_source, "codex-app-server")
        self.assertEqual(quota.quota_observed_at_epoch, observed_at.timestamp())

    def test_maps_account_windows_by_duration(self) -> None:
        result = {
            "rateLimitsByLimitId": {
                "codex": {
                    "primary": {"usedPercent": 18, "windowDurationMins": 300},
                    "secondary": {"usedPercent": 7, "windowDurationMins": 10080},
                }
            }
        }

        quota = quota_from_rate_limits_result(result)

        self.assertIsNotNone(quota)
        self.assertEqual(quota.quota_5h_remaining, 82)
        self.assertEqual(quota.quota_7d_remaining, 93)

    def test_does_not_substitute_model_bucket_for_account_bucket(self) -> None:
        result = {
            "rateLimits": {
                "limitId": "codex_bengalfox",
                "primary": {"usedPercent": 0, "windowDurationMins": 10080},
            },
            "rateLimitsByLimitId": {
                "codex_bengalfox": {
                    "primary": {"usedPercent": 0, "windowDurationMins": 10080},
                }
            },
        }

        self.assertIsNone(quota_from_rate_limits_result(result))

    def test_invalid_response_is_ignored(self) -> None:
        self.assertIsNone(quota_from_rate_limits_result(None))
        self.assertIsNone(quota_from_rate_limits_result({"rateLimitsByLimitId": {"codex": {}}}))


if __name__ == "__main__":
    unittest.main()
