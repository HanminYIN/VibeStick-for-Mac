#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="$ROOT_DIR/.build/macos.noindex"
DERIVED_DATA="$BUILD_ROOT/App-DerivedData"
PRODUCT_PATH="$DERIVED_DATA/Build/Products/Release/VibeStick for Mac.app"
OUTPUT_PATH="$BUILD_ROOT/VibeStick for Mac.app"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme VibeStickForMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ ! -d "$PRODUCT_PATH" ]; then
  printf '%s\n' "Build completed without the expected app at $PRODUCT_PATH" >&2
  exit 1
fi

rm -rf "$OUTPUT_PATH"
/usr/bin/ditto "$PRODUCT_PATH" "$OUTPUT_PATH"
/usr/bin/codesign --force --sign - "$OUTPUT_PATH"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_PATH"

printf '%s\n' "$OUTPUT_PATH"
