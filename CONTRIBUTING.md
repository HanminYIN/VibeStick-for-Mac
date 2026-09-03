# Contributing to VibeStick for Mac

Thanks for your interest! VibeStick for Mac is an independently maintained derivative of
Gary Zhang's VibeStick and remains an early-preview project. Bug reports, ideas, and pull
requests are welcome.

## Project layout

- `firmware/sticks3/` — ESP32-S3 firmware (C, ESP-IDF v5.5.x)
- `app/macos/VibeStickApp/` — native SwiftUI control center
- `app/macos/VibeStickBridge/`, `VibeStickHUD/`, `VibeStickPaste/` — native
  end-user runtime shipped in the App and DMG
- `bridge/` — retained Python reference and compatibility testbed (standard
  library only), not an end-user runtime dependency
- `scripts/`, `docs/`

## Dev setup & checks

Bridge (Python 3.11+):

```sh
python3 -m compileall -q bridge/src tests
PYTHONPATH=bridge/src python3 -m unittest discover -s tests
```

Firmware: install ESP-IDF v5.5.x (see README), then `cd firmware/sticks3 && idf.py build`.
Run the host-side firmware diagnostics contract with
`scripts/test-firmware-network-diagnostics.sh`.
Verify the tracked release payload against the source revision pinned in its
manifest with `scripts/verify-tracked-release-firmware.sh`.
CI runs the Bridge, firmware host, and Swift hostless checks on every push / PR.

## Where to help

- Start with the [public roadmap](docs/ROADMAP.md) and
  [open issues](https://github.com/HanminYIN/VibeStick-for-Mac/issues).
- Issues labelled [`good first issue`](https://github.com/HanminYIN/VibeStick-for-Mac/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
  are intentionally bounded for a first contribution.
- Issues labelled [`help wanted`](https://github.com/HanminYIN/VibeStick-for-Mac/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
  need external hardware, platform, documentation, or security-review help.
- Open an issue before a substantial design change so the product and safety
  boundaries can be agreed before implementation.

## Guidelines

- No third-party Python dependencies — the bridge uses only the standard library; keep it that way.
- Never commit secrets — keep keys/tokens/Wi-Fi creds in the gitignored `.env` and
  `vibe_stick_secrets.h`; don't log tokens or raw API responses.
- Match the surrounding code style; add/update tests for behavior changes.
- Don't change provider icons / generated assets without discussion.

## Pull requests

1. Fork and create a branch.
2. Make focused commits with clear messages.
3. Ensure the checks above pass.
4. Open a PR describing what changed, why, its safety impact, and how it was
   verified. The pull-request template provides the expected checklist.

## Issues

- Bugs / features: open a GitHub issue.
- Security: see SECURITY.md — report privately.

By contributing, you agree your contributions are licensed under the project's MIT License.
