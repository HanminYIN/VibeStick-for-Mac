# Tracked offline release notices

`firmware` contains the 21 firmware, linked-library, C-runtime, and GCC runtime
license texts audited for the secret-free StickS3 payload in VibeStick for Mac
0.2.0 RC 1 and RC 2. App/DMG packaging copies these tracked notices so a clean
source or tag snapshot does not depend on an ignored ESP-IDF checkout,
managed-components directory, or toolchain cache.

Any firmware dependency or toolchain change requires refreshing these files and
`docs/THIRD_PARTY_LICENSES.md` before a new payload is accepted.
