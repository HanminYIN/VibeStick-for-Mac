#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/.build/macos.noindex"
APP_PATH="$BUILD_ROOT/VibeStick for Mac.app"
STAGING_PATH="$BUILD_ROOT/dmg-root"
DMG_PATH="$BUILD_ROOT/VibeStick-for-Mac-M3-A.dmg"

"$ROOT_DIR/scripts/build-macos-app.sh"

rm -rf "$STAGING_PATH"
mkdir -p "$STAGING_PATH"
/usr/bin/ditto "$APP_PATH" "$STAGING_PATH/VibeStick for Mac.app"
ln -s /Applications "$STAGING_PATH/Applications"
rm -f "$DMG_PATH"

/usr/bin/hdiutil create \
  -volname "VibeStick for Mac M3-A" \
  -srcfolder "$STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
printf '%s\n' "$DMG_PATH"
