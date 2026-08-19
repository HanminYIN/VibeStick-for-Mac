# M4 Installation and Recovery Contract

## Scope

M4 turns the existing developer installation into a guided Mac workflow without
bundling the complete ESP-IDF toolchain. It preserves the accepted Bridge, HUD,
Paste, voice, device configuration, and firmware behavior.

M4 is split into independently accepted stages:

1. M4-1: read-only runtime preflight and a deterministic maintenance plan.
2. M4-2: transactional Bridge, HUD, and Paste installation or repair with backup,
   post-install verification, and rollback.
3. M4-3: pinned lightweight flashing-tool download with HTTPS and SHA-256 checks.
4. M4-4A: secret-free distributable firmware, USB Wi-Fi provisioning, and an
   offline-validated firmware payload.
5. M4-4B: explicitly confirmed extraction and offline identity/version validation
   of the pinned flashing tool.
6. M4-4C: separately authorized device identity/security inspection and private
   full-flash backup.
7. M4-4D: fixed-range write, independent readback, full-backup recovery, and
   independent recovery readback, with each real-device step separately authorized.
8. M4-5: legacy migration, redacted diagnostics, and clean-machine acceptance.

## M4-1 mutation boundary

M4-1 may inspect files, LaunchAgents, local health, code signatures, and the Paste
Accessibility permission. It may refresh those observations from the UI.

M4-1 must not:

- install, replace, delete, start, stop, or restart a runtime component;
- download a tool or firmware image;
- access or change a device serial port;
- modify Keychain entries, configuration, or permissions;
- run a firmware build or flash;
- infer that missing Accessibility permission requires reinstalling Paste.

## Maintenance-plan precedence

The planner is deterministic and returns one next safe class of work:

1. An incomplete inspection remains `checking`.
2. Active recording, an unknown port owner, or an externally managed Bridge is
   `blocked` and cannot be taken over.
3. Missing components require installation.
4. Damaged, mismatched, or running-but-not-ready components require repair.
5. A valid Paste component without Accessibility permission requires only manual
   authorization.
6. Installed but stopped Bridge or HUD components require only start actions.
7. Otherwise the runtime is ready.

The plan lists only affected components. A healthy component is never proposed for
replacement merely because another component needs work.

When every component is healthy, M4-2 may expose a separate user-initiated
reinstall action for acceptance, update, or recovery preparation. It must never
start automatically: the same explicit confirmation, second preflight, backup,
verification, and rollback contract applies.

## M4-1 acceptance

- Unit tests cover ready, missing, repair, permission-only, stopped, recording,
  port-conflict, external-Bridge, and incomplete-inspection states.
- The Updates and Recovery page renders the same current Bridge, HUD, and Paste
  health used by the rest of the app.
- Refresh is read-only and no install or repair button is exposed.
- The page states that M4-2 requires a separately confirmed, verified backup and
  rollback path before any runtime mutation.
- Existing Swift tests, Release builds, signatures, GUI smoke, and DMG content
  gates continue to pass.

## M4-2 entry contract

M4-2 must not call the repository `scripts/install.sh` from a distributed app. It
must install only resources shipped and verified as part of the app bundle, stage
them in a private temporary directory, preserve unchanged Paste identity when
possible, back up the current managed installation, and switch atomically.

If verification fails, M4-2 restores the prior runtime and LaunchAgents. It never
adopts an external Bridge, never replaces a conflicting process, never mutates an
active recording session, and never treats a permission prompt as installation
success.

## M4-2 transaction contract

The distributed App embeds `RuntimePayload.noindex`, containing only the three
native helper bundles and a versioned manifest. Every regular file is listed
with its relative path, size, POSIX mode,
and SHA-256 digest. Symlinks, undeclared files, missing files, path traversal, an
unknown schema, or an invalid nested code signature fail before services stop.

After explicit confirmation, M4-2 performs a second preflight. It blocks an
active recording, an unrecognized port owner, an external Bridge, or a loaded
helper outside the managed paths. The native Swift Bridge must not search for or
require Python, Homebrew, Xcode, or another external interpreter.

The file transaction owns only these targets:

- the legacy `runtime` directory as removal/rollback-only state;
- the Bridge, HUD, and Paste apps in `Components.noindex`;
- `com.vibestick.bridge.plist` and `com.vibestick.hud.plist`.

It never moves or copies `.env`, Keychain data, device and bridge identities,
device configuration, recordings, logs, or app preferences. The old managed
targets are moved into a private versioned backup before staged targets are moved
into place. An unchanged, valid Paste build is copied into the backup but kept at
its installed path so its Accessibility identity is not replaced.

The new Bridge and HUD must load, remain running, return the expected Bridge
health identity, and retain valid helper signatures. Any staging, backup, switch,
start, or verification error stops the candidate services, restores all original
targets (including originally absent targets), and restores the prior loaded
service state. A private receipt records either `installed` or `rolled-back` and
contains no secrets.

## M4-2 acceptance

- Manifest tests reject tampering, extra files, symlinks, and unsafe paths.
- Isolated temporary-directory tests prove successful switch, configuration
  preservation, unchanged Paste preservation, and fault rollback after backup,
  switch, and start.
- Release App and DMG gates verify the embedded manifest, exact payload contents,
  nested signatures, arm64/minimum OS, and the absence of private/development
  files.
- Normal App and DMG launch smoke tests prove that merely opening the candidate
  does not stop, restart, or replace the currently installed Bridge or HUD.
- M4-2 validation never clicks the install confirmation against the maintainer's
  current runtime; real mutation requires a separately authorized acceptance run.
- A healthy current runtime can be deliberately reinstalled only after that
  separate authorization; no component is damaged or removed merely to make the
  maintenance planner offer a repair.

## M4-2 maintainer acceptance — 2026-08-14

The first authorized live transaction replaced the staged targets but did not
observe Bridge and HUD as jointly healthy inside the original six-second window.
It wrote a `rolled-back` receipt, restored the prior managed files and running
service state, preserved Paste identity, and left configuration file digests
unchanged.

The installer now waits until the old jobs and port 8765 have fully exited before
switching files, allows a 15-second cold-start verification window, and includes
the final Bridge, HUD, and endpoint states in any failure. After the full build,
signature, unit-test, App, and DMG gates passed again, a second authorized live
transaction installed payload `0.2.0-m4.2`. The installed runtime and Bridge/HUD
bundles matched the embedded payload, all nested signatures passed, Paste retained
its existing identity and Accessibility permission, the five protected
configuration files kept their pre-install digests, and Doctor reported 16 PASS,
0 WARN, 0 FAIL.

## M4-3 pinned flashing-tool descriptor

M4-3 pins the official Apple Silicon standalone archive from Espressif rather than
bundling ESP-IDF or resolving a moving “latest” URL:

- tool: `esptool`;
- version: `5.3.1`;
- architecture: `macos-arm64`;
- source: `https://github.com/espressif/esptool/releases/download/v5.3.1/esptool-v5.3.1-macos-arm64.tar.gz`;
- exact size: `61,218,014` bytes;
- SHA-256: `f63f7203d88cfe4c17aea34d6cf82769458ce204e49a05816c6384c2d299e6ca`.

The size and digest are recorded in Espressif's official Arduino package index as
well as the fixed application descriptor. Changing any field is a reviewed source
change, not an automatic update.

## M4-3 download and cache boundary

Opening the app or the Updates and Recovery page performs only a local cache
inspection. A real download starts only after the user presses the download button,
sees the exact version and approximate size, and confirms.

The downloader must:

- accept only the pinned `github.com/espressif/esptool` HTTPS source;
- refuse any redirect whose next URL is not HTTPS;
- require HTTP 200 and an allow-listed gzip or binary content type;
- reject a declared or actual size different from the pinned size;
- compute SHA-256 over the downloaded file and require the pinned digest;
- write to a private `0700` versioned cache through a `0600` sibling temporary file;
- atomically replace the current pinned archive only after every check succeeds;
- preserve an existing cache if a new response or download fails;
- remove only the exact pinned archive when the user separately confirms cache
  removal.

M4-3 does not unpack or execute the archive, enumerate or open serial ports, inspect
the device, read firmware, build firmware, or issue any erase/write command. Those
operations, including validation of the extracted executable and its signature,
belong to M4-4 and require a separate acceptance boundary.

## M4-3 acceptance

- Hostless tests cover insecure descriptors, oversize descriptors, missing, valid,
  and damaged cache states, verified atomic replacement, HTTPS-response rejection,
  and exact-scope cache removal.
- Source gates pin the version, URL, byte count, and SHA-256, and reject serial,
  extraction, execution, erase, and write behavior in the M4-3 implementation.
- Release App and DMG contain only the descriptor and downloader code, never an
  `esptool` archive or the full ESP-IDF toolchain.
- App and DMG launch smoke tests do not download anything, mutate the cache, restart
  Bridge/HUD, access USB, or modify firmware.
- Unit and build tests use small local fixtures and make no external download. The
  separate real-download acceptance was completed on 2026-08-15 through the installed
  `0.2.0 (3)` app and its explicit confirmation sheet. The final archive was exactly
  `61,218,014` bytes with the pinned SHA-256, mode `0600`, and `0700` cache parents;
  no sibling temporary file remained. The page reported a verified cache and a second
  local inspection passed. Bridge health remained normal, no `esptool` process ran,
  and no extraction, serial access, or firmware operation occurred.

## M4-4A distributable firmware and provisioning boundary

M4-4 begins with a source-and-package-only stage. M4-4A may build a maintainer
firmware payload and embed it in the development App/DMG, but it does not unpack or
execute the downloaded flashing tool, enumerate or open serial ports, inspect or
back up a device, restart any runtime, or erase/write/verify device flash.

The distributable firmware build is compiled with
`VIBE_STICK_DISTRIBUTABLE_BUILD=ON`. In that mode the firmware configuration header
does not include `vibe_stick_secrets.h`, even when the maintainer has that ignored
file locally. The image boots with Wi-Fi unconfigured while keeping USB Serial/JTAG
pairing available. The normal development build remains compatible with the
existing ignored compile-time configuration.

USB pairing schema 1 remains valid and does not alter Wi-Fi. Schema 2 requires the
same pairing and Bridge fields plus `wifi_ssid` and `wifi_password`. The firmware
accepts a 1–32 byte valid UTF-8 SSID without control characters and an 8–63 byte
printable-ASCII WPA2 password. Pairing and Wi-Fi values are written in one NVS
commit; an error restores the in-memory configuration. A successful credential
change is acknowledged with `restart_required: true` before the firmware restarts.
Identify responses advertise `pairing_schema_version: 2` and only the boolean
`wifi_configured`; neither command logs or returns credentials.

`FirmwarePayload.noindex` contains exactly:

- `bootloader.bin` at `0x0`;
- `partition-table.bin` at `0x8000`;
- `vibe-stick.bin` at `0x10000`;
- `manifest-v1.json`.

The schema-1 manifest pins the ESP32-S3/StickS3 target, 8 MiB DIO/80 MHz flash
geometry, source revision and source-tree digest, image modes/sizes/SHA-256 values,
and the preserved NVS range `0x9000..<0xf000`. Python generation and Swift offline
validation reject extra or missing files, symlinks, path/offset changes, overlaps,
wrong modes, bounds violations, and digest mismatches. Packaging also scans the
three images for values from the local ignored secret header without printing
those values.

## M4-4A acceptance

- Python tests cover manifest round-trip, exact offsets, NVS preservation, build
  arguments, tampering, extra files, symlinks, modes, and non-disclosing secret
  detection.
- Swift tests cover schema-1 backward compatibility, schema-2 Wi-Fi validation and
  encoding, firmware geometry, exact file set, tampering, and NVS overlap rejection.
