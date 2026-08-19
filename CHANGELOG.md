# Changelog

## v0.2.0-rc.1 (release candidate)

First GitHub pre-release candidate for VibeStick for Mac. The App version is
`0.2.0 (10)` and supports Apple Silicon Macs running macOS 15 or newer.

### Added

- A fully native Swift Bridge for state observation, account-wide Codex quota,
  opt-in Claude quota, device pairing/configuration, voice recording, OpenAI-compatible or local
  ASR, HUD state, Paste delivery, and Bonjour/HTTP protocol v2.
- A native Swift runtime-payload manifest generator and verifier.
- Offline project, font, firmware-component, C runtime, and GCC runtime license
  notices inside the App bundle.
- Bilingual RC installation, privacy, recovery, and known-limitations notes.

### Changed

- The distributed App now contains only native arm64 Bridge/HUD/Paste
  components. It neither bundles Python source nor searches for Homebrew,
  Xcode, `/usr/bin/python3`, or another external interpreter at install time.
- Runtime upgrades remove the old Python runtime from the active support path
  while preserving it in the transaction rollback backup.
- The source developer installer and `dev.sh` build the native Bridge target.
- The main App and all three helpers share version `0.2.0 (10)` and a macOS
  15.0 minimum.
- The Bridge health route now bypasses serialized provider/session observation,
  so App state refreshes cannot starve installation or liveness checks; all
  state-changing routes remain ordered.
- The App and Bridge declare Local Network and `_vibestick._tcp` Bonjour use,
  while legacy LaunchAgents associate their network access with the main App.
- Firmware payload builds reuse a previously validated source identity or an
  explicitly supplied audited identity; release scripts do not inspect Git.

### Security and privacy

- Managed configuration remains fail-closed: a present but invalid managed
  document never falls back to legacy `.env` credentials.
- Bridge and ASR secrets remain in fixed Keychain accounts; recordings and
  transcripts are not persisted in provider state or diagnostic output.
- Managed startup uses the fixed Apple `/usr/bin/security` client already
  covered by the Keychain item ACL and reports only bounded failure categories.
- Diagnostic preview and local export remain separate explicit actions, with
  no upload or telemetry. Absolute and home-relative local paths are fully
  redacted, including roots and names containing spaces or punctuation.
- Firmware download, preparation, USB access, backup, write, verification, and
  recovery remain separate confirmation gates.

### Known RC limitations

- The candidate is ad-hoc signed, not Developer ID signed or notarized. macOS
  may require Control-click → Open and a Local Network confirmation on first
  launch. A stable Developer ID identity remains preferable before public
  distribution.
- A second clean Mac or external clean boot environment was unavailable, so
  clean-machine first-install and rollback acceptance remains unexecuted, not
  passed.
- Intel Macs and macOS 14 or older are unsupported.

### Publication

- Published as
  [GitHub Pre-release v0.2.0-rc.1](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.1)
  on 2026-08-19.
- The tag points to `a4b59536b432de41f881a20385d941fda10c3a33`; the DMG was
  built from `5479663a32273f6314de5cb5f0cd8d8f27332a2a`. Product source
  paths are unchanged between those commits; the intervening changes are
  documentation and CI only.
- The published 3,546,855-byte asset retains SHA-256
  `9117578032af78fcd5f2ec723983b460daf5c4b9ebd0d7d009c6e7da411600e8`.

### Validation

- Native Bridge behavior is covered with injected tests for protocol routing,
  persistence, provider observation, quota transport, ASR, voice delivery,
  production configuration, and runtime installation/rollback.
- 270 hostless Swift tests in 21 suites and 194 retained Python compatibility
  tests pass.
- The trusted M4-5K firmware payload and its audited notices are tracked release
  inputs, so a clean source/tag snapshot no longer depends on ignored build or
  ESP-IDF directories. CI Python and `macos-15` arm64 Swift jobs pass at
  `5479663`.
- The final 3,546,855-byte DMG has SHA-256
  `9117578032af78fcd5f2ec723983b460daf5c4b9ebd0d7d009c6e7da411600e8`.
- The earlier authorized local upgrade used predecessor candidate
  `6cd183a4c65cfc6eab632ff401fb67316d11e38e1b180dd65d1ea103f282599c`,
  installed payload `0.2.0-rc.1-native`, preserved Paste identity, and passed
  40/40 Bridge health probes while the main App performed three forced state
  refreshes. The final candidate was not installed or launched.
- Architectures, minimum OS, versions, signatures, manifests, licenses,
  forbidden-file boundaries, trusted firmware identity, and read-only mounted
  contents pass the completed local acceptance record.

## v0.2.0-m3a (unreleased)

M3-A Codex Focus interface checkpoint for the independently maintained VibeStick for Mac derivative.

