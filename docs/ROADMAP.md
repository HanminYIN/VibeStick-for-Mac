# Public roadmap

VibeStick for Mac is an actively maintained early-preview project. The current
public release is `v0.2.0-rc.2`; development happens on `main`, and concrete
work is tracked in [GitHub Issues](https://github.com/HanminYIN/VibeStick-for-Mac/issues).

This page describes priorities, not promises or deadlines. An issue is the
source of truth for scope, ownership, dependencies, and acceptance evidence.

## Current priorities

1. **Independent installation evidence**
   - Validate first install, permission guidance, background-component setup,
     uninstall, and rollback on a clean Apple Silicon Mac.
   - Keep the existing RC limitation visible until that external validation is
     complete.

2. **Distribution trust**
   - Prepare a reproducible Developer ID signing and notarization path without
     committing credentials or weakening current integrity checks.
   - Continue publishing release checksums, source identities, limitations,
     and CI evidence.

3. **Real-device compatibility and contributor feedback**
   - Collect reproducible reports from StickS3 users across supported macOS 15+
     versions and common 2.4 GHz network setups.
   - Turn confirmed failures into focused issues and regression tests.

4. **Security review**
   - Review the LAN Bridge, pairing tokens, Keychain access, Accessibility
     helper, audio/ASR flow, diagnostic redaction, release supply chain, and
     guarded USB/firmware operations against the
     [threat model](THREAT_MODEL.md).

5. **Stable 0.2.0 release**
   - Close release-blocking defects, update bilingual documentation, and ship a
     stable release only after its stated acceptance boundary has passed.

## Later exploration

- Additional coding-agent providers with explicit opt-in and credential
  isolation.
- More configurable device pages, alerts, and sound behavior.
- Device abstraction beyond StickS3 after the current hardware path is stable.
- Official Codex App Server approval integration only if one-time approval can
  remain precisely bound, visible, and revocable.

## Contributing

Real installation reports, security review, documentation improvements, and
small tested fixes are welcome. See [CONTRIBUTING.md](../CONTRIBUTING.md) and
use the repository's issue forms. Sensitive findings belong in a private
GitHub Security Advisory as described in [SECURITY.md](../SECURITY.md).