- A separate ESP-IDF build directory produces the distributable images. The legacy
  `firmware/sticks3/build` development images are never copied into the App.
- App and mounted-DMG gates validate both the Python and Swift-compatible manifest
  contract and permit `.bin` files only in the exact firmware payload directory.
- M4-4B extraction/tool validation, M4-4C device identity/security inspection and
  private full-flash backup, and every real-device M4-4D write/readback/recovery
  step each remain separately authorized.

Current local acceptance evidence (2026-08-15): 173 Python tests and 56 Swift
tests passed; the ESP-IDF 5.5.1 distributable build, Release App/helpers,
signatures, fresh-window launch smoke tests, and mounted DMG checks passed. The
`0.2.0 (4)` candidate DMG is 2,643,120 bytes with SHA-256
`49c4ddaf0aa96c6562b871a4de3a0e4a057df86c1e2162ad817d57fc4d419bbc`.
No flashing-tool extraction/execution, serial/device access, runtime installation
or restart, firmware backup, erase, write, or verification occurred.

## M4-4B extracted-tool boundary

M4-4B may run only after the pinned M4-3 archive is present and has again passed
its exact size and SHA-256 checks. App launch, page navigation, USB detection, and
ordinary refresh remain inspection-only. Extraction begins only after the user
selects the separate prepare action and confirms the dialog that names the exact
version and the no-device boundary.

Before extraction, `/usr/bin/tar` lists the archive twice: the name list must equal
the seven pinned entries in their fixed order with no duplicates, and the verbose
list must contain exactly one directory followed by six ordinary files. Absolute
paths, traversal, alternate roots, links, devices, extra files, missing files, or
reordered entries are rejected before extraction. The verified archive is then
unpacked with one path component stripped into a private sibling staging directory;
owner and archive permissions are not inherited.

The extracted directory must contain exactly the pinned `README.md`, `LICENSE`,
`esptool`, `espefuse`, `espsecure`, and `esp_rfc2217_server` files. Every size and
SHA-256 is fixed in source. The four executables must be thin arm64 Mach-O files and
pass strict Apple code-signature requirements for Espressif Developer ID team
`QWXF6GB4AV` and their exact signing identifiers. The directory and executable
permissions are normalized to `0700`; documentation files use `0600`.

Only after those checks may the App execute the exact argument vector
`esptool version` in a minimal environment with no port, chip, read, erase, write,
or verify argument. Its two version lines must identify the pinned version. A
validated staging directory replaces `Prepared.noindex` only after the offline
command succeeds; replacement failure restores the previous directory, and
temporary/backup paths are removed. Refresh validates the on-disk files and
signatures but never executes the tool automatically.

M4-4B does not bundle the downloaded archive or extracted tool in the App/DMG. It
does not enumerate or open serial ports, inspect device security state, read or
back up flash, erase/write/verify firmware, install a main App, or start/restart
Bridge or HUD. Those device operations remain M4-4C/D and require new authorization.

## M4-4B acceptance

- Hostless tests cover exact archive listings, traversal, duplicates, links,
  extracted file-set and digest checks, private permissions, wrong versions,
  cleanup, and preservation of an already prepared tool after a failed attempt.
- Source gates pin all inner file sizes/digests, the Espressif team ID, strict code
  signature validation, the exact `version` argument, and the absence of serial or
  flash commands.
- Release App and DMG still contain neither the archive nor an extracted `esptool`.
- App and mounted-DMG smoke tests remain read-only for the tool cache and preserve
  the existing Bridge/HUD process identities.

Current local acceptance evidence (2026-08-15): 173 Python tests and 59 Swift
tests passed; Release App/helpers, signatures, fresh-window smoke tests, and the
mounted M4-4B DMG passed. The `0.2.0 (5)` candidate DMG is 2,668,475 bytes with
SHA-256 `aff2f26f0cd34f00de4828bdf73c4f330b1f3845128f9ac4883b9cf25d1c7019`.
The separately authorized real preparation used the same manager implementation:
all six files, private modes, four arm64 identities and Espressif signatures
passed, and `esptool version` returned `5.3.1`. No temporary/backup entry or
`esptool` process remained; Bridge health was HTTP 200. No serial/device access,
runtime restart, firmware backup, erase, write, or verification occurred.

## M4-4C device inspection boundary

M4-4C remains inert on App launch, navigation, ordinary refresh, USB appearance,
and tool-cache refresh. Device access begins only after the user selects the device
inspection action, sees that the StickS3 must already be in download mode, and
confirms. The App requires exactly one current USB Serial/JTAG candidate with
Espressif VID `0x303a`, PID `0x1001`, and a `/dev/cu.usbmodem*` callout path. Zero,
multiple, or mismatched candidates fail closed.

Immediately before each device workflow, the App revalidates the pinned archive,
the complete prepared file set, private modes, arm64 Mach-O identity, and Espressif
Developer ID signature. Device commands use that exact executable in an empty
private working directory and a minimal environment. M4-4C fixes the target to
`esp32s3`, the baud to 115200, the reset-before mode to `no-reset`, the loader to
`--no-stub`, and the connect attempts to three. The only command names admitted by
the source whitelist are:

- `get-security-info`;
- `flash-id` with the standard SPI connection;
- `read-mac`;
- `read-flash`.

Inspection accepts only the official esptool 5.3.1 ESP32-S3 package descriptions:
QFN56, ESP32-S3-PICO-1 LGA56, or the forward-compatible unknown-package label,
each with a numeric silicon revision, plus a detected 8 MiB NOR flash. Secure Boot
and Flash Encryption must both be explicitly reported disabled. Enabled or
unparseable security state, a different chip, a different flash size, or an
unrecognized response blocks backup. The hardware MAC is read only to derive a
domain-separated SHA-256 device fingerprint; it is discarded and is not placed in
the UI or receipt. The final inspection command uses the watchdog reset so the
device exits ROM mode.

## M4-4C private full-flash backup transaction

Backup has a second explicit confirmation and requires the same device to enter
download mode again. A second identity/security/flash preflight must match the
previous device fingerprint and flash IDs. The App then runs two complete ROM-only
reads of `0x0..<0x800000`, with the flash size fixed to `8MB` and progress output
disabled. Both temporary images must be ordinary, non-symlink files of exactly
8,388,608 bytes with mode `0600`, and their SHA-256 values must be identical. Only
then is the verification copy removed and one image retained.

The transaction owns only a newly generated child of
`~/Library/Application Support/VibeStick/FirmwareBackups.noindex`. A symbolic-link
backup root is rejected before the tool launches. Parent, staging, and final
directories are `0700`; the image and sorted schema-1 JSON receipt are `0600`.
The final receipt is decoded and compared with the expected in-memory document
before success is returned. It records the tool version, chip and flash geometry,
disabled security booleans, hashed device fingerprint, image size/digest, and the
double-read verification method. It contains no raw MAC, Wi-Fi value, pairing
secret, serial-port path, or firmware bytes. The full image itself may contain
private NVS data and must never enter source control, the App, DMG, diagnostics, or
release artifacts.

Any missing device, identity change, tool error, timeout, short read, unsafe file,
digest mismatch, receipt error, or final validation error removes the exact staging
or failed final directory. No partial image becomes a backup. The last successful
read uses a watchdog reset. M4-4C never invokes erase, write, RAM-load, firmware
comparison, or recovery commands; those remain M4-4D.

## M4-4C acceptance

- Hostless tests cover expected parsing, wrong chip/size/security state, zero,
  multiple and wrong USB candidates, symbolic-link backup-root rejection, exact
  command vectors, identity replacement, double-read mismatch cleanup, private
  modes, exact file set, receipt redaction, and a successful 8 MiB transaction.
- Source gates require the four-command whitelist, ROM-only/no-reset settings,
  two fixed full reads, double-read SHA-256 evidence, private paths/modes, and both
  UI confirmations; they reject all M4-4D mutation/verification command names.
- Release App and mounted-DMG checks reject `FirmwareBackups.noindex`, backup
  images and backup receipts from packaged content. Launch smoke remains device-
  inert and preserves Bridge/HUD process identities.
- On 2026-08-15, the separately authorized real-device run passed after adding
  the official ESP32-S3-PICO-1 LGA56 package description to the strict parser.
  The StickS3 reported 8 MiB flash with Secure Boot and Flash Encryption disabled.
  Two complete ROM-only reads matched; the retained image was exactly 8,388,608
  bytes, the independent on-disk digest matched the redacted receipt, directory
  and file modes were `0700`/`0600`, and no partial directory remained. No device
  fingerprint, private image digest, or local backup-instance path is recorded
  here. The separately authorized M4-4D D1-D4 run and the subsequent D0.1
  correction are recorded below.

## M4-4D D0.1 fixed-write and recovery boundary

M4-4D is implemented in a source file and state machine separate from the M4-4C
reader. The M4-4C source whitelist remains unchanged and continues to reject every
write, erase, comparison, RAM-load, and recovery command. App launch, navigation,
local readiness inspection, and build/DMG smoke tests do not enumerate USB devices,
open a serial path, or execute `esptool`.

Local readiness first validates the embedded schema-1 payload, all file modes,
sizes and SHA-256 values, and at least one complete M4-4C backup. The backup root
and each backup directory must be ordinary non-symlink directories with mode
`0700`; each directory must contain exactly `flash-8MiB.bin` and `receipt-v1.json`
with mode `0600`. The receipt, image size, digest, ESP32-S3/8 MiB geometry, disabled
security flags, tool version, flash IDs, device fingerprint, and double-read method
must all agree before any device workflow can begin.

The candidate plan accepts exactly the payload files and offsets already fixed by
M4-4A: bootloader at `0x0`, partition table at `0x8000`, and application at
`0x10000`. Each non-empty file range is expanded to its actual 4 KiB erase-sector
envelope. Any envelope that overlaps another candidate envelope, falls outside the
8 MiB flash, or touches NVS `0x9000..<0xf000` blocks the transaction. The candidate
command is one fixed `write-flash` invocation with flash size/mode/frequency kept
from the device, standard SPI connection, no progress output, ROM-only `--no-stub`,
and reset-before/reset-after both set to `no-reset`. There is no standalone
`erase-flash` or `erase-region` step. Force, encryption, diff/trust/skip modes,
tool-level `verify-flash`, RAM loading, and flash-status writes are forbidden.

Immediately before any real-device phase, the App requires a healthy managed
Bridge, no recording, and no overlapping tool/backup/flash action; the executor
also reads the private recording state and blocks `recording`, `transcribing`, or
`pending_send` before launching the tool. The pinned prepared executable is fully
revalidated again. Device preflight then requires exactly one supported USB
candidate and reruns the M4-4C security, flash-ID, and MAC-derived fingerprint
inspection without resetting. The current fingerprint and flash IDs must select
the same validated backup that existed before the candidate write.

Tool completion and the fixed `Hash of data verified` output create only a
`write-unverified` journal phase. They are not final acceptance. A second explicit
confirmation is required to reconnect to the same device, read each candidate
range independently, compare every SHA-256 with the payload, then read NVS and
compare it with the private NVS snapshot captured immediately before the candidate
write. The first three reads leave the device in ROM mode; only the final NVS read
uses a watchdog reset. Success becomes `verified`, but still requires functional
real-device acceptance outside this transaction.

D0.1 makes that comparison baseline transactional. After local, runtime, tool,
device, and matching-backup gates pass, D1 first reads exactly `0x6000` bytes from
NVS `0x9000` without resetting the device. It atomically persists the result as
`prewrite-nvs-v1.bin` with mode `0600` in the private transaction root, independently
recalculates its SHA-256, and binds that digest into `latest-v1.json` before issuing
the candidate `write-flash`. A missing, malformed, symlinked, wrongly permissioned,
or digest-mismatched snapshot makes D2 recovery-required before any tool command.
This corrects D0's unsafe assumption that an older full-flash backup necessarily
represented NVS at the moment immediately before the candidate write.

