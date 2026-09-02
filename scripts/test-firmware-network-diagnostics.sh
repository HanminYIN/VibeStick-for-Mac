#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/vibestick-network-diagnostics.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

"${CC:-cc}" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$REPOSITORY_ROOT/firmware/sticks3/include" \
  "$REPOSITORY_ROOT/firmware/sticks3/src/vibe_network_diagnostics.c" \
  "$REPOSITORY_ROOT/firmware/sticks3/tests/vibe_network_diagnostics_test.c" \
  -o "$TEST_ROOT/vibe-network-diagnostics-test"

"$TEST_ROOT/vibe-network-diagnostics-test"
