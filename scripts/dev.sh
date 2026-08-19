#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="$ROOT_DIR/.build/macos.noindex/NativeBridgeDev-DerivedData"
SUPPORT_DIR="$HOME/Library/Application Support/VibeStick"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

case "${VIBE_STICK_BRIDGE_TOKEN:-}" in
  ""|change-this-shared-token|paste-generated-token-here|changeme|change-me)
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN is required because dev.sh exposes the bridge on 0.0.0.0." >&2
    printf '%s\n' "Generate one with: openssl rand -hex 32" >&2
    exit 1
    ;;
esac

mkdir -p "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR"
cp "$ROOT_DIR/.env" "$SUPPORT_DIR/.env"
chmod 600 "$SUPPORT_DIR/.env"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme VibeStickBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_ROOT" \
  CODE_SIGNING_ALLOWED=NO \
  REGISTER_APP_WITH_LAUNCH_SERVICES=NO \
  build

exec "$BUILD_ROOT/Build/Products/Debug/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge"