Recovery has its own destructive confirmation. It repeats all local and device
identity checks, then sends one fixed `write-flash` pair from `0x0` to the matching,
validated 8 MiB M4-4C image and leaves the device in ROM mode. Tool completion
creates only `restore-unverified`. A fourth confirmation is required for a complete
8 MiB independent readback and SHA-256 comparison with the recovery source; only
that read uses a watchdog reset and can produce `restored`. Recovery still requires
post-reset functional acceptance.

The latest operation and phase are atomically persisted in
`~/Library/Application Support/VibeStick/FirmwareTransactions.noindex/latest-v1.json`.
The directory is `0700` and journal is `0600`; device fingerprints and backup,
payload, or prewrite-NVS digests are recorded, but raw MAC, Wi-Fi, and pairing
secrets are not placed in the journal. The one device-derived byte range retained
by this transaction is the 24 KiB private NVS snapshot above; it may contain Wi-Fi
or pairing material and therefore must never enter Git, the App/DMG, diagnostics,
or acceptance logs. Temporary reads use private per-operation directories and
`0600` files and are removed on return. Starting a full restore first persists the
`full-restore` journal and then removes the snapshot before writing. An interrupted
temporary path, orphaned or invalid snapshot, incomplete journal, write/readback
mismatch, NVS change, tool failure, or lost completion evidence becomes a
recovery-required state. The App never automatically retries a write, starts
verification, restores a backup, or guesses a target device.

## M4-4D D0.1 acceptance and evidence

- Hostless tests use an in-memory 8 MiB flash model and temporary private backup;
  they cover sector envelopes and NVS rejection, local readiness without a tool
  call, the immediate private NVS snapshot and journal binding, proof that D2 uses
  this snapshot instead of an older backup, invalid-snapshot recovery before any
  tool call, the exact three-offset candidate write, persistent `write-unverified`
  state, three-region plus NVS readback/reset order, mismatch-to-recovery behavior,
  snapshot removal on restore, one-pair full restore plus complete independent
  readback, private modes, forbidden arguments, and `pending_send` blocking before
  any command.
- Source gates require the separate executor, exact payload/restore vectors,
  forbidden argument set, persistent private transaction state, four UI
  confirmations, and continued absence of mutation names from M4-4C.
- App and mounted-DMG gates reject private backups, transaction directories and
  journals. Launch smoke may inspect local payload/backup readiness but cannot
  click a device action, run `esptool`, or change Bridge/HUD process identities.
- D0.1 authorizes only repository source, tests, documentation, and offline build
  acceptance. It does not authorize new serial access, real erase/write/readback,
  recovery, flashing, main-App installation/replacement, or Bridge/HUD/Paste
  restart. Any corrected-candidate real-device phase needs a new, explicit
  authorization.

Current D0 evidence (2026-08-15): 173 Python tests and 71 hostless Swift tests
passed, including the in-memory 8 MiB flash transactions. Release App, Bridge,
HUD and Paste builds, architecture/minimum-OS checks, payload manifests, ad-hoc
signatures, fresh-window GUI smoke, and mounted-DMG content/smoke checks passed.
The `0.2.0 (7)` D0 DMG is 2,847,311 bytes with SHA-256
`89f2c824ef820b12f29d7a6973249385dd29dc85f5be35ad5c22858561f3e7c4`.
Neither the App nor DMG contains a downloaded/extracted tool, private backup,
transaction journal, or device-derived identifier. GUI smoke preserved the live
Bridge/HUD process identities. No serial access or real firmware command occurred.

Separately authorized D1-D4 evidence (2026-08-15): D1 wrote only the three fixed
candidate ranges and left the device in ROM mode. D2 independently read all three
ranges and matched them to the payload, then correctly stopped in
`recovery-required` when NVS differed from the older M4-4C backup used by D0 as its
baseline. No automatic retry or recovery occurred. D3 revalidated the device and
private backup, then wrote the matching validated 8 MiB image once from `0x0`.
D4 independently read the complete 8 MiB and matched the recovery source, then
reset the device. The user subsequently accepted the original display and sent a
voice-input message through the restored firmware. Private fingerprints, image
digests, NVS bytes, and local backup-instance paths are intentionally omitted.

D0.1 corrects the NVS baseline as described above. Its initial offline evidence
(2026-08-15) included 173 Python tests and 73 hostless Swift tests.
Release App, Bridge, HUD and Paste builds, source contracts, architecture/minimum-
OS checks, payload manifests, ad-hoc signatures, fresh-window GUI smoke, and
mounted-DMG content/smoke checks passed. The `0.2.0 (8)` D0.1 DMG is 2,852,368
bytes with SHA-256
`344b8f1768c0ef87d9599f99c0bef195fd86c162dbf0498fd32bd6ec403a6979`.
The private backup, transaction journal, and NVS snapshot are absent from both App
and DMG. GUI smoke preserved Bridge/HUD process identities. No main App was
installed or replaced, no managed component was restarted, no serial path was
accessed, and no firmware command was issued during D0.1.

The later, separately authorized D0.1 device run captured the immediate NVS
snapshot, wrote the three candidate ranges once, and independently read back all
three ranges plus NVS. Every comparison matched. Functional acceptance still
failed because the candidate could not reach the Bridge: read-only diagnosis found
pairing and Bridge values in NVS but no `wifi_ssid` or `wifi_pass`; the restored
stock image had supplied Wi-Fi at compile time. A separately authorized D3/D4 then
wrote the validated M4-4C 8 MiB image once, independently read the complete image
back with a matching digest, and reset the device. The user accepted the original
display and sent a real voice-input message with the device confirmation button.

## M4-4D D0.2 first-Wi-Fi provisioning boundary

D0.2 changes the Mac pairing surface, not the D1/D2 Flash transaction. The
Connection page has an SSID field and a `SecureField` for the current WPA2
password. Both values blank mean preserve the device's existing Wi-Fi; exactly one
blank is invalid. Validation uses the firmware's 1-32-byte UTF-8 SSID and 8-63-byte
printable-ASCII password limits. Editing these fields never opens a serial port.

The draft is converted into immutable credentials only when the user explicitly
starts USB pairing. On accepted submission, the View clears its SSID and password
state immediately. AppModel does not publish or persist either value; the password
exists only in the secure field and one pairing task and must never enter Mac
preferences, logs, transaction journals, diagnostics, tests, the App, or the DMG.

After identify, a schema-2 identity with `wifi_configured:false` and no supplied
credentials throws `wifiCredentialsRequired` before resolving pairing material,
updating the paired-device registry, staging a Keychain item, or sending the pair
command. Supplying credentials to schema 1 remains unsupported. A schema-1 device,
or a configured schema-2 device with both fields blank, retains the compatibility
payload that does not alter stored Wi-Fi.

The real-device order is strict:

1. D1 may capture prewrite NVS and write the fixed candidate ranges only after its
   own authorization.
2. D2 must compare candidate ranges and the pre-pairing NVS snapshot, then reset.
3. First Wi-Fi provisioning is a new normal-firmware USB pairing mutation with a
   new authorization. It must not run before D2 or its intended NVS change would
   invalidate the D2 preservation proof.
4. Network discovery, Bridge authentication, display, voice, and confirmation-send
   acceptance remain a separate functional gate. D3/D4 recovery is never inferred
   from a pairing or functional failure.

The initial D0.2 repository authorization covered only source, tests,
documentation, and offline build acceptance. It did not authorize serial access,
pairing, Wi-Fi transmission, candidate write/readback, recovery, main-App
installation, service restart, or Git publication. Every later device phase was
separately authorized.

The `0.2.0 (9)` D0.2 candidate passed 173 Python tests, 75 Swift tests, the
fail-closed/ephemeral-Wi-Fi source contract, Release App/Bridge/HUD/Paste builds,
arm64 and macOS 15 deployment checks, payload digests, ad-hoc signatures, built-App
GUI smoke, and mounted-DMG content and GUI smoke. The DMG is 2,867,457 bytes with
SHA-256 `029d651794e3a73d32ad04d50bf30313c8406437c822ca1f6bb59e6a329bd761`.
Neither the App nor DMG contains Wi-Fi credentials, tool archives, extracted tools,
private device backups, NVS snapshots, transaction directories, or journals. The
smoke checks did not change the Bridge or HUD process identity. The installed main
App remained `0.2.0 (3)`; this initial offline phase did not access serial, pair,
transmit Wi-Fi credentials, run a firmware command, restart Bridge/HUD/Paste, or
perform Git publication.

## M4-4D D0.2 real-device acceptance

The later device acceptance preserved the required phase separation:

1. Separately authorized D1 revalidated the unique StickS3, pinned tool, candidate
   payload, and matching M4-4C private recovery source. It captured exactly 24 KiB
   of prewrite NVS with mode `0600`, independently bound its digest into the
   private journal, issued one three-range write at `0x0`, `0x8000`, and `0x10000`,
   and stopped at `write-unverified` without reset, retry, or independent readback.
2. Separately authorized D2 revalidated the same device, read the three candidate
   ranges and NVS independently, matched every candidate digest and the immediate
   NVS snapshot, persisted `candidate-verification/verified`, and reset only after
   the final NVS read.
3. Separately authorized P0 launched the repository-built `0.2.0 (9)` App without
   installation and performed read-only USB enumeration and identify. The normal
   firmware reported protocol 2, pairing schema 2, and `wifi_configured:false`;
   no pair command, registry update, or Keychain update occurred in P0.
4. The user entered the 2.4 GHz credentials directly into the App's secure pairing
   fields and personally submitted one pair/provision action. The App updated the
   private Mac device registry and Keychain as designed, the device restarted, and
   the candidate authenticated to the existing Bridge over Wi-Fi.
5. Functional acceptance used real StickS3 PCM audio, the configured ASR path,
   Paste injection, and the user's physical blue-button confirmation. The Bridge
   returned HTTP 200 for the confirmation request, persisted the session from
   `pending_send` to `sent`, and continued to report the candidate online.

No recovery was needed. The installed main App remained `0.2.0 (3)`; the candidate
App ran only from the repository build. Bridge and HUD retained the same process
identities and were not restarted. Repository evidence excludes the SSID, Wi-Fi
password, device and Bridge identifiers, serial path, local address, private backup
and NVS digests, and transcript text. No add, commit, push, tag, or Release operation
was performed. The documentation-only closeout then reran 173 Python tests and 75
Swift tests, plus shell syntax, diff-format, and targeted redaction checks, without
serial access or a device tool invocation.

## M4-5A contract freeze and inert planning boundary

M4-5A defines the remaining M4 behavior before any live migration, diagnostic
export, or clean-machine mutation is implemented. Its source layer is deliberately
pure: callers supply redacted categories and boolean facts, and the planners return
deterministic plans. The planning layer has no filesystem, Keychain, process,
network, serial, firmware-tool, App-installation, or service-control dependency.

M4-5A may add repository source, documentation, and fictional test fixtures. The
fixtures must contain no values copied from the maintainer Mac, no real identifier,
credential, host, path, transcript, log line, device receipt, backup digest, or
firmware bytes. Merely adding the planning layer does not expose a live migration or
diagnostic-export button and does not change App startup behavior.

The planning vocabulary covers three later workflows:

1. Legacy discovery and migration.
2. Allowlisted, redacted diagnostic export.
3. Clean-machine readiness without Homebrew, Xcode, an external Python, or ESP-IDF.

The authorization vocabulary is also executable contract data. Each authorization
implies only itself; position in the list never grants a later action.

