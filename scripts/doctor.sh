#!/usr/bin/env sh
set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_PATH="$ROOT_DIR/.env"
SECRETS_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.h"
APP_SUPPORT_DIR="$HOME/Library/Application Support/VibeStick"
COMPONENTS_DIR="$APP_SUPPORT_DIR/Components.noindex"
BRIDGE_PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.bridge.plist"
HUD_PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.hud.plist"
BRIDGE_BINARY_PATH="$COMPONENTS_DIR/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge"
HUD_BINARY_PATH="$COMPONENTS_DIR/VibeStick HUD.app/Contents/MacOS/VibeStickHUD"
PASTE_BINARY_PATH="$COMPONENTS_DIR/VibeStick Paste.app/Contents/MacOS/VibeStickPaste"
PASTE_APP_PATH="$COMPONENTS_DIR/VibeStick Paste.app"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$1"
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

is_placeholder_token() {
  case "${1:-}" in
    ""|change-this-shared-token|paste-generated-token-here|changeme|change-me|your-token)
      return 0
      ;;
  esac
  return 1
}

is_placeholder_wifi() {
  case "${1:-}" in
    ""|your-wifi|YOUR_WIFI_SSID|ssid|wifi-ssid)
      return 0
      ;;
  esac
  return 1
}

is_placeholder_password() {
  case "${1:-}" in
    ""|your-password|YOUR_WIFI_PASSWORD|password|wifi-password)
      return 0
      ;;
  esac
  return 1
}

is_placeholder_host() {
  case "${1:-}" in
    ""|127.0.0.1|0.0.0.0|192.168.1.10|YOUR_MAC_IP|your-mac-ip)
      return 0
      ;;
  esac
  return 1
}

check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    fail "Python 3 is not installed or not on PATH."
    return
  fi
  if python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
  then
    pass "Python >= 3.11 is available."
  else
    fail "Python >= 3.11 is required."
  fi
}

check_esp_idf() {
  if command -v idf.py >/dev/null 2>&1; then
    pass "ESP-IDF is available on PATH."
    return
  fi
  export_path=""
  if [ -d "$HOME/esp" ]; then
    export_path="$(find "$HOME/esp" -path '*/esp-idf/export.sh' -print -quit 2>/dev/null || true)"
  fi
  if [ -n "$export_path" ]; then
    pass "ESP-IDF export script was found."
  else
    warn "ESP-IDF was not found; only firmware build/flash needs it."
  fi
}

check_dotenv() {
  if [ -f "$ENV_PATH" ]; then
    pass ".env exists."
  else
    fail ".env is missing; run scripts/setup.sh."
    return
  fi

  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  if is_placeholder_token "$env_token"; then
    warn "VIBE_STICK_BRIDGE_TOKEN is empty or placeholder; binding 0.0.0.0 would be unsafe and install/dev scripts will refuse it."
  else
    pass "VIBE_STICK_BRIDGE_TOKEN is set in .env."
  fi
}

check_secrets() {
  if [ -f "$SECRETS_PATH" ]; then
    pass "firmware secrets file exists."
  else
    fail "firmware secrets file is missing; run scripts/setup.sh."
    return
  fi

  wifi_ssid="$(secret_value VIBE_STICK_WIFI_SSID "$SECRETS_PATH")"
  wifi_password="$(secret_value VIBE_STICK_WIFI_PASSWORD "$SECRETS_PATH")"
  bridge_host="$(secret_value VIBE_STICK_BRIDGE_HOST "$SECRETS_PATH")"

  if is_placeholder_wifi "$wifi_ssid"; then
    fail "Wi-Fi SSID is empty or placeholder in firmware secrets."
  else
    pass "Wi-Fi SSID is configured in firmware secrets."
  fi

  if is_placeholder_password "$wifi_password"; then
    fail "Wi-Fi password is empty or placeholder in firmware secrets."
  else
    pass "Wi-Fi password is configured in firmware secrets."
  fi

  if is_placeholder_host "$bridge_host"; then
    fail "VIBE_STICK_BRIDGE_HOST is empty, loopback, wildcard, or example placeholder."
  else
    pass "VIBE_STICK_BRIDGE_HOST is configured in firmware secrets."
    lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
    if [ -n "$lan_ip" ] && [ "$bridge_host" != "$lan_ip" ]; then
      warn "VIBE_STICK_BRIDGE_HOST ($bridge_host) does not match detected en0 IP ($lan_ip). Keep it only if the bridge runs at that address."
    fi
  fi
}

