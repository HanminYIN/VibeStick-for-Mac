# VibeStick for Mac

`VibeStick.xcodeproj` is the native SwiftUI control center introduced in M1, extended with M2 pairing/configuration, the M3-A Codex Focus interface, M3-B voice/send diagnostics, M3-C native ASR configuration, and M4 transactional maintenance. It targets Apple Silicon and macOS 15 or newer.

See the [M1 achievements and validation evidence](../../docs/VIBESTICK_FOR_MAC_M1_ACHIEVEMENTS.md)
and [M2 achievements and upstream comparison](../../docs/VIBESTICK_FOR_MAC_M2_ACHIEVEMENTS.md),
plus [M3-A achievements and upstream comparison](../../docs/VIBESTICK_FOR_MAC_M3A_ACHIEVEMENTS.md),
[M3-B voice/send achievements](../../docs/VIBESTICK_FOR_MAC_M3B_ACHIEVEMENTS.md), and
[M3-C native ASR configuration achievements](../../docs/VIBESTICK_FOR_MAC_M3C_ACHIEVEMENTS.md), plus the
[M4 installation and recovery contract](../../docs/design/m4/M4_INSTALLATION_RECOVERY_CONTRACT.md),
for the upstream boundary, implemented scope, real-device acceptance, and deferred work.

## M1 foundation through M4-4B tool preparation

The M1 app intentionally manages the existing stable installation instead of replacing it:

- Shows the dedicated Codex state, project name, available 7-day quota, and stale-cache warning from the local Bridge, even if another provider is active.
- Shows separate structured health for VibeStick Bridge, HUD, and Paste.
- Starts, restarts, or stops the existing Bridge and HUD LaunchAgents only after an explicit user action.
- Checks Accessibility by launching the installed `VibeStick Paste.app` through LaunchServices, matching the real paste path so the permission identity is not confused with the main app.
- Reads only a redacted summary of the legacy `.env`; presence is not presented as a successful ASR test, and secret values are never displayed.
- Stores new non-secret preferences in `config-v1.json` with mode `0600` and provides a Keychain storage boundary for later migrations.
- Provides M2 device configuration controls, local paired-device status, strict StickS3 USB detection, and explicit USB pair/re-pair actions.
- Refuses to write a new pairing key unless the running Bridge reports protocol 2 and a valid Bridge ID, protecting the installed M1 runtime from a token mismatch.
- Shows a live 135 × 240 Codex Focus preview whose project-name visibility and fixed name use the same normalized M2 configuration delivered to the device.
- Configures SiliconFlow, Groq, OpenAI-compatible, or a local ASR command; API Keys are stored only in Keychain.
- Generates a fixed temporary audio fixture and tests the selected provider without accessing a Mac microphone or invoking Paste, the clipboard, Return, or the M3-B send session.
- Installs or repairs only the embedded, manifested Bridge/HUD/Paste runtime after explicit confirmation, with backup, verification, and rollback.
- Downloads the pinned Espressif `esptool` 5.3.1 Apple Silicon archive only after explicit confirmation and verifies HTTPS, exact size, and SHA-256.
- After a second explicit confirmation, validates the exact archive listing, inner file digests, thin-arm64 executables, Espressif Developer ID signatures, and the offline `esptool version` command before transactionally preparing a private tool directory.

First launch does not run `scripts/install.sh`, rebuild helpers, modify `.env`, alter firmware, or re-sign the installed Paste app. Closing or quitting the control center does not stop background services.

The M4-4B control center is not yet a firmware flasher. Its development bundle contains a secret-free, offline-validated StickS3 payload. It can prepare the separately downloaded tool only after confirmation and runs only the no-device `esptool version` command. It does not enumerate or open a serial port, inspect device security state, read or back up firmware, or issue erase/write commands. Device inspection/backup and flashing remain separately authorized M4-4C/D work. No firmware operation happens on app launch or USB detection.

If a healthy Bridge is already running outside the installed LaunchAgent, the control center reports it as externally managed and keeps service controls read-only. This avoids creating a second process on port 8765. Stop and restart are also blocked while a recording or transcription is active.

## Xcode targets

- `VibeStickForMac`: Swift 6 control center.
- `VibeStickForMacTests`: hostless model, parsing, persistence, redaction, and lifecycle tests.
- `VibeStickBridge`, `VibeStickHUD`, `VibeStickPaste`: compatibility build targets for the existing helpers. These remain in Swift 5 language mode while the control center uses Swift 6 strict concurrency.

Every target has an explicit `MACOSX_DEPLOYMENT_TARGET` of 15.0. The helper app names remain human-readable while their internal executables retain the stable `VibeStickBridge`, `VibeStickHUD`, and `VibeStickPaste` names. Verify the actual Mach-O load command rather than relying only on `Info.plist`.

## Build

Open `VibeStick.xcodeproj` in Xcode and choose the `VibeStickForMac` scheme, or run:

```sh
scripts/build-macos-app.sh
```

The ad-hoc-signed development app is written to `.build/macos.noindex/VibeStick for Mac.app` so macOS does not list build artifacts as installed apps.

Build the development DMG with:

```sh
scripts/build-macos-dmg.sh
```

The result is `.build/macos.noindex/VibeStick-for-Mac-M4-4B.dmg`. This development DMG contains the M4-2 verified runtime payload, the M4-3 pinned downloader, the M4-4A secret-free firmware payload, and M4-4B validation logic. It does not contain the downloaded archive, extracted `esptool`, or ESP-IDF. Opening it does not install, download, extract, execute a tool, restart services, access USB, or flash firmware.

Run the complete local acceptance chain with:

```sh
scripts/verify-macos-build.sh
```

This rebuilds and verifies the app and helper compatibility targets, signs and executes the hostless Swift tests, creates the DMG, mounts it read-only, and checks its exact content boundary. Tests can also be run from Xcode with the `VibeStickForMac` scheme's Test action.

## Existing helpers

- `VibeStickBridge/main.swift` launches the current Python Bridge runtime.
- `VibeStickHUD/main.swift` renders the recording and transcription HUD.
- `VibeStickPaste/main.swift` performs paste and optional Return through Accessibility.

The installed helpers remain under `~/Library/Application Support/VibeStick` and are managed by the existing `com.vibestick.bridge` and `com.vibestick.hud` LaunchAgents.
