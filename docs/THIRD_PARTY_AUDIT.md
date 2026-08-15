# Third-Party Audit

This audit began with the v0.1.1 cleanup and was reviewed through the VibeStick for Mac
M4-4D D0.1 offline write/recovery correction on 2026-08-15.

| Project / file / dependency | Source | Current use | License status | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| `bridge/src/vibe_stick/` | Project-authored Python | Local Mac bridge, state API, quota observation, recording flow, ASR adapter, paste injection | MIT under this repository | Low | Keep. |
| `app/macos/VibeStickHUD/main.swift` | Project-authored Swift | Minimal recording status HUD | MIT under this repository | Low | Keep. |
| `app/macos/VibeStickBridge/main.swift` and `app/macos/VibeStickPaste/main.swift` | Project-authored Swift | Named macOS bridge launcher and Accessibility-scoped paste helper | MIT under this repository | Low | Keep. |
| `app/macos/VibeStickApp/`, `app/macos/VibeStick.xcodeproj/`, and `app/macos/VibeStickAppTests/` | Project-authored Swift and Xcode metadata | Native VibeStick for Mac control center, compatibility targets, and hostless tests | MIT under this repository | Low | Keep. |
| `firmware/sticks3/src/` and `firmware/sticks3/include/` | Project-authored C using ESP-IDF APIs | StickS3 UI, HTTP, buttons, audio, battery, speaker alerts | MIT under this repository | Low | Keep. |
| `assets/brand/vibestick-icon.svg` | Project-generated simple geometry | Temporary VibeStick brand icon | MIT under this repository | Low | Keep until polished branding exists. |
| `app/macos/VibeStickApp/Resources/Assets.xcassets/AppIcon.appiconset/` | Project-generated derivatives of `assets/brand/vibestick-icon.svg` | macOS application icon | MIT under this repository | Low | Keep. Preserve the source relationship in the audit. |
| `app/macos/VibeStickApp/Resources/Assets.xcassets/VibeStickMenuBar.imageset/` | Project-authored simplified vector derived from the VibeStick device/terminal motif | macOS template menu-bar icon | MIT under this repository | Low | Keep as a monochrome template asset. |
| `app/macos/VibeStickApp/Resources/Assets.xcassets/CodexDeviceIcon.imageset/` | Project-authored terminal-arrow geometry, not a third-party Codex or OpenAI logo | Codex Focus device preview status icon | MIT under this repository | Low | Keep as project-owned interface geometry. |
| `assets/providers/**` and `firmware/sticks3/assets/providers/**` | Project-generated simple geometry | Temporary provider/status icons | MIT under this repository | Low | Keep. Avoid replacing with third-party brand marks unless license/brand usage is reviewed. |
| `assets/brand/home-screen-preview.png` and `assets/brand/voice-input-preview.png` | Existing upstream repository assets; separate generation metadata is not recorded | README and product preview imagery | Covered by the upstream repository license, but provenance is less explicit than the geometric icon assets | Medium | Keep for current project documentation; document provenance or regenerate before a broad standalone marketing release. |
| `docs/design/m3b/m3b-voice-overlays.svg` and rendered `m3b-*.png` previews | Project-authored deterministic StickS3 UI mockups | M3-B voice/send design contract and review evidence | MIT under this repository | Low | Keep the SVG as the authoritative source and the PNGs as review previews. |
| `firmware/sticks3/generated/vibe_stick_ui_assets.c/.h` | Generated from project-owned PNG icons | LVGL image descriptors for provider icons | MIT under this repository | Low | Keep. |
| `firmware/sticks3/generated/vibe_stick_cn_16.c` | Generated from Source Han Sans K Regular | LVGL Chinese glyph subset for StickS3 UI | Source font is SIL Open Font License 1.1, copyright Adobe 2014-2021 | Medium | Keep with NOTICE attribution. Do not use the reserved Source name as an VibeStick brand. |
| `firmware/sticks3/generated/vibe_stick_ui_10.c`, `vibe_stick_ui_12.c`, and `vibe_stick_project_cn_10.c` | Generated from Noto Sans CJK SC / Noto Sans SC Regular | Uncompressed LVGL glyph subsets for fixed Chinese home-screen and M3-B voice labels, plus 6,763 GB2312 Hanzi for user-configured project names | Source font is SIL Open Font License 1.1, copyright Adobe 2014-2021 | Medium | Keep generated subsets and the reproducible generator with NOTICE attribution. Do not use the reserved Source or Noto names as a VibeStick brand. |
| `firmware/sticks3/src/idf_component.yml` dependencies: `espressif/button`, `espressif/esp_codec_dev`, `lvgl/lvgl` | ESP Component Registry | Build-time firmware dependencies | External open-source components, not vendored after cleanup | Low | Keep dependency manifest and lock file. Review component licenses before binary release. |
| ESP-IDF framework | Espressif | Firmware framework | External SDK, not vendored | Low | Keep as build prerequisite. |
| `FirmwarePayload.noindex` generated images | Project firmware linked with ESP-IDF and audited component dependencies | Secret-free StickS3 installation payload prepared by maintainers | Binary redistribution review remains required before a public Release | Medium | Keep local to the development App/DMG until component notices and release signing are complete. Never copy the local development firmware build. |
| Espressif `esptool` 5.3.1 standalone `macos-arm64` archive | Espressif GitHub Release, pinned HTTPS URL, archive/inner-file sizes and SHA-256 values, and Developer ID team `QWXF6GB4AV` | Downloaded and prepared only after separate explicit confirmations in a private local cache; M4-4B enables only offline `version`, M4-4C has an isolated ROM-only whitelist, and M4-4D separately admits fixed writes/readbacks only after step-specific confirmations | GPL-2.0-or-later; `LICENSE` remains in the private prepared directory and neither archive nor extracted files are bundled in the App/DMG | High | Keep M4-4C isolated. Retain the no-standalone-erase policy, exact offsets, NVS sector checks, matching-backup identity, immediate private prewrite NVS snapshot, persistent recovery state, and four confirmations. Repeat corrected-candidate real-device acceptance separately before release. |
| SiliconFlow, Groq, and OpenAI-compatible ASR APIs | Optional external services | Speech-to-text when explicitly configured or tested | Service APIs, no source vendored | Medium | Clearly display the selected endpoint and that audio leaves the Mac. Do not commit API keys. |
| Local Codex session files | User-local Codex data | Quota/status observation from `~/.codex/sessions/**/*.jsonl` | User-local data, not vendored | Medium | Keep local-only. Do not upload or commit session data. |
| Historical VoiceStick / StickS3VoiceKit / VoiceStickTrial directories outside this repository | Local historical reference directories in the parent workspace | Not part of VibeStick repository | Source/license uncertain from local copy | High | Do not copy into VibeStick. Do not publish as part of this repository. |
| Old provider logo-like assets removed during cleanup | Earlier local prototype assets | No longer used | Source unclear / brand risk | High | Replaced with simple project-generated temporary icons. |
| `firmware/sticks3/managed_components/`, `firmware/sticks3/build/`, Python `__pycache__/` | Generated local build/cache output | Not part of source | N/A | Low | Ignored by git. Do not commit. |
| `firmware/sticks3/include/vibe_stick_secrets.h`, `.env`, logs, recordings | Local user secrets/output | Runtime configuration and generated data | Private user data | High | Ignored by git. Never publish. |

## Summary

The M1-M3-C macOS application, tests, interface icons, and M3-B design mockups are
project-authored or derived from project-generated VibeStick geometry. No third-party
source code or brand assets are intentionally vendored after cleanup, except the generated
Chinese LVGL glyph subsets derived from Source Han Sans K and Noto Sans CJK SC under the
SIL Open Font License 1.1.
Build-time firmware dependencies are resolved through the ESP-IDF component manager
and are not committed as vendored source.

Before a public binary release, review the exact ESP-IDF/component licenses included
in the firmware image, ensure the generated Chinese font attribution remains in NOTICE, and
either document or replace the two older preview composites noted above.