check_token_match() {
  [ -f "$ENV_PATH" ] && [ -f "$SECRETS_PATH" ] || return
  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  secret_token="$(secret_value VIBE_STICK_BRIDGE_TOKEN "$SECRETS_PATH")"
  if [ "$env_token" = "$secret_token" ]; then
    if is_placeholder_token "$env_token"; then
      warn "Bridge tokens match but are empty or placeholder."
    else
      pass "Bridge token matches between .env and firmware secrets."
    fi
  else
    fail "Bridge token differs between .env and firmware secrets; button POST requests will get 401."
  fi
}

check_bridge_health() {
  if command -v curl >/dev/null 2>&1 && curl -fsS http://127.0.0.1:8765/health >/dev/null 2>&1; then
    pass "Bridge health endpoint responded on 127.0.0.1:8765."
  else
    warn "Bridge health endpoint is not responding on 127.0.0.1:8765."
  fi
}

check_named_background_services() {
  bridge_program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$BRIDGE_PLIST_PATH" 2>/dev/null || true)"
  hud_program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$HUD_PLIST_PATH" 2>/dev/null || true)"
  if [ "$bridge_program" = "$BRIDGE_BINARY_PATH" ] && [ -x "$BRIDGE_BINARY_PATH" ]; then
    pass "VibeStick Bridge uses its named macOS launcher."
  else
    warn "VibeStick Bridge still uses a missing or legacy background launcher; rerun scripts/install.sh."
  fi
  if [ "$hud_program" = "$HUD_BINARY_PATH" ] && [ -x "$HUD_BINARY_PATH" ]; then
    pass "VibeStick HUD uses its named macOS launcher."
  else
    warn "VibeStick HUD still uses a missing or legacy background launcher; rerun scripts/install.sh."
  fi
  if [ -x "$PASTE_BINARY_PATH" ]; then
    pass "VibeStick Paste helper is installed."
    if python3 - "$PASTE_APP_PATH" <<'PY' >/dev/null 2>&1
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

app = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="vibestick-paste-check-") as tmp:
    request = Path(tmp) / "request.json"
    response = Path(tmp) / "response.json"
    request.write_text(json.dumps({"operation": "check"}))
    try:
        subprocess.run(
            [
                "/usr/bin/open", "-W", "-g", "-n", str(app), "--args",
                "--request", str(request), "--response", str(response),
            ],
            check=False,
            capture_output=True,
            timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(2)

    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if response.exists():
            try:
                data = json.loads(response.read_text())
            except (OSError, UnicodeError, json.JSONDecodeError):
                raise SystemExit(2)
            if not isinstance(data, dict) or type(data.get("success")) is not bool:
                raise SystemExit(2)
            raise SystemExit(0 if data.get("success") else 1)
        time.sleep(0.1)
    raise SystemExit(2)
PY
    then
      pass "VibeStick Paste has Accessibility permission."
    else
      paste_check_status="$?"
      if [ "$paste_check_status" -eq 1 ]; then
        warn "Enable VibeStick Paste in System Settings -> Privacy & Security -> Accessibility."
      else
        warn "VibeStick Paste permission check could not complete; the helper was not reported as unauthorized."
      fi
    fi
    "$LSREGISTER_PATH" -u "$PASTE_APP_PATH" >/dev/null 2>&1 || true
  else
    warn "VibeStick Paste helper is missing; rerun scripts/install.sh."
  fi
}

