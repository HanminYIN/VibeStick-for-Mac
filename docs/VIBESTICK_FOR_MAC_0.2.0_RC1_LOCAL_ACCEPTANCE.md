# VibeStick for Mac 0.2.0 RC 1 local acceptance

Date: 2026-08-19

## Result

The isolated local release candidate passed the authorized pre-publication
acceptance chain. It is ready for a maintainer to commit, push, tag, create a
GitHub Pre-release, and upload the DMG only after those Git/GitHub actions are
separately authorized.

After isolated acceptance, the candidate was installed locally under separate
authorization. The main App was atomically replaced with a recoverable backup,
then its transaction installer backed up and upgraded Bridge, HUD, and Paste.
Normal managed startup read the existing bounded configuration and fixed
Keychain accounts. The previously granted macOS Keychain, Local Network, and
Accessibility permissions remained valid, so this final replacement required no
new system prompt.
No credential value was printed, retained by a probe, or written to this record.
The acceptance did not read logs, call a production diagnostic adapter, access
USB or a device, or perform a firmware operation. Git use was limited to read-only
file/status queries for the prospective tag snapshot; no Git mutation occurred.

## Candidate identity

- File: `.build/macos.noindex/RC1-FinalSnapshot/VibeStick-for-Mac-0.2.0-rc.1.dmg`
- Size: `3,546,767` bytes
- SHA-256: `6cd183a4c65cfc6eab632ff401fb67316d11e38e1b180dd65d1ea103f282599c`
- Main App: `0.2.0 (10)`, thin arm64, minimum macOS 15.0
- Bridge: `0.2.0 (10)`, thin arm64, minimum macOS 15.0
- HUD: `0.2.0 (10)`, thin arm64, minimum macOS 15.0
- Paste: `0.2.0 (10)`, thin arm64, minimum macOS 15.0
- Signing: local ad-hoc signatures; no Developer ID signature or notarization

The App and all three embedded helper bundles passed strict deep signature
verification. Intermediate build products and the mounted candidate were
unregistered from Launch Services; no path under the isolated RC build root
remained registered after acceptance.

## Native runtime boundary

The signed runtime manifest permits exactly these payload entries:

- `VibeStick Bridge.app`
- `VibeStick HUD.app`
- `VibeStick Paste.app`
- `manifest-v1.json`

There are no Python source files, bytecode files, interpreter bundles, or
interpreter-discovery assets in the App. Python remains only as a developer-side
compatibility-test and firmware-maintainer tool; end users do not need Python,
Homebrew, Xcode, ESP-IDF, or repository dependencies.

The App carries 25 offline license/notice files covering the project, font,
firmware components, C libraries, and applicable toolchain runtime terms.

## Verification evidence

- Hostless Swift: 269 tests in 21 suites passed.
- Retained Python compatibility suite: 194 tests passed.
- GitHub Actions now contains a read-only `macos-15` arm64 hostless Swift job in
  addition to the Python job. The clean-snapshot equivalents passed locally;
  the first hosted run remains pending the separately authorized push.
- The prospective tag snapshot was assembled from tracked and non-ignored
  intended source files only. It contained no `.git`, `.build`, `.env`, local
  firmware secret header, generated ESP-IDF tree, or prior accepted App.
- Release builds, exact versions, thin-arm64 architectures, macOS 15.0 load
  commands, signatures, icons, runtime manifest, license inventory, forbidden
  file scan, and exact firmware-binary scope passed.
- The DMG checksum verified successfully.
- The DMG was attached read-only with `nobrowse`; its root contained exactly the
  App and the `/Applications` link.
- The mounted App repeated the version, architecture, minimum-OS, signature,
  runtime-manifest, license, firmware-identity, and forbidden-file checks.
- No executable inside the DMG was launched. The image was detached and its
  temporary mount point removed; no residual RC mount remained.

## Authorized installed-runtime evidence

- `/Applications/VibeStick for Mac.app` and the installed Bridge binary are
  byte-identical to the final isolated candidate.
- App, Bridge, HUD, and Paste are all `0.2.0 (10)`, thin arm64, minimum macOS
  15.0, and pass strict deep signature verification.
- The generated Bridge LaunchAgent associates itself with
  `io.github.hanminyin.vibestick`; Bridge and HUD are loaded and running.
- The final installer receipt records `installed`, payload
  `0.2.0-rc.1-native`, and preserved Paste identity. The App reports Bridge,
  HUD, and Accessibility/Paste as normal.
- macOS 15 Local Network privacy is declared by both the main App and Bridge
  through a nonempty usage description and `_vibestick._tcp`; the legacy
  LaunchAgent includes `AssociatedBundleIdentifiers`, and installer verification
  allows up to 120 seconds for the user permission handoff.
- A serialized route queue now keeps state, recording, and configuration
  operations ordered while `/health` remains independent of slow provider/session
  observation. With the main App open and forced to refresh three times, 40 of
  40 concurrent health probes succeeded. The regression remains covered by the
  complete hostless Swift suite.
- The Advanced Settings card showed `0.2.0 (10) · RC 1`; diagnostic preview was
  still ungenerated, the log option was off, and the USB card remained
  uninspected. No preview, export, device check, or firmware action was invoked.
- The earlier installed runtime and each replacement stage remain in private,
  recoverable backup directories. No firmware or device path was touched.

The embedded `bootloader.bin`, `partition-table.bin`, `vibe-stick.bin`, and
`manifest-v1.json` are byte-identical to the accepted M4-5K App payload. The
accepted payload now lives at the tracked
`release/firmware/sticks3/0.2.0-m4.4a` release-input path, while its 21 audited
offline notices live under `release/licenses/firmware`. CI binds the manifest to
the current secret-free firmware source digest. The packaging step defaults to
refusing a rebuild unless a maintainer separately sets
`VIBESTICK_ALLOW_FIRMWARE_REBUILD=1`; this acceptance therefore needed neither a
previous build directory nor ESP-IDF, did not read the excluded local secret
header, and did not rebuild firmware.

## Preserved baseline

The accepted M4-5K candidate remains untouched:

- File: `.build/macos.noindex/M4-5K-Offline/VibeStick-for-Mac-M4-5K.dmg`
- Size: `3,137,499` bytes
- SHA-256: `960769a7c9b9ec42586c3ddb4c7b2ad9993a8cac047707da7531930fcf28c450`

The existing M4-5K installation backup and diagnostic export were not modified.

## Deferred evidence and publication stop

Strict clean-machine first-install and fault-rollback acceptance remains
unexecuted because no second clean Mac or external clean boot environment is
available. This is neither a pass nor a failure and must be disclosed in the
GitHub Pre-release notes.

The local RC is intentionally stopped before all Git/GitHub mutations: commit,
push, tag, Pre-release creation, and DMG upload. Those actions are outside this
acceptance and require separate explicit authorization.