## M4-5 legacy discovery boundary

Discovery is read-only and returns categories, warnings, and blockers rather than
source values. The complete initial category set is:

- installed Bridge, HUD, and Paste runtime components;
- the legacy Bridge credential;
- legacy ASR credentials and non-secret ASR configuration;
- the active agent provider;
- project display configuration;
- voice paste, confirmation, or automatic-send behavior;
- sound or mute preference when the old format can represent it;
- the existing Paste Accessibility state.

Discovery must not display, log, persist, hash for correlation, or return to the UI
any credential, Wi-Fi value, OAuth token, full local path, device/Bridge identifier,
transcript, recording, or firmware digest. It may report that a secret category is
present and that a legacy file has over-broad permissions. It must not change those
permissions during discovery.

An active recording/transcription/pending-send operation or a loaded runtime with
unknown ownership blocks migration. A known legacy component path may be offered for
migration only after its identity and expected files have been specified in the
implementation contract. M4-5 must retain the M4-1 rule that an external Bridge or
unrecognized port owner is never taken over.

## M4-5 legacy migration transaction

The first live migration implementation must preserve this order:

1. Present the redacted category summary and any blockers.
2. Obtain an import confirmation that names the categories and owned targets.
3. Re-run the read-only preflight and fail closed if ownership or voice activity
   changed.
4. Create a private `0700` rollback directory containing only the non-Keychain files
   required to restore the old configuration. Files are `0600`; the backup never
   enters the App, DMG, diagnostics, tests, or Git.
5. Stage credentials in new versioned Keychain accounts and stage non-secret
   configuration in new files. Existing Keychain items are not overwritten or
   deleted during staging.
6. Decode and compare the staged documents and verify that no secret field entered a
   non-Keychain file.
7. Atomically switch the non-secret configuration to the staged Keychain accounts.
8. Retain the legacy files and rollback directory until activation and functional
   acceptance succeed.

Migration import does not stop, start, or restart Bridge, HUD, or Paste. It does not
delete or rewrite `.env`, remove an old Keychain item, replace the main App, download
a component, access a serial port, pair a device, transmit Wi-Fi credentials, or run
a firmware command. Runtime activation is a new confirmation with a second safety
preflight. Failed activation restores the previous configuration and service state;
it does not silently retry.

Paste Accessibility permission is not transferable application data. Migration may
preserve an unchanged Paste identity and re-check the permission, but macOS approval
must still be performed by the user. A missing permission is never treated as
successful migration or as permission to replace Paste.

## M4-5 redacted diagnostic contract

A diagnostic bundle is created only after a separate export confirmation and is
written only to a user-selected local destination. There is no upload, telemetry,
background export, clipboard copy, or support-server endpoint.

The schema-1 allowlist may contain only newly generated structured summaries of:

- App, macOS, and architecture versions;
- Bridge, HUD, and Paste health and signature status;
- LaunchAgent loaded/running states without full local program paths;
- the expected Bridge health result without network addresses or identities;
- redacted migration and runtime-install receipt outcomes;
- bounded Bridge/HUD excerpts only after each line passes the M4-5 redactor.

Raw `.env`, preferences, device registries, device configuration, Bridge identity,
Keychain values, recordings, transcripts, logs, firmware backups, NVS snapshots,
transaction journals, private receipts, and full local paths are denylisted sources.
A redacted excerpt must replace credentials, authorization headers, Wi-Fi values,
user/home paths, IP and MAC addresses, device/Bridge/session identifiers, UUIDs, and
speech text with non-correlating placeholders. If parsing, redaction, allowlist, path,
permission, or final validation fails, no diagnostic archive becomes available.

Staging directories are `0700` and files are `0600`. Every output entry has a fixed
relative path and appears in a previewed manifest before the final atomic move. The
bundle contains neither the source filename nor an absolute source path. Ordinary
diagnostic planning and preview never access serial, execute the flashing tool,
restart a service, or mutate configuration.

## M4-5 clean-machine contract

> Historical design note: the packaged-Python approach below describes the
> M4-5K baseline. It is superseded for `0.2.0 RC 1` by the native-Bridge
> amendment at the end of this document; the acceptance and authorization gates
> remain in force.

The acceptance Mac is Apple Silicon on the supported macOS baseline and begins with
no VibeStick data, App, LaunchAgents, Homebrew, Xcode, external Python, or ESP-IDF.
The distributed App must therefore carry a self-contained arm64 Python runtime. The
runtime is a versioned payload with pinned provenance, license inventory, exact file
set, sizes, modes, SHA-256 digests, architecture, and minimum-macOS checks. It is
validated before any service stops or managed path changes.

The installed Bridge launcher must execute only the verified interpreter inside the
managed runtime. It must not search Homebrew, `/usr/local`, `/usr/bin/python3`, Xcode,
the shell `PATH`, or a repository checkout as a distributed fallback. Building the
release payload may remain a maintainer workflow; using the release may not require a
terminal or developer environment.

First launch is inspection-only. The graphical guide may explain the next action but
must not install the runtime, enable login, request Accessibility, download or prepare
the flashing tool, enumerate/open serial, pair, provision Wi-Fi, write firmware, or
start recovery without the matching confirmation.

Clean-machine acceptance separates at least these gates:

1. Install or replace the main App.
2. Install and start the self-contained runtime.
3. Perform the user's macOS Accessibility decision.
4. Download the pinned flashing-tool archive.
5. Prepare and version-check that tool without device access.
6. Inspect the device.
7. Create a private full backup.
8. Write the candidate ranges.
9. Independently read them back.
10. Pair and provision Wi-Fi.
11. Perform functional acceptance.
12. Write a recovery image, if authorized.
13. Independently read the recovery image back.

The required non-destructive recovery acceptance is a deterministic M4-2 transaction
fault followed by verified automatic rollback on the clean Mac. A real firmware
recovery is additional evidence and continues to require the separate M4-4D recovery
write and readback confirmations; it is never induced implicitly to satisfy a test.

## M4-5 authorization order

The complete M4-5 authorization sequence is:

1. Repository implementation.
2. Local tests and offline App/DMG build.
3. Live read-only legacy inspection.
4. Live migration transaction.
5. Runtime activation and functional migration check.
6. Local diagnostic export.
7. Main-App installation on the named clean Mac.
8. Runtime installation on that Mac.
9. Tool download.
10. Tool preparation.
11. Device inspection.
12. Device backup.
13. Candidate write.
14. Candidate independent readback.
15. Pairing and Wi-Fi provisioning.
16. Functional acceptance.
17. Recovery write.
18. Recovery independent readback.
19. Local Git checkpoint.
20. Push.
21. Tag.
22. Release.

No entry authorizes a later entry. In particular, repository implementation does not
authorize tests/builds; tests/builds do not authorize live-data inspection; inspection
does not authorize migration; migration does not authorize runtime activation; export
does not authorize upload; and no Git checkpoint authorizes publication.

## M4-5A acceptance

- Pure hostless tests use typed fictional discoveries and clean-machine profiles.
- Planning tests cover complete migration categories, unknown ownership, active voice
  work, rollback staging, separate runtime activation, diagnostic allow/denylists,
  safe relative paths, absent developer dependencies, self-contained runtime
  requirements, and non-inheriting authorization gates.
- The planning source contains no live inspector, exporter, migration executor,
  runtime installer, Keychain write, process control, network client, serial path, or
  firmware command.
- App startup and UI remain unchanged; no live action is exposed in M4-5A.
- Tests and offline builds require the second authorization gate; all live acceptance
  remains behind its later, individually named gate.

Current M4-5A offline evidence (2026-08-15): after the second gate was explicitly
authorized, 173 Python tests and 82 hostless Swift tests passed. The Release App,
Bridge, HUD, and Paste binaries are thin arm64 with a macOS 15.0 minimum; runtime and
firmware manifests, exact firmware-binary scope, local-secret exclusion, stable Paste
identity, forbidden-file scans, and ad-hoc signatures passed for the built App. The
DMG was checksum-verified, mounted read-only, checked to contain only the App and the
`/Applications` link, re-verified for signatures/manifests/secret exclusions, and
detached without launching an executable. It retains version metadata `0.2.0 (9)`, is
2,865,116 bytes, and has SHA-256
`04c93603562a692b872b5a132fa8cbd347c2520caae6ed14d45e6f7eeac43997`.

GUI smoke is intentionally deferred: the existing App startup path reads live support
configuration, Keychain presence, runtime state, and USB summaries, which belongs to
the third live read-only inspection gate. This acceptance did not launch the built or
DMG App, install or replace the main App, restart Bridge/HUD/Paste, inspect legacy
data, access serial or a device, pair or provision Wi-Fi, download or execute a tool,
or read/write/verify/recover firmware.

## M4-5B inert migration transaction implementation

M4-5B implements the migration transaction coordinator without connecting it to the
live Mac or App startup. The production target contains typed protocols for an
already-redacted evidence source and an explicitly authorized transaction store, but
it contains no default filesystem, Keychain, process, network, serial, firmware,
App-installation, or service-control adapter. No UI action invokes the coordinator.

The caller must present the exact redacted discovery and complete category set that
the user confirmed. It must also name every owned target required by those categories:
the private rollback snapshot, new versioned Keychain accounts, managed non-secret
configuration files, and the existing Paste identity where applicable. Missing or
changed categories and missing owned targets fail before transaction work begins.

The coordinator performs two redacted inspections. The second happens immediately
before the first transaction-store operation. Any category, permission, runtime
ownership, or active-voice change fails closed without creating rollback or staging
state. A permitted transaction then has this fixed order:

1. Prepare the private rollback snapshot.
2. Stage only selected secret categories in new versioned Keychain accounts.
3. Stage only selected non-secret configuration categories.
4. Preserve the existing Paste identity when runtime components are selected.
5. Validate all staged state.
6. Atomically commit the non-secret configuration.
7. Retain the legacy fallback for later activation and functional acceptance.

Validation must independently attest that rollback modes are private, selected
secrets use new versioned accounts, legacy Keychain items remain untouched, no secret
entered staged configuration, and the existing Paste identity was preserved when
selected. Any false required assertion is rejected before commit and rolled back.

Every transaction-store failure invokes one restore-and-discard operation exactly
once; there is no automatic retry. A rollback failure is returned as a typed redacted
operation error without propagating the underlying error text. A successful receipt
contains categories, completed operation names, and safety booleans only. It records
that legacy items were not deleted, the runtime was not restarted, and runtime
activation remains both required and unauthorized.

Current M4-5B offline evidence (2026-08-17): nine new fictional tests cover the
typed redacted inspector, exact double preflight, separate activation, changed live
facts, owned-target authorization, staging rollback, commit rollback, and rollback
failure redaction, including rejection of secrets in staged configuration. The
complete hostless Swift suite passes 91 tests in three suites.
The test build used a temporary derived-data directory and did not launch the App,
read live configuration or Keychain data, access runtime services or USB/serial,
install anything, or execute a migration.

## M4-5C offline adapters and versioned credential references

M4-5C gives the inert coordinator a concrete adapter that is still incapable of a
live migration. `M4OfflineMigrationTransactionStore` rejects every filesystem root
outside the process temporary directory. It accepts only an injected, protocol-based
credential vault and has no default Keychain implementation. It does not discover a
home or Application Support directory, inspect a process, start an App, control a
service, access a network or serial path, or install anything.

The non-secret runtime document is `managed-runtime-v1.json`, schema 1. Credential
references are fixed to service `io.github.hanminyin.vibestick`, storage
`macos-keychain`, and new accounts `bridge-token-v1` and `asr-api-key-v1`. Arbitrary,
legacy, duplicate, or differently versioned references are rejected. Secret bytes
are supplied only to the injected vault and are scanned out of the encoded runtime
document before staging or commit.

