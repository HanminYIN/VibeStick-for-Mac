# Changelog

## v0.2.0-m1 (unreleased)

M1 development checkpoint for the independently maintained VibeStick for Mac derivative.

### Added

- Native SwiftUI control center for Apple Silicon and macOS 15 or newer.
- Sidebar, dashboard, menu bar control, preferences, structured service health, and explicit Bridge/HUD lifecycle actions.
- Branded macOS AppIcon and 18 pt template menu bar icon.
- Development DMG build and verification workflow for an existing stable VibeStick installation.
- Hostless Swift tests, responsive-launch smoke tests, Mach-O deployment-target checks, signature checks, and distribution privacy scanning.
- Redacted legacy-configuration summaries and a private, atomic preference store with a Keychain migration boundary.

### Changed

- Standardized the installed names and identities of VibeStick Bridge, HUD, and Paste.
- Aligned Paste permission checks with the real LaunchServices invocation path.
- Refined diagnostics, service readiness, recording protection, and user-facing recovery language.
- Distinguished user-initiated Codex tasks from internal subagents and Guardian sessions.
- Kept the global device state running when another user task remains active, while emitting one completion event for each completed user task.

### Fixed

- SwiftUI menu bar binding feedback loop that could freeze the app at launch.
- False Accessibility warnings caused by attributing a Paste check to the main app.
- Short-lived false completion sounds and DONE screens caused by internal task completion events.
- Mismatched card heights, generic app/menu bar icons, unclear diagnostic labels, and configuration-summary visual hierarchy.

### Validation

- 81 Python tests and 14 hostless Swift tests pass.
- `scripts/doctor.sh`: 16 PASS, 0 WARN, 0 FAIL in the normal macOS user session.
- Main app, helper compatibility targets, signatures, arm64/macOS 15 load commands, AppIcon, menu bar asset, responsive launch, privacy boundary, and mounted DMG all pass `scripts/verify-macos-build.sh`.
- User acceptance covers DMG installation, startup, permissions, Bridge/HUD stop-start-restart, real StickS3 voice input, menu bar/window lifecycle, settings persistence, and core visual checks.

This checkpoint does not yet include clean-machine installation, pairing, configuration sync, new firmware UI, one-click flashing, or smart approval.

## v0.1.4

Initial public release of VibeStick — a tiny desktop companion for coding agents on M5Stack StickS3.

- Home screen shows Codex and Claude providers with live status (running / idle / done / approval / error / offline) and independent 5-hour / 7-day usage bars.
- Opt-in real Claude Code subscription usage (5H / 7D) via an undocumented Anthropic endpoint using local credentials; disabled by default, and the token / raw responses are never logged.
- Push-to-talk voice input: record on the StickS3, transcribe via any OpenAI-compatible ASR (e.g. SiliconFlow), and paste into the focused app; a local-command / fully-offline path is also supported.
- Alerts (done / approval / error) play from whichever provider raises them, on the StickS3 speaker.
- First-run helpers (`scripts/setup.sh`, `scripts/doctor.sh`), bridge token authentication, and a bilingual README (English + 中文) with clearly-marked physical steps.

Licensed under MIT.
