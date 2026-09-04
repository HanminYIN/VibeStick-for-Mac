#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/scripts/release-config.sh"
load_release_configuration "$ROOT_DIR"
export VIBESTICK_RELEASE_CONFIG="$VIBESTICK_RELEASE_CONFIG_PATH"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="${VIBESTICK_BUILD_ROOT:-$ROOT_DIR/.build/macos.noindex}"
DERIVED_DATA="$BUILD_ROOT/App-DerivedData"
PRODUCT_PATH="$DERIVED_DATA/Build/Products/Release/$VIBESTICK_APP_BUNDLE_NAME"
OUTPUT_PATH="$BUILD_ROOT/$VIBESTICK_APP_BUNDLE_NAME"
RECEIPT_PATH="$BUILD_ROOT/$VIBESTICK_APP_BUNDLE_NAME.build-receipt-v1.json"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

rm -f "$RECEIPT_PATH"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme VibeStickForMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$VIBESTICK_BUILD_VERSION" \
  MARKETING_VERSION="$VIBESTICK_PRODUCT_VERSION" \
  PRODUCT_NAME="$VIBESTICK_PRODUCT_NAME" \
  REGISTER_APP_WITH_LAUNCH_SERVICES=NO \
  build

"$LSREGISTER_PATH" -u "$PRODUCT_PATH" >/dev/null 2>&1 || true

if [ ! -d "$PRODUCT_PATH" ]; then
  printf '%s\n' "Build completed without the expected app at $PRODUCT_PATH" >&2
  exit 1
fi

rm -rf "$OUTPUT_PATH"
/usr/bin/ditto "$PRODUCT_PATH" "$OUTPUT_PATH"
/usr/bin/plutil -replace VibeStickReleaseLabel -string "$VIBESTICK_RELEASE_LABEL" "$OUTPUT_PATH/Contents/Info.plist"
/usr/bin/plutil -replace VibeStickReleaseTitle -string "$VIBESTICK_APP_RELEASE_TITLE" "$OUTPUT_PATH/Contents/Info.plist"
/usr/bin/plutil -replace VibeStickReleaseSummary -string "$VIBESTICK_APP_RELEASE_SUMMARY" "$OUTPUT_PATH/Contents/Info.plist"
LICENSE_ROOT="$OUTPUT_PATH/Contents/Resources/Licenses"
mkdir -p "$LICENSE_ROOT"
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/LICENSE" "$LICENSE_ROOT/VibeStick-MIT.txt"
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/NOTICE" "$LICENSE_ROOT/VibeStick-NOTICE.txt"
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/docs/SIL-OFL-1.1.txt" "$LICENSE_ROOT/SIL-OFL-1.1.txt"
/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/docs/THIRD_PARTY_LICENSES.md" "$LICENSE_ROOT/THIRD-PARTY-LICENSES.md"
/usr/bin/ditto --norsrc --noextattr \
  "$VIBESTICK_RELEASE_CONFIG_PATH" \
  "$OUTPUT_PATH/Contents/Resources/ReleaseConfiguration-v1.json"
"$ROOT_DIR/scripts/build-macos-runtime-payload.sh" "$OUTPUT_PATH"
"$ROOT_DIR/scripts/build-macos-firmware-payload.sh" "$OUTPUT_PATH"
/usr/bin/codesign --force --sign - "$OUTPUT_PATH"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_PATH"
python3 "$ROOT_DIR/scripts/release_artifact.py" seal \
  "$OUTPUT_PATH" \
  "$VIBESTICK_RELEASE_CONFIG_PATH" \
  "$RECEIPT_PATH"

printf '%s\n' "$OUTPUT_PATH"
