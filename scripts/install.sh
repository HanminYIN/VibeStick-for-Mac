#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SETUP_PATH="$ROOT_DIR/scripts/setup.sh"
ENV_PATH="$ROOT_DIR/.env"
SECRETS_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.h"
CONFIG_DIR="$HOME/Library/Application Support/VibeStick"
RUNTIME_DIR="$CONFIG_DIR/runtime"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.vibestick.bridge.plist"
HUD_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.vibestick.hud.plist"
BRIDGE_APP_PATH="$CONFIG_DIR/VibeStick Bridge.app"
BRIDGE_BINARY_PATH="$BRIDGE_APP_PATH/Contents/MacOS/VibeStickBridge"
HUD_APP_PATH="$CONFIG_DIR/VibeStick HUD.app"
HUD_BINARY_PATH="$HUD_APP_PATH/Contents/MacOS/VibeStickHUD"
PASTE_APP_PATH="$CONFIG_DIR/VibeStick Paste.app"
PASTE_BINARY_PATH="$PASTE_APP_PATH/Contents/MacOS/VibeStickPaste"
PASTE_BUILD_STAMP_PATH="$PASTE_APP_PATH/Contents/Resources/VibeStickPaste.build"
BRIDGE_SOURCE_PATH="$ROOT_DIR/app/macos/VibeStickBridge/main.swift"
HUD_SOURCE_PATH="$ROOT_DIR/app/macos/VibeStickHUD/main.swift"
PASTE_SOURCE_PATH="$ROOT_DIR/app/macos/VibeStickPaste/main.swift"
LEGACY_RUNNER_PATH="$CONFIG_DIR/run-bridge.sh"
LEGACY_HUD_BINARY_PATH="$CONFIG_DIR/VibeStickHUD"

is_placeholder_token() {
  case "${1:-}" in
    ""|change-this-shared-token|paste-generated-token-here|changeme|change-me|your-token)
      return 0
      ;;
  esac
  return 1
}

env_value() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      k = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        sub(/^[^=]*=/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print
        exit
      }
    }
  ' "$file"
}

secret_value() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    $1 == "#define" && $2 == key {
      value = $0
      sub(/^[^"]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$file"
}

require_bridge_token_ready() {
  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  secret_token="$(secret_value VIBE_STICK_BRIDGE_TOKEN "$SECRETS_PATH")"

  if is_placeholder_token "$env_token"; then
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN is required because install.sh exposes the bridge on 0.0.0.0." >&2
    printf '%s\n' "Run scripts/setup.sh to generate and sync the bridge token." >&2
    exit 1
  fi
  if is_placeholder_token "$secret_token"; then
    printf '%s\n' "Firmware VIBE_STICK_BRIDGE_TOKEN is missing or still a placeholder." >&2
    printf '%s\n' "Run scripts/setup.sh to sync the same token into firmware secrets." >&2
    exit 1
  fi
  if [ "$env_token" != "$secret_token" ]; then
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN differs between .env and firmware secrets." >&2
    printf '%s\n' "Refusing to install because the device would receive 401 responses for protected POST requests." >&2
    exit 1
  fi
}

"$SETUP_PATH"
require_bridge_token_ready

if [ -f "$ENV_PATH" ]; then
  set -a
  . "$ENV_PATH"
  set +a
fi

if ! PYTHON_PATH="$(command -v python3)"; then
  printf '%s\n' "Python 3 is required to install VibeStick Bridge." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

RUNTIME_TEMP="$CONFIG_DIR/.runtime.installing"
BRIDGE_APP_TEMP="$CONFIG_DIR/.VibeStick Bridge.app.installing"
HUD_APP_TEMP="$CONFIG_DIR/.VibeStick HUD.app.installing"
PASTE_APP_TEMP="$CONFIG_DIR/.VibeStick Paste.app.installing"

rm -rf "$RUNTIME_TEMP" "$BRIDGE_APP_TEMP" "$HUD_APP_TEMP" "$PASTE_APP_TEMP"
mkdir -p "$RUNTIME_TEMP"
cp -R "$ROOT_DIR/bridge" "$RUNTIME_TEMP/bridge"

mkdir -p "$BRIDGE_APP_TEMP/Contents/MacOS"
mkdir -p "$HUD_APP_TEMP/Contents/MacOS"
mkdir -p "$PASTE_APP_TEMP/Contents/MacOS"
mkdir -p "$PASTE_APP_TEMP/Contents/Resources"

swiftc "$BRIDGE_SOURCE_PATH" -o "$BRIDGE_APP_TEMP/Contents/MacOS/VibeStickBridge"
swiftc "$HUD_SOURCE_PATH" -o "$HUD_APP_TEMP/Contents/MacOS/VibeStickHUD" -framework AppKit -framework QuartzCore
swiftc "$PASTE_SOURCE_PATH" -o "$PASTE_APP_TEMP/Contents/MacOS/VibeStickPaste" -framework AppKit -framework ApplicationServices

cat > "$BRIDGE_APP_TEMP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>VibeStick Bridge</string>
  <key>CFBundleExecutable</key>
  <string>VibeStickBridge</string>
  <key>CFBundleIdentifier</key>
  <string>com.vibestick.bridge.agent</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VibeStick Bridge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.4</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$HUD_APP_TEMP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>VibeStick HUD</string>
  <key>CFBundleExecutable</key>
  <string>VibeStickHUD</string>
  <key>CFBundleIdentifier</key>
  <string>com.vibestick.hud.agent</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VibeStick HUD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.4</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$PASTE_APP_TEMP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>VibeStick Paste</string>
  <key>CFBundleExecutable</key>
  <string>VibeStickPaste</string>
  <key>CFBundleIdentifier</key>
  <string>com.vibestick.paste</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VibeStick Paste</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.4</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

PASTE_SOURCE_DIGEST="$(shasum -a 256 "$PASTE_SOURCE_PATH" | awk '{print $1}')"
PASTE_PLIST_DIGEST="$(shasum -a 256 "$PASTE_APP_TEMP/Contents/Info.plist" | awk '{print $1}')"
PASTE_BUILD_FINGERPRINT="$({
  printf '%s\n' "$PASTE_SOURCE_DIGEST"
  printf '%s\n' "$PASTE_PLIST_DIGEST"
  printf '%s\n' 'swiftc-frameworks:AppKit,ApplicationServices'
} | shasum -a 256 | awk '{print $1}')"
printf '%s\n' "$PASTE_BUILD_FINGERPRINT" > "$PASTE_APP_TEMP/Contents/Resources/VibeStickPaste.build"