### Added

- A real-device Codex Focus home screen with compact Wi-Fi, Bridge, battery, status, quota, sync, refresh, and voice affordances.
- A live 135 × 240 SwiftUI preview linked to project-name visibility and fixed-name configuration.
- Dynamic single-window and multi-window quota layouts; the current single 7D window expands to the full card.
- Per-state optical compensation for running, done, approval, error, offline, idle, and unknown states.
- A manual Codex account-quota reader using one short-lived local app-server process only when refresh is explicitly requested.

### Changed

- Prioritize the currently running Codex task's project over a newer completed task when selecting the device project name.
- Keep passive session `rate_limits` events as the normal low-resource quota source; use the active account read only for double-click/manual refresh.
- Merge active and passive quota observations by timestamp and source so older values do not overwrite newer readings.
- Normalize project names to both the Mac UI limit and the firmware UTF-8 byte limit.
- Rename the development image to `VibeStick-for-Mac-M3-A.dmg`.

### Fixed

- Project status incorrectly showing a different, more recently completed Codex task.
- Stale 7D quota remaining visible after an explicit refresh.
- Single-window quota cards reserving space for an unavailable 5H window.
- Mathematical alignment that looked unbalanced on the real low-resolution LCD.
- Real local Bridge/device identifiers retained in test fixtures.

### Validation

- 109 Python tests and 24 hostless Swift tests pass.
- ESP-IDF 5.5.1 firmware build, Release App, helper targets, signatures, responsive-launch smoke tests, M3-A DMG content, and mounted-App verification pass.
- Firmware image size is `0x154c90`; the smallest app partition retains `0x22370` (9%).
- The paired StickS3 is online with configuration revision `1/1`; firmware flashes completed with hash verification.
- User acceptance covers the high-fidelity preview, real-device status layouts, project shown/hidden states, 7D/LEFT optical balance, footer, and final LCD appearance.
- Bridge/HUD/Paste, push-to-talk voice input, alert sound, M2 pairing, and configuration synchronization remain operational.

This checkpoint does not yet complete M3 voice/send interaction, clean-machine installation, one-click flashing/recovery, Developer ID signing, notarization, or a formal Release.

## v0.2.0-m2 (unreleased)

M2 pairing, discovery, and configuration-sync checkpoint for the independently maintained VibeStick for Mac derivative.

### Added

- Stable StickS3 device IDs, persistent Bridge UUID, and structured paired-device status.
- Explicit USB-only pair/re-pair flow with per-device 256-bit tokens and salted token hashes.
- macOS Keychain storage, staged credential rotation, idempotent pairing transactions, and rollback after USB write failure.
- `_vibestick._tcp` Bonjour advertisement and Bridge-ID-based firmware discovery with manual-address fallback.
- Versioned, allow-listed device configuration with monotonic revision, StickS3 NVS persistence, and authenticated ACK.
- Mac controls for modules, project fields, front-button double-click, and side-button single-click behavior.
- Dynamic `quota_windows` protocol fields while retaining the legacy 5H/7D fields.

### Changed

- Extended the native control center from service health to USB, pairing, LAN-online, firmware, and configuration-sync status.
- Authenticated paired firmware requests with device ID plus a device-specific token while retaining the M1 legacy path.
- Kept the M1 firmware layout and voice/HUD/Paste path stable while adding the M2 protocol foundation.

### Fixed

- ESP mDNS service queries missing the underscore-prefixed service/protocol names.
- First USB identify attempts racing with delayed USB Serial/JTAG enumeration after reset.
- Development-signature changes blocking safe Keychain credential rotation.
- Lost final USB acknowledgements potentially creating ambiguous half-completed pairing transactions.
- Harmless client disconnects producing `BrokenPipeError` noise in Bridge logs.

### Validation

- 97 Python tests and 23 hostless Swift tests pass.
- ESP-IDF 5.5.1 firmware build, Release App, signatures, responsive-launch smoke tests, DMG content, and mounted-App verification pass.
- `scripts/doctor.sh`: 16 PASS, 0 WARN, 0 FAIL.
- Real-device acceptance covers first pairing, credential rotation, injected write-failure rollback, configuration revision/ACK, reboot persistence, Bonjour restart recovery, and a real Mac address change from the original DHCP address to a temporary address.
- During the 95-second new-address-only window, the paired StickS3 completed 63 authenticated Bridge requests.
- Voice recording, ASR, HUD, Paste, TextEdit insertion, alert sounds, Codex state, and dynamic `7D` quota remain operational.

This checkpoint does not yet include the final M3 firmware UI, clean-machine installation, one-click flashing/recovery, Developer ID signing, notarization, or a formal Release.

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
