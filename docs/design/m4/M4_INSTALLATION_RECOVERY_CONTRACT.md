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
4. M4-4: USB mode detection, firmware backup, flash verification, and recovery.
5. M4-5: legacy migration, redacted diagnostics, and clean-machine acceptance.

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
