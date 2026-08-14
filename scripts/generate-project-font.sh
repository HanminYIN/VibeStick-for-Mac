#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEFAULT_FONT_PATH="$ROOT_DIR/firmware/sticks3/managed_components/lvgl__lvgl/tests/src/test_files/fonts/noto/NotoSansSC-Regular.ttf"
FONT_PATH="${VIBESTICK_PROJECT_FONT_SOURCE:-$DEFAULT_FONT_PATH}"
OUTPUT_PATH="$ROOT_DIR/firmware/sticks3/generated/vibe_stick_project_cn_10.c"
TEMP_OUTPUT_PATH="$OUTPUT_PATH.tmp.$$"
FONT_CONVERTER_VERSION="1.5.3"

cleanup() {
  rm -f "$TEMP_OUTPUT_PATH"
}
trap cleanup EXIT HUP INT TERM

if [ ! -f "$FONT_PATH" ]; then
  printf '%s\n' "Project-name font source not found: $FONT_PATH" >&2
  printf '%s\n' "Run an ESP-IDF configure once, or set VIBESTICK_PROJECT_FONT_SOURCE to NotoSansSC-Regular.ttf." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "Python 3 is required to generate the deterministic GB2312 character set." >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  printf '%s\n' "npx is required to run lv_font_conv $FONT_CONVERTER_VERSION." >&2
  exit 1
fi

symbols="$(python3 - <<'PY'
hanzi = set()
for lead in range(0xA1, 0xF8):
    for trail in range(0xA1, 0xFF):
        try:
            character = bytes((lead, trail)).decode("gb2312")
        except UnicodeDecodeError:
            continue
        if len(character) == 1 and "\u4e00" <= character <= "\u9fff":
            hanzi.add(character)

if len(hanzi) != 6763:
    raise SystemExit(f"expected 6763 GB2312 Hanzi, found {len(hanzi)}")

punctuation = "·—（）【】《》〈〉「」『』，。！？、：；"
print("".join(sorted(hanzi)) + punctuation, end="")
PY
)"

npx --yes "lv_font_conv@$FONT_CONVERTER_VERSION" \
  --font "$FONT_PATH" \
  --symbols "$symbols" \
  --size 10 \
  --bpp 4 \
  --format lvgl \
  --no-compress \
  --no-kerning \
  --lv-include lvgl.h \
  --lv-font-name vibe_stick_project_cn_10 \
  --lv-fallback lv_font_montserrat_10 \
  --output "$TEMP_OUTPUT_PATH"

python3 - "$TEMP_OUTPUT_PATH" "$OUTPUT_PATH" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
header = """/*******************************************************************************
 * Size: 10 px, Bpp: 4, uncompressed.
 * Source font: Noto Sans SC Regular, SIL Open Font License 1.1.
 * Glyph subset: 6,763 GB2312 Hanzi plus common Chinese project-name punctuation.
 * ASCII letters, digits, and symbols fall back to LVGL Montserrat 10.
 * Generated with lv_font_conv 1.5.3 by scripts/generate-project-font.sh.
 ******************************************************************************/"""
source, count = re.subn(r"\A/\*.*?\*/", header, source, count=1, flags=re.DOTALL)
if count != 1:
    raise SystemExit("could not replace lv_font_conv generated header")
source = source.rstrip() + "\n"
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

printf '%s\n' "$OUTPUT_PATH"
