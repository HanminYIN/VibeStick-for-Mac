#!/usr/bin/env sh
set -eu

CONFIG_DIR="$HOME/Library/Application Support/VibeStick"
COMPONENTS_DIR="$CONFIG_DIR/Components.noindex"
PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.bridge.plist"
HUD_PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.hud.plist"
BRIDGE_APP_PATH="$COMPONENTS_DIR/VibeStick Bridge.app"
HUD_APP_PATH="$COMPONENTS_DIR/VibeStick HUD.app"
PASTE_APP_PATH="$COMPONENTS_DIR/VibeStick Paste.app"
LEGACY_BRIDGE_APP_PATH="$CONFIG_DIR/VibeStick Bridge.app"
LEGACY_HUD_APP_PATH="$CONFIG_DIR/VibeStick HUD.app"
LEGACY_PASTE_APP_PATH="$CONFIG_DIR/VibeStick Paste.app"
LEGACY_RUNNER_PATH="$CONFIG_DIR/run-bridge.sh"
LEGACY_HUD_BINARY_PATH="$CONFIG_DIR/VibeStickHUD"

printf '%s\n' "VibeStick uninstall helper"
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$HUD_PLIST_PATH"
rm -f "$LEGACY_RUNNER_PATH"
rm -f "$LEGACY_HUD_BINARY_PATH"
rm -rf \
  "$BRIDGE_APP_PATH" \
  "$HUD_APP_PATH" \
  "$PASTE_APP_PATH" \
  "$LEGACY_BRIDGE_APP_PATH" \
  "$LEGACY_HUD_APP_PATH" \
  "$LEGACY_PASTE_APP_PATH"
rmdir "$COMPONENTS_DIR" >/dev/null 2>&1 || true
printf '%s\n' "LaunchAgent removed:"
printf '%s\n' "$PLIST_PATH"
printf '%s\n' "$HUD_PLIST_PATH"
printf '%s\n' "Named VibeStick background components removed."
printf '%s\n' "Config directory:"
printf '%s\n' "$CONFIG_DIR"
printf '%s\n' "Remove it manually only if you no longer need local cache/config."
