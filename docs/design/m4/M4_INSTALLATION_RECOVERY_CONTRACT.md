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
helper bundles, Bridge Python package source, `pyproject.toml`, and a versioned
manifest. Every regular file is listed with its relative path, size, POSIX mode,
and SHA-256 digest. Symlinks, undeclared files, missing files, path traversal, an
unknown schema, or an invalid nested code signature fail before services stop.

After explicit confirmation, M4-2 performs a second preflight. It blocks an
active recording, an unrecognized port owner, an external Bridge, or a loaded
helper outside the managed paths. It also requires an existing compatible Python
3.11 runtime; downloading or bundling the clean-machine Python runtime remains a
later M4 acceptance item.

The file transaction owns only these targets:

- `runtime`;
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
