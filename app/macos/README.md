# VibeStick for Mac

`VibeStick.xcodeproj` is the native SwiftUI control center introduced in M1. It targets Apple Silicon and macOS 15 or newer.

See the [M1 achievements and validation evidence](../../docs/VIBESTICK_FOR_MAC_M1_ACHIEVEMENTS.md)
for the upstream boundary, implemented scope, manual acceptance, and deferred work.

## M1 scope

The M1 app intentionally manages the existing stable installation instead of replacing it:

- Shows the dedicated Codex state, project name, available 7-day quota, and stale-cache warning from the local Bridge, even if another provider is active.
- Shows separate structured health for VibeStick Bridge, HUD, and Paste.
- Starts, restarts, or stops the existing Bridge and HUD LaunchAgents only after an explicit user action.
- Checks Accessibility by launching the installed `VibeStick Paste.app` through LaunchServices, matching the real paste path so the permission identity is not confused with the main app.
- Reads only a redacted summary of the legacy `.env`; presence is not presented as a successful ASR test, and secret values are never displayed.
- Stores new non-secret preferences in `config-v1.json` with mode `0600` and provides a Keychain storage boundary for later migrations.
- Includes placeholders for the agreed M2–M4 modules without pretending that pairing, firmware generation, or flashing already works.

First launch does not run `scripts/install.sh`, rebuild helpers, modify `.env`, alter firmware, or re-sign the installed Paste app. Closing or quitting the control center does not stop background services.

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

The ad-hoc-signed development app is written to `.build/macos/VibeStick for Mac.app`.

Build the development DMG with:

```sh
scripts/build-macos-dmg.sh
```

The result is `.build/macos/VibeStick-for-Mac-M1.dmg`. This M1 DMG is for a Mac that already has the stable VibeStick services installed. A self-contained clean-machine installer and on-demand flashing tool download belong to M4/R1.

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
