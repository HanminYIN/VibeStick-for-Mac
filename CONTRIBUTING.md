# Contributing to VibeStick for Mac

Thanks for your interest! VibeStick for Mac is an independently maintained derivative of
Gary Zhang's VibeStick and remains an early-preview project. Bug reports, ideas, and pull
requests are welcome.

## Project layout
- `firmware/sticks3/` — ESP32-S3 firmware (C, ESP-IDF v5.5.x)
- `bridge/` — local macOS bridge service (Python, standard library only)
- `app/macos/VibeStickApp/` — native SwiftUI control center
- `app/macos/VibeStickBridge/`, `VibeStickHUD/`, `VibeStickPaste/` — compatible native helpers
- `scripts/`, `docs/`

## Dev setup & checks
Bridge (Python 3.11+):
    python3 -m compileall -q bridge/src tests
    PYTHONPATH=bridge/src python3 -m unittest discover -s tests
Firmware: install ESP-IDF v5.5.x (see README), then `cd firmware/sticks3 && idf.py build`.
CI runs the bridge checks on every push / PR.

## Guidelines
- No third-party Python dependencies — the bridge uses only the standard library; keep it that way.
- Never commit secrets — keep keys/tokens/Wi-Fi creds in the gitignored `.env` and
  `vibe_stick_secrets.h`; don't log tokens or raw API responses.
- Match the surrounding code style; add/update tests for behavior changes.
- Don't change provider icons / generated assets without discussion.

## Pull requests
1. Fork and create a branch. 2. Make focused commits with clear messages.
3. Ensure the checks above pass. 4. Open a PR describing what changed and why.

## Issues
- Bugs / features: open a GitHub issue.
- Security: see SECURITY.md — report privately.

By contributing, you agree your contributions are licensed under the project's MIT License.
