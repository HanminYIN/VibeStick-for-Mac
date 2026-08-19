# Third-party licenses in the VibeStick for Mac RC binary

This inventory covers the files distributed inside the `0.2.0 RC 1` App/DMG.
The macOS App, native Swift Bridge, HUD, and Paste helper use Apple system
frameworks and do not embed a third-party language runtime or package manager.

The App contains a secret-free StickS3 firmware payload built with ESP-IDF
5.5.1. Its linked map and locked component manifest identify these
redistributed components:

| Component | Version | License |
| --- | --- | --- |
| ESP-IDF core and Espressif Wi-Fi/PHY/coexistence libraries | 5.5.1 | Apache-2.0 |
| Espressif Button | 4.2.0 | Apache-2.0 |
| Espressif ESP Codec Dev | 1.5.10 | Apache-2.0 |
| Espressif mDNS | 1.11.3 | Apache-2.0 |
| LVGL | 9.2.0 | MIT |
| FreeRTOS Kernel | 10.5.1 | MIT |
| Argtable3 | 3.2.2 | BSD-3-Clause |
| Linenoise | bundled by ESP-IDF 5.5.1 | BSD-2-Clause |
| CMock | bundled by ESP-IDF 5.5.1 | MIT |
| FatFs | R0.15 | FatFs permissive license |
| HTTP Parser | 2.7.0 | MIT |
| cJSON | bundled by ESP-IDF 5.5.1 | MIT |
| lwIP | 2.2.0 | BSD-3-Clause |
| Mbed TLS | 3.6.4 | Apache-2.0 |
| ESP-MQTT | 1.0.0 | Apache-2.0 |
| Newlib/Picolibc C runtime portions | ESP-IDF toolchain versions | Newlib and Picolibc permissive notices |
| protobuf-c | bundled by ESP-IDF 5.5.1 | BSD-2-Clause |
| SPIFFS | bundled by ESP-IDF 5.5.1 | MIT |
| Unity | bundled by ESP-IDF 5.5.1 | MIT |
| wpa_supplicant | 2.10 | BSD-3-Clause |
| GCC runtime libraries used by the firmware | 14.2.0 | GPL-3.0-or-later with GCC Runtime Library Exception 3.1 |
| Source Han Sans K / Noto Sans SC glyph subsets | generated subset | SIL Open Font License 1.1 |

The full corresponding notices are tracked under `release/licenses/firmware`
and copied into `VibeStick for Mac.app/Contents/Resources/Licenses` during the
RC build. The
main project MIT license, derivative NOTICE, font OFL, component licenses,
Newlib/Picolibc notices, and GCC runtime license plus exception are therefore
available offline inside the distributed App.

Espressif `esptool` is not bundled. The App can download the separately
licensed GPL-2.0-or-later tool only after explicit user confirmation. Codex,
Claude, ASR services, and their CLIs are integrations, not redistributed
copies.

The authoritative version lock is
`firmware/sticks3/dependencies.lock`. A firmware dependency or toolchain
version change requires refreshing this inventory and the packaged texts
before another binary release.
