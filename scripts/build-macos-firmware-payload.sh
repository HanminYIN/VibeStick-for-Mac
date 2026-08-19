#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIRMWARE_ROOT="$ROOT_DIR/firmware/sticks3"
BUILD_ROOT="${VIBESTICK_FIRMWARE_BUILD_ROOT:-${VIBESTICK_BUILD_ROOT:-$ROOT_DIR/.build/macos.noindex}/FirmwarePayload.noindex}"
IDF_BUILD_ROOT="$BUILD_ROOT/idf"
CACHE_ROOT="$BUILD_ROOT/payload"
APP_PATH="${1:-$ROOT_DIR/.build/macos.noindex/VibeStick for Mac.app}"
PAYLOAD_ROOT="$APP_PATH/Contents/Resources/FirmwarePayload.noindex"
PAYLOAD_VERSION="0.2.0-m4.4a"
MANIFEST_TOOL="$ROOT_DIR/scripts/firmware-payload-manifest.py"
SECRET_HEADER="$FIRMWARE_ROOT/include/vibe_stick_secrets.h"
IDF_ROOT="${VIBE_STICK_IDF_PATH:-${IDF_PATH:-$HOME/esp/esp-idf}}"
TRUSTED_PAYLOAD="${VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD:-$ROOT_DIR/release/firmware/sticks3/0.2.0-m4.4a}"
TRUSTED_LICENSES="${VIBESTICK_TRUSTED_FIRMWARE_LICENSES:-$ROOT_DIR/release/licenses/firmware}"
ALLOW_FIRMWARE_REBUILD="${VIBESTICK_ALLOW_FIRMWARE_REBUILD:-0}"

case "$ALLOW_FIRMWARE_REBUILD" in
  0|1) ;;
  *)
    printf '%s\n' "VIBESTICK_ALLOW_FIRMWARE_REBUILD must be 0 or 1" >&2
    exit 1
    ;;
esac

if [ ! -d "$APP_PATH/Contents" ]; then
  printf '%s\n' "Expected an app bundle at $APP_PATH" >&2
  exit 1
fi

PYTHON_PATH="$(command -v python3)"
SOURCE_DIGEST="$($PYTHON_PATH "$MANIFEST_TOOL" source-digest "$FIRMWARE_ROOT")"
SOURCE_REVISION="${VIBE_STICK_FIRMWARE_SOURCE_REVISION:-}"
if [ -z "$SOURCE_REVISION" ] \
  && "$PYTHON_PATH" "$MANIFEST_TOOL" verify-source "$TRUSTED_PAYLOAD" "$FIRMWARE_ROOT" >/dev/null 2>&1; then
  SOURCE_REVISION="$(/usr/bin/plutil -extract source.revision raw -o - "$TRUSTED_PAYLOAD/manifest-v1.json")"
fi
if [ -z "$SOURCE_REVISION" ] \
  && "$PYTHON_PATH" "$MANIFEST_TOOL" verify "$CACHE_ROOT" >/dev/null 2>&1 \
  && [ "$(/usr/bin/plutil -extract source.digest raw -o - "$CACHE_ROOT/manifest-v1.json" 2>/dev/null || true)" = "$SOURCE_DIGEST" ]; then
  SOURCE_REVISION="$(/usr/bin/plutil -extract source.revision raw -o - "$CACHE_ROOT/manifest-v1.json")"
fi
if [ "${#SOURCE_REVISION}" -ne 40 ] \
  || ! printf '%s\n' "$SOURCE_REVISION" | /usr/bin/grep -Eq '^[0-9a-f]{40}$'; then
  printf '%s\n' "Set VIBE_STICK_FIRMWARE_SOURCE_REVISION to the audited 40-character source revision when the validated cache cannot provide it." >&2
  exit 1
fi
CACHED_DIGEST=""
if [ -f "$BUILD_ROOT/source-digest" ]; then
  CACHED_DIGEST="$(/usr/bin/sed -n '1p' "$BUILD_ROOT/source-digest")"
fi

PAYLOAD_SOURCE="$CACHE_ROOT"
if "$PYTHON_PATH" "$MANIFEST_TOOL" verify-source "$TRUSTED_PAYLOAD" "$FIRMWARE_ROOT" >/dev/null 2>&1 \
  && [ "$(/usr/bin/plutil -extract source.revision raw -o - "$TRUSTED_PAYLOAD/manifest-v1.json")" = "$SOURCE_REVISION" ]; then
  PAYLOAD_SOURCE="$TRUSTED_PAYLOAD"
elif [ "$ALLOW_FIRMWARE_REBUILD" != "1" ]; then
  printf '%s\n' "The accepted firmware payload does not match the current secret-free source identity; refusing to rebuild without VIBESTICK_ALLOW_FIRMWARE_REBUILD=1." >&2
  exit 1
elif [ "$CACHED_DIGEST" != "$SOURCE_DIGEST" ] \
  || ! "$PYTHON_PATH" "$MANIFEST_TOOL" verify "$CACHE_ROOT" >/dev/null 2>&1; then
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
/usr/bin/ditto --norsrc --noextattr "$PAYLOAD_SOURCE" "$PAYLOAD_ROOT"
"$PYTHON_PATH" "$MANIFEST_TOOL" verify "$PAYLOAD_ROOT"

if [ ! -d "$TRUSTED_LICENSES" ]; then
  printf '%s\n' "Tracked firmware license directory is missing: $TRUSTED_LICENSES" >&2
  exit 1
fi
LICENSE_ROOT="$APP_PATH/Contents/Resources/Licenses/Firmware"
rm -rf "$LICENSE_ROOT"
if /usr/bin/find "$TRUSTED_LICENSES" -type l -print -quit | /usr/bin/grep -q .; then
  printf '%s\n' "Tracked firmware license directory contains a symbolic link" >&2
  exit 1
fi
license_count="$(/usr/bin/find "$TRUSTED_LICENSES" -type f -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [ "$license_count" -ne 21 ] \
  || /usr/bin/find "$TRUSTED_LICENSES" -type f -size 0 -print -quit | /usr/bin/grep -q .; then
  printf '%s\n' "Tracked firmware license directory must contain exactly 21 nonempty files" >&2
  exit 1
fi
/usr/bin/ditto --norsrc --noextattr "$TRUSTED_LICENSES" "$LICENSE_ROOT"

printf '%s\n' "$PAYLOAD_ROOT"