The offline store creates a 0700 rollback directory and 0600 rollback files, refuses
to reuse an existing transaction root, stages a private configuration, validates the
new accounts and unchanged legacy-vault assertion, preserves the supplied fictional
Paste identity, commits atomically inside the temporary sandbox, and retains a
secret-free fallback marker. Restore puts back the exact previous sandbox
configuration and discards only the newly staged credential references.

The Bridge package contains the matching pure parser in
`vibe_stick.config.managed_runtime`. It consumes bytes plus an injected credential
reader, accepts only the fixed schema/accounts, fails closed for a missing cloud-ASR
credential, and does not ask for an ASR credential for a local command. It contains
no filesystem, subprocess, Keychain, process, network, serial, or service-control
adapter. M4-5C does not wire this parser into the live Bridge launcher or server.

Current M4-5C offline evidence (2026-08-19): five new Python contract tests and eight
new Swift tests use only fictional values, an in-memory credential vault, and private
temporary directories. The complete suites pass 178 Python tests and 99 hostless
Swift tests in four Swift suites. The isolated Release build then produced the main
App plus Bridge, HUD, and Paste as thin arm64 binaries with a macOS 15.0 minimum. The
App keeps version metadata `0.2.0 (9)`; its deep ad-hoc signature, runtime and firmware
payload manifests, Paste identity fingerprint, icon assets, exact firmware-binary
scope, M4-5C parser inclusion, and forbidden private/developer-file scan all pass.
The DMG checksum verifies and its read-only mounted root contains exactly the App and
the `/Applications` link. The mounted App signature, version, architecture, manifests,
M4-5C parser, firmware scope, and forbidden-file scan pass again without launching an
executable. The DMG is 2,900,641 bytes with SHA-256
`7071af850f5607f41f31a72aaee9505402707a5cd5475260c16ece40dd1f08ff`.

The build and acceptance did not read live configuration or Keychain data, launch an
App, activate or restart Bridge/HUD/Paste, export diagnostics, install anything,
access a device, or perform a Git operation. A real filesystem/Keychain adapter, live
migration, runtime activation, UI exposure, installation, and publication remain
separately authorized future gates.

## M4-5D production filesystem and Keychain adapters

M4-5D implements production-capable storage adapters but does not wire or invoke them.
`M4ProductionMigrationTransactionStore` retains the M4-5B transaction protocol and
accepts only injected `M4MigrationFileSystemAccess` and `M4OfflineCredentialVault`
implementations. Its live factory pins the root to the existing VibeStick Application
Support directory and creates a new safe transaction identifier beneath
`MigrationTransactions.noindex`. All owned paths must remain below that root. The
Foundation client rejects paths outside the authorized root and existing symbolic-link
components, creates transaction directories as 0700, writes files as 0600, and uses an
atomic write for the managed configuration commit and rollback restore.

`M4VersionedKeychainCredentialVault` accepts an injected generic-password client and
allows only the schema-1 service/accounts already frozen by M4-5C. The Security client
uses add-only writes for `bridge-token-v1` and `asr-api-key-v1`; a pre-existing managed
account fails closed instead of being overwritten. The vault never constructs a legacy
account reference and deletes only an item successfully created by its current
transaction. A failed deletion remains tracked so an explicitly invoked recovery can
retry it. Managed credentials trust the current App and Apple `/usr/bin/security`, but
the Security implementation is not called by M4-5D tests or any App startup path.

Current M4-5D repository evidence (2026-08-19): nine new hostless Swift tests use a
pure in-memory filesystem and a pure in-memory generic-password client with fictional
paths, secrets, configuration, and Paste identity. They cover path confinement,
traversal rejection, fixed managed accounts, pre-existing-account refusal, ownership-
scoped deletion, retryable deletion failure, a complete transaction, exact rollback,
private-permission rejection, and pre-mutation category rejection. The complete suites
pass 178 Python tests and 108 hostless Swift tests in five Swift suites. Static scans
confirm that no AppModel, UI, Bridge launcher, runtime manager, or other production
source references the new adapters, while the M4-5D test source contains no
`FileManager`, `SecItem`, `SupportPaths`, `KeychainStore`, or direct file read/write
entry point. The Xcode project passes plist validation and the new Swift source emits no
compiler diagnostic.

The isolated M4-5D Release acceptance then produced the main App plus Bridge, HUD,
and Paste as thin arm64 binaries with a macOS 15.0 minimum. The App retains version
metadata `0.2.0 (9)`; its deep ad-hoc signature, fixed helper requirements, runtime and
firmware payload manifests, Paste identity fingerprint, icon assets, exact three-image
firmware scope, M4-5C parser byte identity, forbidden private/developer-file scan, and
M4-5D production symbols in the main Release binary all pass. The firmware cache was
reused only after its manifest and non-secret source digest matched the current source;
this gate intentionally did not read the local secret header. The DMG checksum verifies,
and its read-only mounted root contains exactly the App and `/Applications` link. The
mounted App passes the signature, version, architecture, manifest, parser, M4-5D symbol,
icon, firmware-scope, and forbidden-file checks again without launching an executable.
The DMG is 2,906,724 bytes with SHA-256
`260ac1a4486e1ad7eb4eaed268b92ec46e53a1792ffdbf994b7b6479976992dc`.

The implementation and isolated Release gate did not read or write live Application
Support data or Keychain items, launch an App, execute a migration, activate or restart
Bridge/HUD/Paste, export diagnostics, install anything, access a device, or perform a
Git operation. Live migration remains authorization gate 4; runtime activation remains
the separate gate 5.

## M4-5E explicit legacy discovery and migration entry

M4-5E connects the frozen planner, double-preflight coordinator, offline payload mapper,
and production transaction-store factory through one explicit entry. Constructing the
entry remains inert. No `AppModel`, view, startup path, Bridge launcher, runtime manager,
or background helper constructs or invokes it, so repository capability does not expose
a migration action or cause discovery at App launch.

The production filesystem reader accepts only four typed legacy sources below the fixed
VibeStick Application Support root: `.env`, `config-v1.json`,
`device-config-v1.json`, and `recording.json`. It has no arbitrary path API, rejects an
unsafe root, escape, symbolic link, non-regular file, changed byte count, and files above
their fixed size limits. The Keychain reader accepts only generic-password items under
service `io.github.hanminyin.vibestick` and the two legacy accounts `bridge-token` and
`asr-api-key`; it has no arbitrary service or account parameter.

Discovery preview reads the fixed non-Keychain sources and typed injected runtime facts,
but calls only Keychain presence checks. It does not request credential data. Its result
contains only detected categories, permission/ownership/active-work booleans, blockers,
and whether import may be offered; paths, values, identities, secret bytes, and error
details are not returned. An incomplete, expanded, or otherwise mismatched confirmation
fails before a prepared migration read.

After an exact confirmation, migration creates a fresh session and performs two prepared
preflights. Those reads may map the fixed legacy inputs and credential contents into an
in-memory `M4OfflineMigrationPayload`, but the production transaction store remains
deferred. Each prepared result must have identical payload/evidence categories; both
redacted discoveries must equal the confirmed preview, remain migration-safe, and equal
each other. Any change fails before the store factory or a filesystem/Keychain mutation.
Only after the second preflight can the payload be consumed once and the existing M4-5D
production transaction store be constructed. Legacy sources remain untouched, and the
success receipt still records that runtime restart and activation did not occur and that
activation requires its separate authorization.

Current M4-5E repository evidence (2026-08-19): nine new hostless Swift tests use only
fictional files, credentials, runtime facts, payloads, and an in-memory transaction
store. They prove the fixed allowlists, secret-free managed mapping, preview redaction,
zero Keychain-content reads during preview, exact confirmation, fresh double preflight,
deferred store creation, changed-preflight refusal, and missing cloud-ASR credential
refusal. The complete suites pass 178 Python tests and 117 hostless Swift tests in six
Swift suites. The Xcode project passes plist validation, Swift 6 compilation succeeds,
the test source has no live filesystem/Keychain entry point, and no App/UI/runtime source
references the new entry outside its definition.

The initial implementation gate did not invoke a production reader or transaction store,
read or write live Application Support or Keychain data, launch an App, execute a
migration, activate or restart Bridge/HUD/Paste, export diagnostics, build a Release App
or DMG, install anything, access a device, or perform a Git operation. Offline Release
App/DMG acceptance, live discovery/migration, and runtime activation therefore remained
separate authorizations.

After a separate offline-Release authorization, the M4-5E source was compiled by the main
Release target and emitted as its own object; the linked App retains the prepared-session
coordination symbols, while static scanning still finds no App, UI, startup, Bridge, or
runtime call site for the explicit entry. The main App, Bridge, HUD, and Paste are thin
arm64 binaries with a macOS 15.0 minimum. The App retains version `0.2.0 (9)`. Its deep
ad-hoc signature, fixed helper requirements, runtime and firmware manifests, managed
runtime parser byte identity, Paste identity fingerprint, App/menu-bar icons, exact
three-image firmware scope, and private/runtime/test/developer-file exclusion all pass.
The firmware cache was reused only after its manifest verified and its non-secret source
digest matched both the current firmware source and cached manifest; this gate did not
read the excluded local secret header.

The M4-5E DMG verifies, and a read-only mount contained exactly the App plus the
`/Applications` link. The mounted App repeated the signature, version, architecture,
minimum-OS, manifest, parser, linked coordination-symbol, icon, firmware-scope, and
forbidden-file checks without launching any executable. The image was then detached. It
is 2,911,227 bytes with SHA-256
`37f8b53afb902039592eacaf3ff36c54b0ea31f3f790d48969b920795a4156cd`.

The offline Release gate did not invoke a production reader or transaction store, read
or write live Application Support or Keychain data, launch an App or helper, execute a
migration, activate or restart Bridge/HUD/Paste, export diagnostics, install anything,
access a device, or perform a Git operation. Live discovery/migration and runtime
activation remain later, separately authorized gates.

## M4-5F explicit migration UI and confirmation flow

M4-5F connects the M4-5E entry to one Advanced Settings card without adding an App
startup, periodic refresh, menu-bar, or background discovery call. Constructing
`AppModel`, `M4LegacyMigrationUIFlow`, its operation builder, and the injected runtime
facts closure is inert. The builder does not create `M4ExplicitLegacyMigrationEntry`
or its fixed filesystem/Keychain readers until the user explicitly chooses
**Check migratable legacy settings**.

The published UI state is a redacted projection rather than the M4-5E prepared payload.
It may contain only typed categories, legacy-file existence/private-permission booleans,
typed blockers, the exact required managed targets, migration-policy booleans, typed
failure stages, and the existing receipt summary. It must not retain or display a
filesystem path, credential value, Paste identity value, underlying error, mapped
configuration value, or rollback artifact. Discovery and migration failures therefore
collapse to separate generic UI failures; retry clears the operation and preview and
requires a new explicit discovery.

When discovery has no blocker and at least one category, the user must independently
select every displayed category and every target computed by
`M4MigrationOwnedTargetPolicy`. Missing items and expanded targets cannot arm the next
step. An exact selection changes the state to awaiting final confirmation and presents
a separate confirmation dialog. Cancelling it returns to review without calling
`migrate`. Confirming it passes only the exact category/target sets to the M4-5E entry,
which still performs its fresh double preflight before constructing the production
transaction store. The UI does not call runtime start, restart, activation, diagnostics,
installation, device, or firmware APIs. A successful receipt explicitly reports that
legacy fallback was retained, legacy items were not deleted, runtime was not restarted,
and runtime activation remains separately unauthorized and required.

