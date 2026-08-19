#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="${VIBESTICK_BUILD_ROOT:-$ROOT_DIR/.build/macos.noindex}"
APP_PATH="${1:-$BUILD_ROOT/VibeStick for Mac.app}"
PAYLOAD_ROOT="$APP_PATH/Contents/Resources/RuntimePayload.noindex"
PAYLOAD_VERSION="0.2.0-rc.1-native"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SWIFT_MODULE_CACHE="$BUILD_ROOT/SwiftModuleCache.noindex"
mkdir -p "$SWIFT_MODULE_CACHE"

if [ ! -d "$APP_PATH/Contents" ]; then
  printf '%s\n' "Expected an app bundle at $APP_PATH" >&2
  exit 1
fi

for target in VibeStickBridge VibeStickHUD VibeStickPaste; do
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$target" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_ROOT/$target-DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    REGISTER_APP_WITH_LAUNCH_SERVICES=NO \
    build
done

BRIDGE_APP="$BUILD_ROOT/VibeStickBridge-DerivedData/Build/Products/Release/VibeStick Bridge.app"
HUD_APP="$BUILD_ROOT/VibeStickHUD-DerivedData/Build/Products/Release/VibeStick HUD.app"
PASTE_APP="$BUILD_ROOT/VibeStickPaste-DerivedData/Build/Products/Release/VibeStick Paste.app"

"$LSREGISTER_PATH" -u "$BRIDGE_APP" >/dev/null 2>&1 || true
"$LSREGISTER_PATH" -u "$HUD_APP" >/dev/null 2>&1 || true
"$LSREGISTER_PATH" -u "$PASTE_APP" >/dev/null 2>&1 || true

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT/Components.noindex"

/usr/bin/ditto --norsrc --noextattr "$BRIDGE_APP" "$PAYLOAD_ROOT/Components.noindex/VibeStick Bridge.app"
/usr/bin/ditto --norsrc --noextattr "$HUD_APP" "$PAYLOAD_ROOT/Components.noindex/VibeStick HUD.app"
/usr/bin/ditto --norsrc --noextattr "$PASTE_APP" "$PAYLOAD_ROOT/Components.noindex/VibeStick Paste.app"

PASTE_PAYLOAD_APP="$PAYLOAD_ROOT/Components.noindex/VibeStick Paste.app"
mkdir -p "$PASTE_PAYLOAD_APP/Contents/Resources"
PASTE_SOURCE_DIGEST="$(/usr/bin/shasum -a 256 "$ROOT_DIR/app/macos/VibeStickPaste/main.swift" | /usr/bin/awk '{print $1}')"
PASTE_PLIST_DIGEST="$(/usr/bin/shasum -a 256 "$ROOT_DIR/app/macos/VibeStickPaste/Info.install.plist" | /usr/bin/awk '{print $1}')"
PASTE_BUILD_FINGERPRINT="$({
  printf '%s\n' "$PASTE_SOURCE_DIGEST"
  printf '%s\n' "$PASTE_PLIST_DIGEST"
  printf '%s\n' 'swiftc-frameworks:AppKit,ApplicationServices'
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
printf '%s\n' "$PASTE_BUILD_FINGERPRINT" > "$PASTE_PAYLOAD_APP/Contents/Resources/VibeStickPaste.build"

/usr/bin/codesign --force --sign - --requirements '=designated => identifier "com.vibestick.bridge.agent"' "$PAYLOAD_ROOT/Components.noindex/VibeStick Bridge.app"
/usr/bin/codesign --force --sign - --requirements '=designated => identifier "com.vibestick.hud.agent"' "$PAYLOAD_ROOT/Components.noindex/VibeStick HUD.app"
/usr/bin/codesign --force --sign - --requirements '=designated => identifier "com.vibestick.paste"' "$PASTE_PAYLOAD_APP"

/usr/bin/xcrun swift -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT_DIR/scripts/runtime-payload-manifest.swift" generate "$PAYLOAD_ROOT" "$PAYLOAD_VERSION"
/usr/bin/xcrun swift -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT_DIR/scripts/runtime-payload-manifest.swift" verify "$PAYLOAD_ROOT"

printf '%s\n' "$PAYLOAD_ROOT"
