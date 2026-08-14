#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIRMWARE_ROOT="$ROOT_DIR/firmware/sticks3"
BUILD_ROOT="$ROOT_DIR/.build/firmware-payload.noindex"
IDF_BUILD_ROOT="$BUILD_ROOT/idf"
CACHE_ROOT="$BUILD_ROOT/payload"
APP_PATH="${1:-$ROOT_DIR/.build/macos.noindex/VibeStick for Mac.app}"
PAYLOAD_ROOT="$APP_PATH/Contents/Resources/FirmwarePayload.noindex"
PAYLOAD_VERSION="0.2.0-m4.4a"
MANIFEST_TOOL="$ROOT_DIR/scripts/firmware-payload-manifest.py"
SECRET_HEADER="$FIRMWARE_ROOT/include/vibe_stick_secrets.h"

if [ ! -d "$APP_PATH/Contents" ]; then
  printf '%s\n' "Expected an app bundle at $APP_PATH" >&2
  exit 1
fi

PYTHON_PATH="$(command -v python3)"
SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DIGEST="$($PYTHON_PATH "$MANIFEST_TOOL" source-digest "$FIRMWARE_ROOT")"
CACHED_DIGEST=""
if [ -f "$BUILD_ROOT/source-digest" ]; then
  CACHED_DIGEST="$(/usr/bin/sed -n '1p' "$BUILD_ROOT/source-digest")"
fi

if [ "$CACHED_DIGEST" != "$SOURCE_DIGEST" ] \
  || ! "$PYTHON_PATH" "$MANIFEST_TOOL" verify "$CACHE_ROOT" >/dev/null 2>&1; then
  IDF_ROOT="${VIBE_STICK_IDF_PATH:-${IDF_PATH:-$HOME/esp/esp-idf}}"
  if [ ! -f "$IDF_ROOT/export.sh" ]; then
    printf '%s\n' "ESP-IDF export.sh was not found; set VIBE_STICK_IDF_PATH before building the maintainer payload" >&2
    exit 1
  fi

  rm -rf "$CACHE_ROOT"
  mkdir -p "$IDF_BUILD_ROOT" "$CACHE_ROOT"
  . "$IDF_ROOT/export.sh" >/dev/null
  idf.py \
    -C "$FIRMWARE_ROOT" \
    -B "$IDF_BUILD_ROOT" \
    -D "SDKCONFIG=$IDF_BUILD_ROOT/sdkconfig" \
    -D VIBE_STICK_DISTRIBUTABLE_BUILD=ON \
    build

  "$PYTHON_PATH" "$MANIFEST_TOOL" assert-build-layout "$IDF_BUILD_ROOT"
  /usr/bin/ditto --norsrc --noextattr "$IDF_BUILD_ROOT/bootloader/bootloader.bin" "$CACHE_ROOT/bootloader.bin"
  /usr/bin/ditto --norsrc --noextattr "$IDF_BUILD_ROOT/partition_table/partition-table.bin" "$CACHE_ROOT/partition-table.bin"
  /usr/bin/ditto --norsrc --noextattr "$IDF_BUILD_ROOT/vibe_stick_sticks3.bin" "$CACHE_ROOT/vibe-stick.bin"
  chmod 0644 "$CACHE_ROOT/bootloader.bin" "$CACHE_ROOT/partition-table.bin" "$CACHE_ROOT/vibe-stick.bin"
  "$PYTHON_PATH" "$MANIFEST_TOOL" generate \
    "$CACHE_ROOT" "$PAYLOAD_VERSION" "$SOURCE_REVISION" "$SOURCE_DIGEST"
  "$PYTHON_PATH" "$MANIFEST_TOOL" assert-no-secrets "$CACHE_ROOT" "$SECRET_HEADER"
  "$PYTHON_PATH" "$MANIFEST_TOOL" verify "$CACHE_ROOT"
  printf '%s\n' "$SOURCE_DIGEST" > "$BUILD_ROOT/source-digest"
else
  "$PYTHON_PATH" "$MANIFEST_TOOL" generate \
    "$CACHE_ROOT" "$PAYLOAD_VERSION" "$SOURCE_REVISION" "$SOURCE_DIGEST"
  "$PYTHON_PATH" "$MANIFEST_TOOL" assert-no-secrets "$CACHE_ROOT" "$SECRET_HEADER"
  "$PYTHON_PATH" "$MANIFEST_TOOL" verify "$CACHE_ROOT"
fi

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$(dirname -- "$PAYLOAD_ROOT")"
/usr/bin/ditto --norsrc --noextattr "$CACHE_ROOT" "$PAYLOAD_ROOT"
"$PYTHON_PATH" "$MANIFEST_TOOL" verify "$PAYLOAD_ROOT"

printf '%s\n' "$PAYLOAD_ROOT"