The explicit runtime-facts path refreshes Bridge/HUD ownership and active recording
state without launching the Paste permission probe. Paste Accessibility therefore stays
unknown during migration discovery and remains a later permission/activation check.
External or conflicting runtime ownership counts as an observed runtime and fails closed
even when no compatible managed LaunchAgent is installed.

Current M4-5F repository evidence (2026-08-19): ten new Swift tests use injected
fictional operations, builders, and runtime snapshots only. They prove zero operation
construction or calls at flow initialization, fail-closed external-runtime mapping, one
construction after an explicit discovery, redacted review state, exact-selection
enforcement, cancellable final confirmation, blocker refusal, generic discovery/migration
failures that omit secret/path sentinels, a receipt with no runtime activation, and a
fresh operation build after reset. The complete hostless run passes 127 Swift tests in
seven suites; 178 Python tests also pass. Both the test target
and the main Debug App target compile offline, the Xcode project passes plist validation,
and static call-site inspection finds discovery/migration actions only in the explicit
Advanced Settings controls, never in App startup or refresh. The App was not launched.

This implementation gate did not call the production entry or its filesystem, Keychain,
runtime, or transaction adapters; read or write live Application Support or Keychain
data; execute a migration; activate or restart Bridge/HUD/Paste; export diagnostics;
build a Release App or DMG; install anything; access a device; or perform a Git
operation. Any live discovery/migration execution and all runtime activation remain
separately authorized actions.

After a separate offline-Release authorization, M4-5F was built in the isolated
`.build/macos.noindex/M4-5F-Offline` tree. The main App and the Bridge, HUD, and Paste
components are thin arm64 binaries with a macOS 15.0 minimum; the App remains version
`0.2.0 (9)`. Release intermediates contain `M4MigrationUIFlow.o`, and the linked main
binary retains the explicit UI-flow, delayed production-builder, M4-5E entry, and
prepared double-preflight session symbols. No binary was executed.

The App's deep ad-hoc signature, each component's fixed designated requirement, runtime
and firmware manifests, byte-identical packaged `managed_runtime.py`, Paste build
fingerprint, icons, exact three-image firmware scope, and private/runtime/test/developer
file exclusions all pass. The firmware cache was reused only after its manifest passed,
the current non-secret firmware source digest matched both cached digest records, and
all three images plus the manifest were byte-identical to the previously accepted M4-5E
payload. This acceptance did not read the excluded local secret header and did not call
Git.

The M4-5F DMG passes `hdiutil verify`. It was attached with read-only and no-browse
options; the mounted filesystem reported `read-only`, and its root contained exactly the
App and the `/Applications` link. The mounted App repeated signature, version,
architecture, minimum-OS, runtime/firmware manifest, managed parser, M4-5F linked-symbol,
firmware-scope, and forbidden-file checks without executing an App or helper. The image
was then detached and its temporary mount point removed. The complete hostless suites
also pass again: 127 Swift tests in seven suites and 178 Python tests. The artifact is
`.build/macos.noindex/M4-5F-Offline/VibeStick-for-Mac-M4-5F.dmg`, 2,950,894 bytes, with
SHA-256 `ec9b799a97bacecf3cb410b7703d324977a31c4b330558354e59b9d5722c8e77`.

This offline Release gate did not launch the App or a helper, call a production migration
reader/store, read live Application Support or Keychain data, execute discovery or
migration, activate or restart Bridge/HUD/Paste, export diagnostics, install anything,
access a device, or perform a Git operation. Live discovery/migration and runtime
activation remain separate authorization gates.

## M4-5G redacted ASR conflict resolution

M4-5G adds one fail-closed branch for the case where both the current App preferences
and the legacy `.env` contain ASR configuration and their mapped configurations differ.
Discovery publishes only a fixed conflict object whose complete source set is
`currentApp` and `legacyEnvironment`. The UI renders those values only as **Current App
configuration** and **Legacy .env configuration**. Neither the discovery model nor the
UI review state may retain or display provider parameters, endpoints, model names, local
commands, credential contents, or the mapped configuration values.

There is no default source. A conflict requires the user to select exactly one of the
two fixed sources before the final confirmation can be armed. A missing or unknown
selection is rejected before a prepared read. Conversely, when discovery reports no
conflict, an injected source selection is also rejected. The selected source changes
only which ASR configuration is mapped into the prepared payload; credential handling,
confirmed categories, required managed targets, blockers, and runtime-activation policy
remain governed by the existing M4-5E/M4-5F contracts.

The selected source is captured by the prepared migration session and passed unchanged
to both fresh preflights. Each prepared result must report that it resolved the same
source. A missing, different, or second-preflight-drifted source fails as an inspection
error before the production transaction factory is created and before any transaction
operation can run. The normal M4-5E comparison still requires the complete second
discovery to match the first preflight before mutation.

Current M4-5G repository evidence (2026-08-19): five new Swift tests use only fictional
files, simulated Keychain/runtime readers, injected UI operations, and in-memory
transaction stores. They cover redacted conflict discovery without credential-content
reads, both explicit source mappings, selection required before reads, identical source
binding across both preflights, second-preflight source drift before factory creation,
and explicit UI selection before final confirmation. The complete hostless run passes
132 Swift tests in seven suites, and 178 Python tests pass. The test target and main
Debug App target compile offline; project plist, explicit-call-site, whitespace, and UI
forbidden-value scans pass. No App or helper was launched.

This implementation gate did not call the production filesystem, Keychain, runtime, or
transaction adapters; read or write live Application Support or Keychain data; execute
live discovery or migration; activate or restart Bridge/HUD/Paste; export diagnostics;
build a Release App or DMG; install anything; access a device; or perform a Git
operation. Offline Release/DMG acceptance, live execution, and runtime activation remain
separately authorized gates.

After a separate offline-Release authorization, M4-5G was built under the isolated
`.build/macos.noindex/M4-5G-Offline` tree. The main App, Bridge, HUD, and Paste are thin
arm64 binaries with a macOS 15.0 minimum, and the App remains `0.2.0 (9)`. Release
intermediates contain both `M4LiveMigrationEntry.o` and `M4MigrationUIFlow.o`; the linked
binary retains the prepared migration session, explicit ASR-source selection method,
and the three redacted conflict/source UI text fragments.

The App's deep ad-hoc signature, all three fixed helper designated requirements,
runtime and firmware manifests, byte-identical packaged `managed_runtime.py`, Paste
identity fingerprint, App/menu-bar icons, exact three-image firmware scope, and
private/runtime/test/developer-file exclusions pass. The firmware cache was reused only
after its manifest passed, the current non-secret firmware-source digest matched the
cached digest and manifest, and all three images plus the manifest were byte-identical
to the previously accepted M4-5F App payload. This gate did not read the excluded local
secret header and did not invoke Git.

The M4-5G DMG passes `hdiutil verify`. It was attached read-only and without browsing;
the mounted filesystem reported `read-only`, and its root contained exactly the App and
the `/Applications` link. The mounted App repeated version, architecture, minimum-OS,
signature, helper identity, runtime/firmware manifest, managed parser, M4-5G linked
symbol/text, icon, firmware-scope, and forbidden-file checks without executing any
binary. The image was then detached and its mount point removed. The complete hostless
suites pass again: 132 Swift tests in seven suites and 178 Python tests. The artifact is
`.build/macos.noindex/M4-5G-Offline/VibeStick-for-Mac-M4-5G.dmg`, 2,963,095 bytes, with
SHA-256 `bb7889cc4029c69038381a219e2cd35bd2725da8a5a76744c564410b4d214a98`.

This offline Release gate did not launch the App or a helper, call a production
migration reader/store, read live Application Support or Keychain data, execute live
discovery or migration, activate or restart Bridge/HUD/Paste, export diagnostics,
install anything, access a device, or perform a Git operation. Live discovery,
migration, and runtime activation remain separate authorization gates.

## M4-5H post-migration managed status card

M4-5H separates the compatibility summary for the unversioned legacy accounts from a
new redacted managed-runtime summary. The existing `.env`, `bridge-token`, and
`asr-api-key` observations remain explicitly labelled as legacy compatibility state.
They are never used as evidence that the versioned migration targets exist.

The managed summary first reads only the fixed `managed-runtime-v1.json` location. The
production reader accepts an existing regular file only when it is non-empty, bounded
to 1 MiB, and has no group or other permission bits. It then decodes and validates the
versioned configuration contract. Missing, invalid, unsafe, or unavailable input is
collapsed into fixed typed states that carry no path, account, parameter, underlying
error, or configuration value.

Managed credential inspection depends on a narrow presence-only protocol. Its only
operation is `contains(M4VersionedCredentialReference)`; it has no secret-read method.
The inspector queries only references that survived configuration validation, so an
absent or invalid configuration causes zero Keychain queries. The production presence
implementation accepts only the fixed managed references enforced by the existing
M4-5D client. UI copy never renders their account or service strings.

`AppModel` stores the legacy and managed summaries separately. A normal refresh may
update both, but a successful explicit migration invokes a dedicated completion handler
that refreshes only the managed summary. It does not trigger the broader Bridge,
runtime, USB, or permission refresh and cannot activate or restart any component. The
Advanced Settings card renders separate **Legacy compatibility state** and
**Post-migration managed state** sections. A validated configuration whose Bridge and
ASR references both pass presence checks shows both managed credentials as stored.

Current M4-5H repository evidence (2026-08-19): six new Swift tests use temporary
directories, fictional configurations, simulated presence-only Keychain clients, and
an injected migration-completion refresh. They cover no configuration/zero Keychain
queries, two stored fixed references, one missing reference, invalid input redaction,
overexposed-file refusal, and exactly one post-success managed refresh. Together with
the M4-5G final-confirmation detail test, the complete hostless run passes 139 Swift
tests in seven suites; 178 Python tests also pass. The main Debug App target compiles,
the Xcode project plist and UI forbidden-value scans pass, and no temporary M4-5H
fixture remains. The App and helpers were not launched. Xcode's isolated Debug-product
Launch Services registration was removed by exact build path after compilation.

This implementation gate did not instantiate the live status inspector, read or write
live Application Support or Keychain data, alter the retained migration transaction,
execute a migration, activate or restart Bridge/HUD/Paste, export diagnostics, build a
Release App or DMG, install an App, access a device, or perform a Git operation. Offline
Release/DMG acceptance, GUI verification, runtime activation, installation, and
publication remain separate authorization gates.

## M4-5I managed Bridge startup injection

M4-5I connects the versioned runtime document to the Bridge startup boundary without
activating a real runtime. The Swift Bridge wrapper checks only the fixed
`managed-runtime-v1.json` location before it can load compatibility configuration. If
the managed document exists, the wrapper sets one non-secret startup-selection marker
and does not parse `.env`. Only an absent managed document permits the existing `.env`
compatibility path. The Python bootstrap repeats and freezes that selection: a managed
document disappearing after selection, or appearing after legacy selection, stops
startup rather than crossing modes.

The production file reader opens the fixed document with no-follow and close-on-exec
semantics. It accepts only a regular, non-empty file of at most 1 MiB with no group or
other permission bits, and requires device, inode, size, and modification time to stay
stable across the bounded read. Every filesystem failure collapses to a fixed typed
error. The Keychain adapter accepts only service
`io.github.hanminyin.vibestick` and accounts `bridge-token-v1` and
`asr-api-key-v1`; the secret is returned from the fixed `security` query only into
process memory. Command arguments contain no secret, and return status, stderr, paths,
and underlying exception text are never propagated to the Bridge startup error.

