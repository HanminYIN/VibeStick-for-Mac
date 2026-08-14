#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="$ROOT_DIR/.build/macos.noindex"
APP_PATH="${1:-$BUILD_ROOT/VibeStick for Mac.app}"
PAYLOAD_ROOT="$APP_PATH/Contents/Resources/RuntimePayload.noindex"
PAYLOAD_VERSION="0.2.0-m4.2"

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
    build
done

BRIDGE_APP="$BUILD_ROOT/VibeStickBridge-DerivedData/Build/Products/Release/VibeStick Bridge.app"
HUD_APP="$BUILD_ROOT/VibeStickHUD-DerivedData/Build/Products/Release/VibeStick HUD.app"
PASTE_APP="$BUILD_ROOT/VibeStickPaste-DerivedData/Build/Products/Release/VibeStick Paste.app"

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT/Components.noindex"
mkdir -p "$PAYLOAD_ROOT/runtime/bridge/src/vibe_stick"

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

/usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/bridge/pyproject.toml" "$PAYLOAD_ROOT/runtime/bridge/pyproject.toml"
find "$ROOT_DIR/bridge/src/vibe_stick" -type f -name '*.py' -print | while IFS= read -r source_path; do
  relative_path="${source_path#"$ROOT_DIR/bridge/src/vibe_stick/"}"
  destination_path="$PAYLOAD_ROOT/runtime/bridge/src/vibe_stick/$relative_path"
  mkdir -p "$(dirname -- "$destination_path")"
  /usr/bin/ditto --norsrc --noextattr "$source_path" "$destination_path"
done

PYTHON_PATH="$(command -v python3)"
"$PYTHON_PATH" "$ROOT_DIR/scripts/runtime-payload-manifest.py" generate "$PAYLOAD_ROOT" "$PAYLOAD_VERSION"
"$PYTHON_PATH" "$ROOT_DIR/scripts/runtime-payload-manifest.py" verify "$PAYLOAD_ROOT"

printf '%s\n' "$PAYLOAD_ROOT"
