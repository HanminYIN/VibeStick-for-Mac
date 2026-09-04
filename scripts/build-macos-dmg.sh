#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/release-config.sh"
load_release_configuration "$ROOT_DIR"
BUILD_ROOT="${VIBESTICK_BUILD_ROOT:-$ROOT_DIR/.build/macos.noindex}"
APP_PATH="$BUILD_ROOT/$VIBESTICK_APP_BUNDLE_NAME"
APP_RECEIPT_PATH="$BUILD_ROOT/$VIBESTICK_APP_BUNDLE_NAME.build-receipt-v1.json"
STAGING_PATH="$BUILD_ROOT/dmg-root"
DMG_PATH="$BUILD_ROOT/$VIBESTICK_DMG_FILENAME"
DITTO_PATH="${VIBESTICK_DITTO_PATH:-/usr/bin/ditto}"
HDIUTIL_PATH="${VIBESTICK_HDIUTIL_PATH:-/usr/bin/hdiutil}"
MOUNT_POINT=""
MOUNTED=0

cleanup_package_mount() {
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
    "$HDIUTIL_PATH" detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [ -n "$MOUNT_POINT" ]; then
    /bin/rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}
trap cleanup_package_mount EXIT HUP INT TERM

python3 "$ROOT_DIR/scripts/release_artifact.py" verify \
  "$APP_PATH" \
  "$VIBESTICK_RELEASE_CONFIG_PATH" \
  "$APP_RECEIPT_PATH"

rm -rf "$STAGING_PATH"
mkdir -p "$STAGING_PATH"
"$DITTO_PATH" "$APP_PATH" "$STAGING_PATH/$VIBESTICK_APP_BUNDLE_NAME"
ln -s /Applications "$STAGING_PATH/Applications"
python3 "$ROOT_DIR/scripts/release_artifact.py" verify \
  "$STAGING_PATH/$VIBESTICK_APP_BUNDLE_NAME" \
  "$VIBESTICK_RELEASE_CONFIG_PATH" \
  "$APP_RECEIPT_PATH"
rm -f "$DMG_PATH"

"$HDIUTIL_PATH" create \
  -volname "$VIBESTICK_DMG_VOLUME_NAME" \
  -srcfolder "$STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

"$HDIUTIL_PATH" verify "$DMG_PATH"
MOUNT_POINT="$(/usr/bin/mktemp -d "$BUILD_ROOT/dmg-package-verify.XXXXXX")"
"$HDIUTIL_PATH" attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DMG_PATH" >/dev/null
MOUNTED=1
python3 "$ROOT_DIR/scripts/release_artifact.py" verify \
  "$MOUNT_POINT/$VIBESTICK_APP_BUNDLE_NAME" \
  "$VIBESTICK_RELEASE_CONFIG_PATH" \
  "$APP_RECEIPT_PATH"
"$HDIUTIL_PATH" detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
/bin/rmdir "$MOUNT_POINT"
MOUNT_POINT=""
printf '%s\n' "$DMG_PATH"
