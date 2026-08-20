# Tracked StickS3 release payload

`sticks3/0.2.0-m4.4a` is the exact secret-free firmware payload accepted in
M4-5K and reused by VibeStick for Mac 0.2.0 RC 1 and RC 2. The directory
intentionally contains only the three flash images and `manifest-v1.json`; the
payload validator rejects extra files, changed modes, changed offsets, and hash
drift.

The manifest binds the binaries to the secret-free firmware source digest. CI
recomputes that digest from the source snapshot and fails if it differs. Normal
App/DMG builds copy this tracked payload and do not require ESP-IDF or a previous
local build directory. Rebuilding firmware remains a separate maintainer action
behind `VIBESTICK_ALLOW_FIRMWARE_REBUILD=1` and requires renewed binary,
license, and device acceptance before this directory may be replaced.