codesign --force --deep --sign - --requirements '=designated => identifier "com.vibestick.bridge.agent"' "$BRIDGE_APP_TEMP"
codesign --force --deep --sign - --requirements '=designated => identifier "com.vibestick.hud.agent"' "$HUD_APP_TEMP"
codesign --force --deep --sign - --requirements '=designated => identifier "com.vibestick.paste"' "$PASTE_APP_TEMP"

# An ad-hoc-signed Accessibility app is stored by macOS using its exact code
# hash. Preserve an unchanged helper across reinstalls so its permission remains
# valid. Source or bundle changes intentionally replace it and require the user
# to enable the new build once.
PRESERVE_PASTE_APP=0
if [ -x "$PASTE_BINARY_PATH" ] \
  && [ -f "$PASTE_BUILD_STAMP_PATH" ] \
  && [ "$(sed -n '1p' "$PASTE_BUILD_STAMP_PATH")" = "$PASTE_BUILD_FINGERPRINT" ] \
  && codesign --verify --deep --strict "$PASTE_APP_PATH" >/dev/null 2>&1; then
  PRESERVE_PASTE_APP=1
fi

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH" "$HUD_PLIST_PATH"
rm -f "$LEGACY_RUNNER_PATH" "$LEGACY_HUD_BINARY_PATH"
rm -rf "$RUNTIME_DIR" "$BRIDGE_APP_PATH" "$HUD_APP_PATH"
mv "$RUNTIME_TEMP" "$RUNTIME_DIR"
mv "$BRIDGE_APP_TEMP" "$BRIDGE_APP_PATH"
mv "$HUD_APP_TEMP" "$HUD_APP_PATH"
if [ "$PRESERVE_PASTE_APP" -eq 1 ]; then
  rm -rf "$PASTE_APP_TEMP"
else
  rm -rf "$PASTE_APP_PATH"
  mv "$PASTE_APP_TEMP" "$PASTE_APP_PATH"
fi

if [ -f "$ENV_PATH" ]; then
  cp "$ENV_PATH" "$CONFIG_DIR/.env"
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vibestick.bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BRIDGE_BINARY_PATH</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$CONFIG_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>VIBE_STICK_PYTHON_PATH</key>
    <string>$PYTHON_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$CONFIG_DIR/bridge.log</string>
  <key>StandardErrorPath</key>
  <string>$CONFIG_DIR/bridge.err.log</string>
</dict>
</plist>
PLIST

cat > "$HUD_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vibestick.hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HUD_BINARY_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$CONFIG_DIR/hud.log</string>
  <key>StandardErrorPath</key>
  <string>$CONFIG_DIR/hud.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl bootstrap "gui/$(id -u)" "$HUD_PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.vibestick.bridge"
launchctl kickstart -k "gui/$(id -u)/com.vibestick.hud"

printf '%s\n' "VibeStick config directory is ready:"
printf '%s\n' "$CONFIG_DIR"
printf '%s\n' "VibeStick Bridge background service installed:"
printf '%s\n' "$PLIST_PATH"
printf '%s\n' "VibeStick HUD background service installed:"
printf '%s\n' "$HUD_PLIST_PATH"
if [ "$PRESERVE_PASTE_APP" -eq 1 ]; then
  printf '%s\n' "VibeStick Paste accessibility helper preserved (permission identity unchanged):"
else
  printf '%s\n' "VibeStick Paste accessibility helper installed or updated:"
fi
printf '%s\n' "$PASTE_APP_PATH"