check_asr() {
  if python3 - "$ENV_PATH" "$APP_SUPPORT_DIR" <<'PY'
import os
import sys
import tomllib
from pathlib import Path

env_path = Path(sys.argv[1])
app_support = Path(sys.argv[2])

def clean(value):
    if value is None:
        return ""
    value = str(value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1].strip()
    return value

def present(value):
    value = clean(value)
    return bool(value) and value.lower() not in {
        "changeme",
        "change-me",
        "your-key",
        "your-api-key",
        "paste-api-key-here",
    }

def read_dotenv(path):
    data = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return data
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = clean(value)
    return data

def merged_env(path):
    data = read_dotenv(path)
    for key in (
        "VIBE_STICK_TRANSCRIBE_CMD",
        "VIBE_STICK_ASR_PROVIDER",
        "VIBE_STICK_ASR_BASE_URL",
        "VIBE_STICK_ASR_API_KEY",
        "VIBE_STICK_GROQ_API_KEY",
    ):
        if key in os.environ:
            data[key] = os.environ[key]
    return data

def env_has_asr(data):
    if present(data.get("VIBE_STICK_TRANSCRIBE_CMD")):
        return True
    provider = clean(data.get("VIBE_STICK_ASR_PROVIDER")).lower()
    base_url = data.get("VIBE_STICK_ASR_BASE_URL")
    asr_key = data.get("VIBE_STICK_ASR_API_KEY")
    groq_key = data.get("VIBE_STICK_GROQ_API_KEY")
    if provider == "groq":
        return present(asr_key) or present(groq_key)
    if provider == "openai-compatible" or present(base_url) or present(asr_key):
        return present(base_url) and present(asr_key)
    return present(groq_key)

def toml_has_asr(path):
    try:
        data = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return False
    provider = clean(data.get("asr_provider") or data.get("provider")).lower()
    base_url = data.get("base_url")
    api_key = data.get("api_key")
    groq_key = data.get("groq_api_key")
    if provider == "groq":
        return present(groq_key) or present(api_key)
    if provider == "openai-compatible" or present(base_url) or present(api_key):
        return present(base_url) and present(api_key)
    return False

dotenv = merged_env(env_path)
ok = env_has_asr(dotenv) or any(
    toml_has_asr(path)
    for path in (app_support / "asr.toml", app_support / "config.toml")
)
raise SystemExit(0 if ok else 1)
PY
  then
    pass "ASR is configured through command, Groq, or OpenAI-compatible settings."
  else
    warn "ASR is not configured; recording can capture audio but will not transcribe."
  fi
}

check_claude_token() {
  claude_usage="$(env_value VIBE_STICK_CLAUDE_USAGE "$ENV_PATH" | tr '[:upper:]' '[:lower:]')"
  case "$claude_usage" in
    1|true|yes|on)
      if PYTHONPATH="$ROOT_DIR/bridge/src" python3 - "$ENV_PATH" <<'PY'
import os
import sys
from pathlib import Path

env_path = Path(sys.argv[1])

def load_dotenv(path):
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\"'")
        os.environ.setdefault(key.strip(), value)

load_dotenv(env_path)
from vibe_stick.claude.usage import resolve_token

raise SystemExit(0 if resolve_token() else 1)
PY
      then
        pass "Claude usage is on and an OAuth token can be resolved: yes."
      else
        warn "Claude usage is on but an OAuth token can be resolved: no."
      fi
      ;;
    *)
      pass "Claude usage is off; token resolution skipped."
      ;;
  esac
}

check_python
check_esp_idf
check_dotenv
check_secrets
check_token_match
check_bridge_health
check_named_background_services
check_asr
check_claude_token

printf 'INFO macOS permissions: grant Accessibility permission to VibeStick Paste for automatic text insertion.\n'
printf 'SUMMARY pass=%s warn=%s fail=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
