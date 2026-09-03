# Threat model

## Purpose and status

This document makes the current security assumptions and review targets of
VibeStick for Mac explicit. It is a living review aid for an early public
release candidate, not a certification or a claim that all risks are resolved.

## Protected assets

- ASR API keys, Bridge and per-device pairing tokens, and local account access.
- Audio, transcripts, focused-input contents, local paths, project names, and
  coding-agent session metadata.
- Firmware images, device configuration, preserved NVS data, release artifacts,
  and update provenance.
- The integrity and availability of the native App, Bridge, HUD, Paste helper,
  and StickS3 firmware.

## Trust boundaries

1. **Mac user account:** the native App and helpers run with the signed-in
   user's permissions. Accessibility access is a separately granted macOS
   permission and is not assumed by default.
2. **Local network:** the StickS3 reaches the Bridge over a trusted LAN. Other
   LAN peers are not trusted merely because they share the network.
3. **USB and device:** identification, backup, write, readback, and recovery are
   separate operations. A connected serial device is not trusted solely by its
   port name.
4. **External ASR provider:** audio leaves the Mac only when the user configures
   and invokes that provider. Provider availability and data handling remain
   outside this repository's control.
5. **Release distribution:** GitHub source, release metadata, manifests,
   checksums, signing state, and the downloaded artifact form one provenance
   boundary.

## Primary threats

- An untrusted LAN peer reads state, submits commands, replays requests, or
  exhausts the Bridge with oversized or repeated traffic.
- A local process obtains credentials, recordings, transcripts, diagnostic
  contents, or Accessibility-assisted input capabilities beyond its need.
- A malicious or misidentified USB device receives firmware operations, or a
  failed update destroys device configuration that should have been preserved.
- A compromised dependency, build input, release artifact, or download path
  breaks the link between reviewed source and installed code.
- Logs, error messages, fixtures, or exported diagnostics disclose secrets,
  local identities, paths, recordings, or raw provider responses.
- Stale coding-agent observations or network failures are presented as
  authoritative state and lead the user to take an unsafe recovery action.

## Current controls

- Non-loopback Bridge deployments require a shared token; per-device trust and
  bounded request sizes protect state-changing and recording routes.
- Managed secrets use fixed Keychain items. Repository configuration stores
  references rather than secret values, and real credentials are gitignored.
- Diagnostic preview and export are separate explicit actions. Raw logs are
  excluded by default, selected excerpts are bounded and redacted, and there is
  no telemetry or automatic upload.
- Helper installation and migration are explicit and rollback-aware.
- Firmware inspection, download, USB access, backup, write, independent
  readback, and recovery remain separate confirmation boundaries. Release
  firmware is tied to manifests and source identities.
- CI covers the retained Python compatibility implementation, firmware host
  contracts, and native Swift behavior on every push and pull request.
- Public releases state their architecture, minimum OS, checksum, signing
  status, validation evidence, and known limitations.

## Known gaps and review priorities

- Public RC builds are ad-hoc signed and not notarized.
- Clean-machine first-install and fault-rollback acceptance has not yet been
  completed on an independent environment.
- The Bridge is intentionally reachable by a paired StickS3 on the LAN; network
  exposure, authentication failure modes, replay resistance, and resource
  bounds deserve continuing review.
- Accessibility permission can affect the foreground application. Paste and
  optional Return actions must stay explicit, narrowly scoped, and fail closed.
- Claude usage relies on an undocumented endpoint and remains disabled by
  default; it must not weaken credential isolation.
- External ASR privacy depends on the provider selected by the user. The local
  command path should remain available for users who do not want cloud ASR.

## Security review checklist

For changes touching a trust boundary, reviewers should ask:

- Does this expand network, filesystem, Keychain, Accessibility, microphone,
  USB, firmware, or external-provider access?
- Is the action read-only, state-changing, or destructive, and is that clear to
  the user before it runs?
- Are authentication, size, timeout, concurrency, replay, and stale-state
  behaviors bounded and covered by tests?
- Can errors or diagnostics expose secrets, raw provider responses, recordings,
  local paths, device identifiers, or account identity?
- Does the release artifact remain traceable to reviewed source and declared
  build inputs?
- Is rollback or recovery independently verified rather than assumed?

Report sensitive findings through the private process in
[SECURITY.md](../SECURITY.md), not a public issue.