Parsing validates schema 1, fixed credential references, ASR fields, Agent provider,
project-presentation field types, voice-delivery mode, and sound preference before
resolving credentials. A missing, empty, or known-placeholder Bridge credential fails
closed. Cloud ASR requires its versioned credential; local-command ASR retains the
already accepted M4-5C rule that no cloud credential is requested. Invalid input,
missing required credentials, or any read failure exits before `BridgeStateStore` or
the HTTP server is created. There is no fallback to `.env`, environment ASR/token
values, App configuration, or the unversioned Keychain accounts once managed startup
has been selected.

Resolved values are injected directly: the managed Bridge token closes over request
authentication, Agent selection bypasses the legacy environment, ASR configuration and
its credential are passed to the transcription adapter, voice delivery is passed to
the recording controller, and project presentation overrides only the legacy project
fields while preserving the other normalized device settings. `soundEnabled` remains
typed in the resolved startup model because the current Bridge has no sound-preference
consumer; it is not translated into an environment variable or written to a file. The
only new environment value is the non-secret managed/legacy selection marker. A final
defensive redaction removes the in-memory managed ASR key if a lower-level provider
error were ever to echo it.

Current M4-5I repository evidence (2026-08-19): fifteen new Python tests use only
temporary directories, fictional documents and secrets, simulated Keychain commands,
mocked ASR/runtime dependencies, and a mocked server start. They cover missing-only
legacy fallback, frozen-mode races, file type/permission/symlink/size rejection, fixed
Keychain scope, invalid and missing configuration, placeholder Bridge credentials,
secret-free failures, no environment mutation, legacy-source bypass, project override,
managed ASR error redaction, and stop-before-server behavior. The complete Python suite
passes 193 tests. The unchanged complete hostless Swift suite passes 139 tests in seven
suites. Isolated Debug builds compile the Bridge and main App test target; the Bridge
binary is arm64 with macOS 15.0 minimum, and its compiled payload retains the managed
selection marker, managed filename, and compatibility branch. Runtime payload assembly
copies every Bridge Python module, including the new bootstrap adapter.

This implementation and test gate did not invoke the production file or Keychain
adapters against the current Mac, read or write live configuration or credentials,
launch the App or a helper, start or restart Bridge/HUD/Paste, activate a runtime,
export diagnostics, build a Release App or DMG, install anything, download anything,
access a device, or perform a Git operation. Offline Release/DMG acceptance, real
runtime activation, installation, clean-machine validation, and publication remain
separate authorization gates.

After separate authorization, the M4-5I offline Release was built under the isolated
`.build/macos.noindex/M4-5I-Offline` tree. The main App, Bridge, HUD, and Paste are thin
arm64 binaries with a macOS 15.0 minimum, and the App remains `0.2.0 (9)`. Deep ad-hoc
signature verification, the three fixed helper designated requirements, runtime and
firmware manifests, byte identity for every packaged Bridge Python source, the compiled
managed-selection filename/marker, App and menu-bar icons, Paste identity fingerprint,
exact three-image firmware scope, and private/test/developer-file exclusion all pass.

Firmware reuse required the current non-secret source digest to equal the cache digest
and all four cached payload files to be byte-identical to the previously accepted
M4-5H App payload. This avoided reading the excluded local secret header, rebuilding
firmware, or consulting Git. The complete 193-test Python suite and unchanged 139-test,
seven-suite hostless Swift run pass again.

The DMG verifies and was attached read-only without browsing. Its root contains exactly
the App and `/Applications` link, and the mounted App repeats the version, architecture,
minimum-OS, signature, helper identity, both manifests, source/firmware payload identity,
M4-5I compiled marker, and forbidden-file checks. No executable in the image was run.
The image was detached and its mount point removed. The artifact is
`.build/macos.noindex/M4-5I-Offline/VibeStick-for-Mac-M4-5I.dmg`, 2,978,616 bytes, with
SHA-256 `f2a7dd52286ceec5b6a7fb84d801e7ee99ac7f532537ef60b3f72a8f758e6548`.

This offline Release gate did not launch the App, Bridge, or any helper, read live
configuration or Keychain data, activate or restart Bridge/HUD/Paste, install anything,
export diagnostics, download anything, access a device, or perform a Git operation.
Candidate startup, real managed-runtime activation, installation, clean-machine
validation, and publication remain separate authorization gates.

## M4-5J redacted diagnostic bundle transaction

M4-5J implements the earlier diagnostic plan as an explicit local-only, fail-closed
transaction. Its schema-1 structured evidence is limited to validated App, macOS, and
architecture metadata; Bridge/HUD/Paste health and signature booleans; LaunchAgent
loaded, running, and current-user ownership booleans; the fixed Bridge-health enum; and
redacted migration/runtime receipt summaries. Evidence is supplied through an injected
reader. The compiled production filesystem transaction has no App-startup or UI call
site, and this gate does not provide or invoke a live evidence reader.

Optional logs are limited to Bridge and HUD line sources. Each line is rejected if it
contains a newline or exceeds 8 KiB, then a fixed redactor replaces Wi-Fi values,
Authorization and credential fields, speech/transcript text, device/Bridge/session
identifiers, URLs/endpoints, user and system paths, MAC/IP addresses, UUIDs, email
addresses, and long token-shaped values. A redacted line is capped at 512 characters;
an excerpt reads at most 200 source lines and emits at most 32 KiB with a fixed
truncation marker. The preview manifest uses only fixed relative paths, typed sources,
and byte counts and explicitly records that raw logs and automatic upload are absent.

Export requires both a caller assertion that the destination was user-selected and an
exact match to the previewed manifest. The Foundation transaction accepts only the
caller-supplied local destination root, rejects a missing/non-directory/root/symlink
destination, escape or symlink components, and existing staging or final bundles. It
creates a same-directory private staging tree with 0700 directories and 0600 files,
then revalidates the exact entry set, source types, bytes, manifest, permissions, and
absence of symlinks before an atomic move publishes the `.vibediagnostics` bundle. A
failure cleans staging and publishes nothing; an existing final bundle is never
overwritten.

Repository evidence on 2026-08-19: ten new Swift tests use only temporary directories,
fictional summaries and logs, a simulated runtime evidence reader, and an injected
filesystem. They cover every redaction category including quoted JSON keys, no-log
zero reads, bounded excerpts, unsafe metadata and oversized-line failure, exact bytes
and 0700/0600 permissions, both confirmation gates with zero mutation, rollback and
staging cleanup, no overwrite, and symlink rejection. The complete Swift result is 149
tests in eight suites; the complete Python result remains 193 tests. The main App Debug
target and test target compile offline under Swift 6, and the project plist,
startup-call-site, forbidden-runtime-API, private-value, and fixture-cleanup scans pass.

This implementation gate did not read live configuration, Keychain, logs, recordings,
device registration, migration transactions, firmware backups, or identity values. It
did not launch the App or a helper, perform a real preview/export, upload, control a
runtime, install anything, access a device, or perform a Git operation. Offline
Release/DMG acceptance, a production evidence reader, GUI wiring, and any real local
preview/export remain separate authorization gates.

After separate authorization, the M4-5J offline Release was built under the isolated
`.build/macos.noindex/M4-5J-Offline` tree. The main App, Bridge, HUD, and Paste are thin
arm64 binaries with a macOS 15.0 minimum, and the App remains `0.2.0 (9)`. Deep ad-hoc
signature verification, all three fixed helper designated requirements, runtime and
firmware manifests, byte identity for every packaged Bridge Python source, Paste's
stable identity fingerprint, the App icon, exact three-image firmware scope, and
private/log/recording/transaction/test/developer-file exclusions all pass. The Release
intermediate contains `M4DiagnosticExport.o`, its link list includes that object, and
the final App binary retains the M4-5J diagnostic export transaction symbols.

Firmware reuse required the current non-secret source digest to equal the previously
accepted M4-5I manifest digest. The copied manifest and all three images are
byte-identical to that accepted payload. This avoided reading the excluded local
secret header, rebuilding firmware, or consulting Git. The complete 193-test Python
suite and 149-test, eight-suite hostless Swift run pass again.

The DMG verifies and was attached read-only without browsing. Its root contains exactly
the App and `/Applications` link. The mounted App repeats the version, architecture,
minimum-OS, signature, fixed helper identity, both manifests, packaged Python source,
M4-5J linked-symbol, firmware scope, and forbidden-file checks. No executable in the
image was run. The image was detached and its mount point removed. The artifact is
`.build/macos.noindex/M4-5J-Offline/VibeStick-for-Mac-M4-5J.dmg`, 2,981,164 bytes, with
SHA-256 `48207ff56ac7e7339d08c1a0d73bcd7ed8daff85e95bcbace5742582414eafd9`.

This offline Release gate did not launch the App or a helper; read live configuration,
Keychain, logs, recordings, device registration, migration transactions, firmware
backups, or identity values; perform a real diagnostic preview/export or upload;
control a runtime; install anything; access a device; or perform a Git operation. A
production evidence reader, GUI wiring, and any real local preview/export remain
separate authorization gates.

## M4-5K explicit diagnostic preview and local export UI

M4-5K connects the M4-5J local transaction to an explicit Advanced Settings card and
adds a fixed-scope production read adapter. Construction remains inert. The structured
source is an actor-backed copy of the AppModel's already-redacted in-memory state and
contains only version, OS, architecture, typed component and LaunchAgent booleans,
Bridge health, and redacted migration/runtime receipts. A fixed Bridge/HUD/Paste code
signature reader contributes validity booleans only; it does not publish code paths,
identifiers, certificates, or underlying Security errors.

Optional log input is fixed to the immediate support-directory children `bridge.log`,
`bridge.err.log`, `hud.log`, and `hud.err.log`. The production reader rejects a root or
final-file symlink, path escape, non-regular file, and a source whose device, inode,
size, ctime, or mtime changes during the read. It opens with no-follow semantics and
reads at most a 16 KiB tail and 100 lines per file, with 200 lines combined. Every line
then passes through the M4-5J redactor and its 8 KiB input-line, 512-character output-
line, and 32 KiB total-output limits before it can enter a prepared preview.

No evidence adapter is called on App startup. The user explicitly chooses whether to
include redacted excerpts and requests preparation. The UI publishes only schema 1,
fixed relative bundle paths, source kinds, byte counts, and the raw-log/no-upload
booleans. Destination selection is a separate local directory panel; the selected URL
stays private rather than entering observable state. A second confirmation shows the
frozen entry count, total bytes, excerpt choice, absence of raw logs, and absence of
automatic upload. Only that confirmation can submit the prepared bytes, exact manifest,
and user-selected destination fact to the M4-5J atomic transaction. Cancellation is
zero-write and all visible failures use fixed redacted categories.

Repository evidence on 2026-08-19: twelve new Swift tests use only temporary
directories, fictional log data, simulated runtime/filesystem/signature readers,
simulated destinations, and injected operations. They cover startup zero calls,
explicit-only preparation, frozen excerpt choice, the exact four bounded source names,
tail and symlink behavior, dropped runtime/Bridge identity details, private destination
state, cancellation, exact final confirmation, one export, and fixed failures. The
complete result is 161 Swift tests in nine suites and 193 Python tests. The main App
Debug and test targets compile offline, the project plist validates, and startup and
forbidden-surface scans pass.

This implementation gate did not call the production adapters, read live configuration,
Keychain, logs, recordings, device registration, migration transactions, firmware
backups, or identity values; launch the App or a helper; perform a real preview/export
or upload; control a runtime; build a Release App or DMG; install anything; access a
device; or perform a Git operation. Offline Release/DMG acceptance and any real GUI
preview/export remain separate authorization gates.

