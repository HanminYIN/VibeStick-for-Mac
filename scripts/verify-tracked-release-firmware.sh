#!/bin/sh
set -eu

VIBESTICK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VIBESTICK_PAYLOAD="$VIBESTICK_ROOT/release/firmware/sticks3/0.2.0-m4.4a"
VIBESTICK_MANIFEST="$VIBESTICK_PAYLOAD/manifest-v1.json"
VIBESTICK_TOOL="$VIBESTICK_ROOT/scripts/firmware-payload-manifest.py"

python3 "$VIBESTICK_TOOL" verify "$VIBESTICK_PAYLOAD"
VIBESTICK_SOURCE_REVISION=$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["source"]["revision"])' \
  "$VIBESTICK_MANIFEST")

if ! git -C "$VIBESTICK_ROOT" cat-file -e "${VIBESTICK_SOURCE_REVISION}^{commit}"; then
  echo "tracked release source revision is unavailable: $VIBESTICK_SOURCE_REVISION" >&2
  exit 1
fi

VIBESTICK_RELEASE_TMP=$(mktemp -d /tmp/vibestick-release-source.XXXXXX)
trap 'rm -rf -- "$VIBESTICK_RELEASE_TMP"' EXIT HUP INT TERM

git -C "$VIBESTICK_ROOT" archive \
  "$VIBESTICK_SOURCE_REVISION" \
  firmware/sticks3 \
  | tar -x -C "$VIBESTICK_RELEASE_TMP"

python3 "$VIBESTICK_TOOL" verify-source \
  "$VIBESTICK_PAYLOAD" \
  "$VIBESTICK_RELEASE_TMP/firmware/sticks3"