After separate authorization, the M4-5K offline Release was built under the isolated
`.build/macos.noindex/M4-5K-Offline` tree. The main App, Bridge, HUD, and Paste are thin
arm64 binaries with a macOS 15.0 minimum, and the App remains `0.2.0 (9)`. Deep ad-hoc
signature verification, the three fixed designated requirements, runtime and firmware
manifests, byte identity for every packaged Bridge Python source, Paste's stable
fingerprint, App and menu-bar icons, exact three-image firmware scope, and exclusions
for private configuration, logs, recordings, registration, migration/firmware
transactions, backups, tests, and developer files all pass. Release intermediates and
the linked binary retain the M4-5J export transaction and M4-5K UI flow, production
read-only log adapter, explicit preview, destination selection, and confirmation
symbols. Empty `__pycache__` directories introduced by the packaging copy were detected
and removed before the runtime manifest and App signature were regenerated.

Firmware reuse required the current non-secret source digest, the sealed cache digest,
and the accepted M4-5J manifest digest to match. The manifest and all three firmware
images are byte-identical to that accepted payload. This avoided reading the excluded
local secret header, rebuilding firmware, or consulting Git. The complete 193-test
Python suite and 161-test, nine-suite hostless Swift run pass again.

The DMG verifies and was attached read-only and without browsing. Its APFS mount reports
`read-only` and `nobrowse`; the root contains exactly the App and `/Applications` link.
The mounted App repeats the version, architecture, minimum-OS, signature, fixed helper
identity, both manifests, M4-5K linked-symbol, source/firmware identity, icon, exact
firmware scope, and forbidden-file checks. No executable in the image was run. The image
was detached and its mount point removed. The artifact is
`.build/macos.noindex/M4-5K-Offline/VibeStick-for-Mac-M4-5K.dmg`, 3,137,499 bytes, with
SHA-256 `960769a7c9b9ec42586c3ddb4c7b2ad9993a8cac047707da7531930fcf28c450`.

This offline Release gate did not launch the App or a helper, call the production
diagnostic adapters, read live configuration, Keychain, logs, recordings, device
registration, migration transactions, firmware backups, or identity values, perform a
real diagnostic preview/export or upload, control a runtime, install anything, access a
device, or perform a Git operation. Real GUI preview/local export, installation,
clean-machine validation, and publication remain separate authorization gates.

### M4-5K authorized local live closeout

After separate real-preview authorization, only the isolated candidate top-level App
was launched. Advanced Settings retained the log-excerpt option as off and prepared one
real structured preview. Its frozen schema-1 manifest contained three entries totaling
923 bytes: `runtime-v1.json` at 420 bytes, `summary-v1.json` at 411 bytes, and
`system-v1.json` at 92 bytes. Redacted excerpts and raw logs were both excluded, the
four optional log sources remained unread, and automatic upload remained false. No
destination was selected and no export occurred under that authorization.

After independent local-export authorization, a private destination under
`.build/macos.noindex/M4-5K-Real-Diagnostic-Export` was selected and the exact frozen
summary was confirmed once. The resulting `.vibediagnostics` directory contains only
`manifest-v1.json` plus the three preview JSON files. The package is mode `0700`, every
file is mode `0600`, there are no symlinks or log files, all four files parse as JSON,
and manifest byte counts exactly match the payload files. A targeted forbidden-value
scan had no matches. Review exposed only key/type structure and these bounded manifest
facts; it did not publish the full destination, generated package identifier, or any
structured evidence value.

After a separate installation authorization, the existing `/Applications/VibeStick for
Mac.app` version `0.2.0 (3)` was retained both as a verified copy and as the original
moved bundle under `.build/macos.noindex/M4-5K-Install-Backup`. The candidate was first
copied to a hidden same-volume staging path and reverified for version, architecture,
signature, and exact tree identity. An atomic rename swap then installed version
`0.2.0 (9)`, thin arm64 with a macOS 15.0 minimum, valid deep signature, and exact tree
identity with the candidate. No hidden staging, previous, or failed bundle remained.
The swap did not auto-launch the main App; the existing Bridge and HUD process
identities, PIDs, and start times did not change, and Paste was not triggered.

Under a fourth, installation-smoke authorization, only the final installed main App was
launched. Its home and Advanced Settings views rendered without a permission or error
prompt, and the version card showed `VibeStick for Mac 0.2.0 (9) · M4-5K`. The log
option remained off. The smoke did not prepare another preview, refresh state, choose a
destination, export, migrate, request permissions, operate a helper, or access a
device; Bridge and HUD remained unchanged.

The strict clean-machine installation and recovery acceptance was then explicitly
deferred because no second clean Mac or usable external-boot environment was available.
This is an environment-limited, unexecuted gate: it is neither a failure nor a pass, and
M4-5K must not claim clean-machine readiness, first-install self-contained runtime
activation, or recovery validation from this local closeout. No authorization in this
sequence extended to USB/device access, Keychain, recordings, device registration,
migration transactions, firmware backups, identity values, helper installation or
restart, Git, or publication. Publication remains a separate gate and must disclose the
clean-machine evidence gap.

## 0.2.0 RC 1 native-Bridge amendment

The release candidate supersedes the earlier packaged-Python clean-machine design
without changing M4's authorization boundaries. `VibeStickBridge` is now a native
Swift executable. The exact runtime payload consists of the Bridge, HUD, and Paste
App bundles plus a Swift/CryptoKit manifest; it contains no Python source,
interpreter, `pyproject.toml`, or interpreter-discovery environment variable.

The native production assembly preserves protocol v2 routing, Bonjour, device
authentication and configuration, Codex/Claude observation, Codex account/session
quota, opt-in Claude OAuth quota, voice recording, PCM upload, cloud/local-command
ASR, HUD, Paste, and pending-send confirmation. Managed configuration remains
fail-closed. Fixed Keychain lookups and bounded no-follow credential-file access
occur only when the relevant runtime feature is used; tests substitute fictional
readers and transports and do not read live credentials or make provider calls.

Upgrade treats the old `runtime` directory as an owned removal/rollback-only
target. It is moved into the private backup before native activation and restored
on failure. Configuration, Keychain items, logs, recordings, registries, device
backups, and firmware transactions remain outside the runtime payload and are not
overwritten.

The RC App carries the project license, NOTICE, SIL Open Font License, a bundled
third-party inventory, and the applicable local ESP-IDF, linked-component,
Newlib/Picolibc, and GCC runtime notices. App, Bridge, HUD, and Paste are version
`0.2.0 (10)`, thin arm64, with a macOS 15.0 minimum. Isolated acceptance must
unregister intermediate build products and disable candidate launch smoke; it may
compile, execute hostless tests, inspect/sign artifacts, build the DMG, attach it
read-only with `nobrowse`, verify its mounted contents, and detach it. It must not
launch the candidate or helpers, install or control a runtime, read live user data,
or access USB/devices.

Strict clean-machine first-install and fault-rollback acceptance remains
environment-limited and unexecuted because no second clean Mac or external clean
boot environment is available. This amendment must not label that gate passed.
Source commit, push, and Draft PR creation were separately authorized and are
complete. Merge, tag, GitHub Pre-release creation, and artifact upload remain
separate post-acceptance actions requiring explicit authorization.

Final local RC evidence on 2026-08-19: the isolated acceptance chain passed with
App, Bridge, HUD, and Paste all at `0.2.0 (10)`, thin arm64, and a macOS 15.0
minimum. Strict deep ad-hoc signatures, the exact native runtime manifest, 25
offline license/notice files, icons, forbidden-file scanning, and firmware scope
passed. The distributed runtime contains the three native App bundles and its
Swift/CryptoKit manifest, with zero Python payload files. The complete hostless
result is 270 Swift tests in 21 suites; all 194 retained Python compatibility tests
also pass.

The firmware manifest and all three images are byte-identical to the accepted
M4-5K payload. They are now fixed prospective-tag inputs under
`release/firmware/sticks3/0.2.0-m4.4a`, with 21 audited offline notices under
`release/licenses/firmware`. CI verifies that the payload manifest still binds to
the current secret-free firmware source digest. The release builder refuses
firmware rebuilding by default and requires a separate
`VIBESTICK_ALLOW_FIRMWARE_REBUILD=1` maintainer choice; this acceptance reused the
tracked payload without an ignored prior App, ESP-IDF, or managed-components tree,
and without reading the excluded local secret header or rebuilding firmware.

The final DMG verified, attached read-only with `nobrowse`, repeated all mounted-App
checks, and detached without a residual mount or isolated-build Launch Services
registration. No candidate executable was launched. The artifact is
`.build/macos.noindex/RC1-FinalSnapshot-5479663/VibeStick-for-Mac-0.2.0-rc.1.dmg`,
3,546,855 bytes, with SHA-256
`9117578032af78fcd5f2ec723983b460daf5c4b9ebd0d7d009c6e7da411600e8`.
The M4-5K DMG remains byte-for-byte identified by its original 3,137,499-byte size
and SHA-256
`960769a7c9b9ec42586c3ddb4c7b2ad9993a8cac047707da7531930fcf28c450`.

After the predecessor candidate's isolated gate, a separately authorized local
installation exposed two
macOS integration requirements. First, the existing Keychain ACL accepted the
fixed Apple `/usr/bin/security` client but rejected direct Security.framework
access from the newly signed helper. The production reader therefore invokes only
the fixed tool, fixed service, and fixed accounts with bounded output, and startup
errors retain only stable redacted categories. Second, macOS 15 Local Network
privacy requires both the main App and Bridge to declare a nonempty purpose and
`_vibestick._tcp`; because the legacy LaunchAgent is not installed by
`SMAppService`, its plist also carries the main App in
`AssociatedBundleIdentifiers`. Service verification permits a 120-second user
permission handoff. The user personally completed the Keychain and Local Network
prompts; no secret value was printed, retained by a probe, or copied into evidence.

Live acceptance then found that synchronous provider/session observation for
`/state` could occupy the original serial HTTP queue long enough to delay
`/health`. `NativeBridgeRequestCoordinator` now executes ordinary state-changing
routes on a dedicated serialized queue while the immutable health response stays
available on the listener path. The regression test blocks a fictional state read
and proves health still responds. With the installed predecessor main App forcing
three real state refreshes, 40 of 40 concurrent health probes passed.

The installed main App and Bridge were byte-identical to the predecessor candidate
`6cd183a4c65cfc6eab632ff401fb67316d11e38e1b180dd65d1ea103f282599c`. App,
Bridge, HUD, and Paste are all `0.2.0 (10)`, thin arm64, minimum macOS 15.0, and
strict-signature valid. Bridge and HUD are running; the final receipt records
`installed`, payload `0.2.0-rc.1-native`, and preserved Paste identity. The local
installation used normal bounded managed-configuration and fixed-Keychain startup
reads but did not read logs, call the production diagnostic adapter, access
USB/devices, or perform firmware or Git mutations. The exact acceptance record is
`docs/VIBESTICK_FOR_MAC_0.2.0_RC1_LOCAL_ACCEPTANCE.md`. Clean-machine acceptance
remains unexecuted. The final candidate adds only the diagnostic path-redaction
fix covered by the complete hostless and isolated DMG verification; it was not
installed or launched.

The prospective tag snapshot contains a read-only GitHub Actions job for the
hostless Swift suite on `macos-15` arm64 in addition to retained Python tests and
tracked-payload source-identity verification. Its local clean-snapshot equivalent
passed locally, and the Python and macOS Swift hosted jobs both pass at
`5479663`. The predecessor local replacement retained both App and runtime
rollback copies, reinstalled payload `0.2.0-rc.1-native`, preserved Paste build
identity and Accessibility, and left Bridge/HUD running. The GUI reported
`0.2.0 (10) · RC 1`, three forced home
refreshes stayed healthy, diagnostics remained ungenerated with logs off, USB
remained uninspected, and 40 of 40 concurrent health probes succeeded. No Git or
GitHub mutation occurred during that local replacement; subsequent source commits,
pushes, and Draft PR creation were separately authorized.
