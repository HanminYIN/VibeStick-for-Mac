#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="$ROOT_DIR/.build/macos"
APP_PATH="$BUILD_ROOT/VibeStick for Mac.app"
APP_BINARY="$APP_PATH/Contents/MacOS/VibeStick for Mac"
DMG_PATH="$BUILD_ROOT/VibeStick-for-Mac-M1.dmg"
TEST_DERIVED_DATA="$BUILD_ROOT/VerificationTests-DerivedData"
TEST_BUNDLE="$TEST_DERIVED_DATA/Build/Products/Debug/VibeStickForMacTests.xctest"

assert_binary() {
  binary_path="$1"
  label="$2"

  architectures="$(/usr/bin/lipo -archs "$binary_path")"
  if [ "$architectures" != "arm64" ]; then
    printf '%s\n' "FAIL: $label architecture is $architectures, expected arm64" >&2
    exit 1
  fi
  /usr/bin/vtool -show-build "$binary_path" | /usr/bin/awk '
    $1 == "minos" && $2 == "15.0" { found = 1 }
    END { exit found ? 0 : 1 }
  '
  printf '%s\n' "PASS: $label is thin arm64 with macOS 15.0 minimum"
}

sign_and_verify_bundle() {
  bundle_path="$1"
  label="$2"
  /usr/bin/codesign --force --sign - "$bundle_path"
  /usr/bin/codesign --verify --deep --strict "$bundle_path"
  printf '%s\n' "PASS: $label ad-hoc signature verified"
}

assert_app_icon() {
  icon_app_path="$1"
  icon_label="$2"
  icon_info_plist="$icon_app_path/Contents/Info.plist"
  icon_icns="$icon_app_path/Contents/Resources/AppIcon.icns"
  icon_assets="$icon_app_path/Contents/Resources/Assets.car"

  if [ ! -s "$icon_icns" ] || [ ! -s "$icon_assets" ]; then
    printf '%s\n' "FAIL: $icon_label is missing its compiled AppIcon resources" >&2
    exit 1
  fi

  icon_file_name="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$icon_info_plist" 2>/dev/null || true)"
  icon_asset_name="$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$icon_info_plist" 2>/dev/null || true)"
  if [ "$icon_file_name" != "AppIcon" ] || [ "$icon_asset_name" != "AppIcon" ]; then
    printf '%s\n' "FAIL: $icon_label Info.plist does not identify AppIcon" >&2
    exit 1
  fi

  icon_asset_info="$(/usr/bin/mktemp "$BUILD_ROOT/app-icon-assets.XXXXXX")"
  if ! /usr/bin/assetutil --info "$icon_assets" >"$icon_asset_info"; then
    /bin/rm -f "$icon_asset_info"
    printf '%s\n' "FAIL: $icon_label AppIcon assets could not be inspected" >&2
    exit 1
  fi
  icon_rendition_count="$(
    /usr/bin/awk '
          /^[[:space:]]*\{/ {
            in_object = 1
            is_icon = 0
            is_app_icon = 0
          }
          /"AssetType" : "Icon Image"/ { is_icon = 1 }
          /"Name" : "AppIcon"/ { is_app_icon = 1 }
          /^[[:space:]]*\},?[[:space:]]*$/ {
            if (in_object && is_icon && is_app_icon) {
              count += 1
            }
            in_object = 0
          }
          END { print count + 0 }
        ' "$icon_asset_info"
  )"
  /bin/rm -f "$icon_asset_info"
  case "$icon_rendition_count" in
    ''|*[!0-9]*) icon_rendition_count=0 ;;
  esac
  if [ "$icon_rendition_count" -lt 10 ]; then
    printf '%s\n' "FAIL: $icon_label contains only $icon_rendition_count AppIcon renditions" >&2
    exit 1
  fi

  icon_decode_root="$(/usr/bin/mktemp -d "$BUILD_ROOT/icon-verify.XXXXXX")"
  if ! /usr/bin/iconutil --convert iconset \
    --output "$icon_decode_root/AppIcon.iconset" \
    "$icon_icns" >/dev/null 2>&1; then
    /bin/rm -rf "$icon_decode_root"
    printf '%s\n' "FAIL: $icon_label AppIcon.icns could not be decoded" >&2
    exit 1
  fi
  /bin/rm -rf "$icon_decode_root"
  printf '%s\n' "PASS: $icon_label contains the complete VibeStick AppIcon"
}

assert_menu_bar_source_contract() {
  app_entry="$ROOT_DIR/app/macos/VibeStickApp/App/VibeStickForMacApp.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"

  if ! /usr/bin/awk '
    function without_comments(source, output, open_at, close_at, line_comment_at) {
      output = ""
      while (length(source) > 0) {
        if (in_block_comment) {
          close_at = index(source, "*/")
          if (!close_at) return output
          source = substr(source, close_at + 2)
          in_block_comment = 0
        } else {
          open_at = index(source, "/*")
          line_comment_at = index(source, "//")
          if (line_comment_at && (!open_at || line_comment_at < open_at)) {
            return output substr(source, 1, line_comment_at - 1)
          }
          if (!open_at) return output source
          output = output substr(source, 1, open_at - 1)
          source = substr(source, open_at + 2)
          in_block_comment = 1
        }
      }
      return output
    }
    {
      source_line = without_comments($0)
      if (source_line ~ /^[[:space:]]*MenuBarExtra\([[:space:]]*$/) {
        contract_stage = 1
      } else if (contract_stage == 1 &&
                 source_line ~ /^[[:space:]]*"VibeStick",[[:space:]]*$/) {
        contract_stage = 2
      } else if (contract_stage == 2 &&
                 source_line ~ /^[[:space:]]*image:[[:space:]]*"VibeStickMenuBar",[[:space:]]*$/) {
        contract_stage = 3
      } else if (contract_stage == 3 &&
                 source_line ~ /^[[:space:]]*isInserted:[[:space:]]*\$menuBarItemInserted[[:space:]]*$/) {
        contract_stage = 4
      } else if (contract_stage == 4 &&
                 source_line ~ /^[[:space:]]*\)[[:space:]]*\{[[:space:]]*$/) {
        found = 1
        contract_stage = 0
      } else if (source_line !~ /^[[:space:]]*$/) {
        contract_stage = 0
      }
    }
    END { exit found ? 0 : 1 }
  ' "$app_entry"; then
    printf '%s\n' "FAIL: MenuBarExtra is not using the VibeStick menu bar asset" >&2
    exit 1
  fi
  if /usr/bin/grep -E 'menuBarSystemImage|bolt\.horizontal\.circle|exclamationmark\.circle\.fill' \
    "$app_entry" "$app_model" >/dev/null; then
    printf '%s\n' "FAIL: the legacy SF Symbol menu bar icon path is still present" >&2
    exit 1
  fi
  printf '%s\n' "PASS: source uses the branded VibeStick menu bar asset"
}

assert_m1_polish_source_contract() {
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"
  infrastructure="$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift"

  if ! /usr/bin/grep -F 'Text("显示故障排查信息")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Button("打开本地数据文件夹（故障排查）")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Label("草图", systemImage: "pencil.and.outline")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Text("状态区域")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'NSWorkspace.shared.open(SupportPaths.supportDirectory)' "$infrastructure" >/dev/null; then
    printf '%s\n' "FAIL: the M1 usability polish source contract is incomplete" >&2
    exit 1
  fi

  if /usr/bin/grep -E 'activateFileViewerSelecting|revealSupportDirectory|private var deviceStatus|bridgeSnapshot\.state\?\.codexState\?\.status|if let project = model\.configurationSummary\.projectName|显示技术名称和服务标识' \
    "$section_views" "$infrastructure" >/dev/null; then
    printf '%s\n' "FAIL: a misleading M1 preview or legacy Finder interaction remains" >&2
    exit 1
  fi
  printf '%s\n' "PASS: source keeps diagnostics understandable and the device preview explicitly schematic"
}

assert_menu_bar_icon() {
  menu_app_path="$1"
  menu_label="$2"
  menu_assets="$menu_app_path/Contents/Resources/Assets.car"
  menu_binary="$menu_app_path/Contents/MacOS/VibeStick for Mac"

  if [ ! -s "$menu_assets" ] || [ ! -x "$menu_binary" ]; then
    printf '%s\n' "FAIL: $menu_label is missing compiled asset resources" >&2
    exit 1
  fi

  menu_binary_strings="$(/usr/bin/mktemp "$BUILD_ROOT/menu-bar-binary.XXXXXX")"
  if ! /usr/bin/strings "$menu_binary" >"$menu_binary_strings"; then
    /bin/rm -f "$menu_binary_strings"
    printf '%s\n' "FAIL: $menu_label menu bar asset reference could not be inspected" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fx 'VibeStickMenuBar' "$menu_binary_strings" >/dev/null; then
    /bin/rm -f "$menu_binary_strings"
    printf '%s\n' "FAIL: $menu_label does not reference the VibeStick menu bar asset" >&2
    exit 1
  fi
  /bin/rm -f "$menu_binary_strings"

  menu_asset_info="$(/usr/bin/mktemp "$BUILD_ROOT/menu-bar-assets.XXXXXX")"
  if ! /usr/bin/assetutil --info "$menu_assets" >"$menu_asset_info"; then
    /bin/rm -f "$menu_asset_info"
    printf '%s\n' "FAIL: $menu_label menu bar assets could not be inspected" >&2
    exit 1
  fi
  menu_renditions="$(
    /usr/bin/awk '
          /^[[:space:]]*\{/ {
            in_object = 1
            is_image = 0
            is_menu_icon = 0
            is_monochrome = 0
            is_transparent = 0
            is_template = 0
            preserves_vector = 0
            width = 0
            height = 0
            scale = 0
          }
          /"AssetType" : "Image"/ { is_image = 1 }
          /"Name" : "VibeStickMenuBar"/ { is_menu_icon = 1 }
          /"ColorModel" : "Monochrome"/ { is_monochrome = 1 }
          /"Opaque" : false/ { is_transparent = 1 }
          /"Template Mode" : "template"/ { is_template = 1 }
          /"Preserved Vector Representation" : true/ { preserves_vector = 1 }
          /"PixelWidth"[[:space:]]*:[[:space:]]*18[[:space:]]*,?[[:space:]]*$/ { width = 18 }
          /"PixelWidth"[[:space:]]*:[[:space:]]*36[[:space:]]*,?[[:space:]]*$/ { width = 36 }
          /"PixelHeight"[[:space:]]*:[[:space:]]*18[[:space:]]*,?[[:space:]]*$/ { height = 18 }
          /"PixelHeight"[[:space:]]*:[[:space:]]*36[[:space:]]*,?[[:space:]]*$/ { height = 36 }
          /"Scale"[[:space:]]*:[[:space:]]*1[[:space:]]*,?[[:space:]]*$/ { scale = 1 }
          /"Scale"[[:space:]]*:[[:space:]]*2[[:space:]]*,?[[:space:]]*$/ { scale = 2 }
          /^[[:space:]]*\},?[[:space:]]*$/ {
            if (in_object && is_image && is_menu_icon && is_monochrome &&
                is_transparent && is_template && preserves_vector) {
              if (width == 18 && height == 18 && scale == 1) one_x += 1
              if (width == 36 && height == 36 && scale == 2) two_x += 1
            }
            in_object = 0
          }
          END { print one_x + 0, two_x + 0 }
        ' "$menu_asset_info"
  )"
  /bin/rm -f "$menu_asset_info"
  set -- $menu_renditions
  if [ "${1:-0}" -lt 1 ] || [ "${2:-0}" -lt 1 ]; then
    printf '%s\n' "FAIL: $menu_label lacks complete 18pt template menu bar renditions" >&2
    exit 1
  fi
  printf '%s\n' "PASS: $menu_label contains the branded 18pt template menu bar icon"
}

assert_no_forbidden_files() {
  forbidden_root="$1"
  forbidden_label="$2"
  forbidden_files="$(/usr/bin/find "$forbidden_root" \( \
    -name '.DS_Store' -o \
    -name '.env' -o \
    -name '.env.*' -o \
    -name 'vibe_stick_secrets.h' -o \
    -name '.vibestick-state.json' -o \
    -name 'CLAUDE_PROVIDER_PLAN.md' -o \
    -name '*.token' -o \
    -name '*.key' -o \
    -name '*.pem' -o \
    -name '*.p12' -o \
    -name '*.log' -o \
    -name '*.jsonl' -o \
    -name '*.wav' -o \
    -name '*.pcm' -o \
    -name '*.m4a' -o \
    -name '*.caf' -o \
    -name '*.mp3' -o \
    -name '*.pyc' -o \
    -name 'Recordings' -o \
    -name 'recordings' -o \
    -name '__pycache__' -o \
    -name '.pytest_cache' -o \
    -name '.venv' -o \
    -name 'venv' -o \
    -name 'node_modules' -o \
    -name 'dist' -o \
    -name '.git' -o \
    -name '.build' -o \
    -name 'build' -o \
    -name 'DerivedData' -o \
    -name '.swiftpm' -o \
    -name '.vscode' -o \
    -name '.idea' -o \
    -name '*.xcassets' -o \
    -name '*.appiconset' -o \
    -name '*.psd' -o \
    -name '*.ai' -o \
    -name '*.sketch' -o \
    -name '.pio' -o \
    -name 'managed_components' -o \
    -name 'sdkconfig' -o \
    -name 'sdkconfig.old' -o \
    -name 'esp-idf' -o \
    -name '.espressif' -o \
    -name '*Tests*' \
  \) -print)"
  if [ -n "$forbidden_files" ]; then
    printf '%s\n' "FAIL: $forbidden_label contains forbidden development or private files" >&2
    printf '%s\n' "$forbidden_files" >&2
    exit 1
  fi
}

launch_agent_pid() {
  launch_agent_label="$1"
  /bin/launchctl print "gui/$(/usr/bin/id -u)/$launch_agent_label" 2>/dev/null | /usr/bin/awk '
    $1 == "pid" && $2 == "=" { print $3; exit }
  ' || true
}

stop_smoke_app() {
  stop_target_pid="$1"

  if [ -n "$stop_target_pid" ] && /bin/kill -0 "$stop_target_pid" 2>/dev/null; then
    /bin/kill -TERM "$stop_target_pid" 2>/dev/null || true
    stop_attempt=0
    while [ "$stop_attempt" -lt 30 ] && /bin/kill -0 "$stop_target_pid" 2>/dev/null; do
      /bin/sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
    if /bin/kill -0 "$stop_target_pid" 2>/dev/null; then
      /bin/kill -KILL "$stop_target_pid" 2>/dev/null || true
    fi
  fi
  if [ -n "$stop_target_pid" ]; then
    wait "$stop_target_pid" 2>/dev/null || true
  fi
}

ACTIVE_SMOKE_PID=""
ACTIVE_SMOKE_DIR=""
MOUNT_POINT=""
mounted=0

cleanup_all() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM

  if [ -n "$ACTIVE_SMOKE_PID" ]; then
    stop_smoke_app "$ACTIVE_SMOKE_PID"
    ACTIVE_SMOKE_PID=""
  fi
  if [ "$mounted" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    mounted=0
  fi
  if [ -n "$MOUNT_POINT" ]; then
    /bin/rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
  case "$ACTIVE_SMOKE_DIR" in
    "$BUILD_ROOT"/launch-smoke.*)
      /bin/rm -rf "$ACTIVE_SMOKE_DIR"
      ;;
  esac
  ACTIVE_SMOKE_DIR=""
  exit "$cleanup_status"
}

trap cleanup_all EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

assert_app_launch_smoke() {
  smoke_app_path="$1"
  smoke_label="$2"
  smoke_dir="$(/usr/bin/mktemp -d "$BUILD_ROOT/launch-smoke.XXXXXX")"
  smoke_heartbeat="$smoke_dir/heartbeat.json"
  smoke_stdout="$smoke_dir/stdout.log"
  smoke_stderr="$smoke_dir/stderr.log"
  smoke_sample="$smoke_dir/hang.sample.txt"
  smoke_runtime_log="$smoke_dir/runtime.log"
  smoke_app_binary="$smoke_app_path/Contents/MacOS/VibeStick for Mac"
  smoke_app_pid=""
  smoke_sequence=0
  smoke_model_changes=0
  smoke_window_visible=false
  smoke_passed=0
  bridge_pid_before="$(launch_agent_pid com.vibestick.bridge)"
  hud_pid_before="$(launch_agent_pid com.vibestick.hud)"

  ACTIVE_SMOKE_DIR="$smoke_dir"
  VIBESTICK_SMOKE_OUTPUT="$smoke_heartbeat" \
    "$smoke_app_binary" >"$smoke_stdout" 2>"$smoke_stderr" &
  smoke_app_pid=$!
  ACTIVE_SMOKE_PID="$smoke_app_pid"

  smoke_attempt=0
  while [ "$smoke_attempt" -lt 80 ]; do
    if [ -f "$smoke_heartbeat" ]; then
      smoke_sequence="$(/usr/bin/plutil -extract sequence raw -o - "$smoke_heartbeat" 2>/dev/null || printf '0')"
      smoke_reported_pid="$(/usr/bin/plutil -extract pid raw -o - "$smoke_heartbeat" 2>/dev/null || true)"
      smoke_model_changes="$(/usr/bin/plutil -extract modelChanges raw -o - "$smoke_heartbeat" 2>/dev/null || printf '0')"
      smoke_window_visible="$(/usr/bin/plutil -extract windowVisible raw -o - "$smoke_heartbeat" 2>/dev/null || printf 'false')"
      case "$smoke_sequence" in
        ''|*[!0-9]*) smoke_sequence=0 ;;
      esac
      case "$smoke_model_changes" in
        ''|*[!0-9]*) smoke_model_changes=0 ;;
      esac
      if [ "$smoke_sequence" -ge 15 ] \
        && [ "$smoke_reported_pid" = "$smoke_app_pid" ] \
        && [ "$smoke_window_visible" = "true" ] \
        && [ "$smoke_model_changes" -lt 50 ] \
        && /bin/kill -0 "$smoke_app_pid" 2>/dev/null; then
        smoke_passed=1
        break
      fi
    fi
    if ! /bin/kill -0 "$smoke_app_pid" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.1
    smoke_attempt=$((smoke_attempt + 1))
  done

  if [ "$smoke_passed" -ne 1 ]; then
    if [ -n "$smoke_app_pid" ] && /bin/kill -0 "$smoke_app_pid" 2>/dev/null; then
      /usr/bin/sample "$smoke_app_pid" 2 10 -file "$smoke_sample" >/dev/null 2>&1 || true
    fi
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label did not keep its main interface responsive during launch" >&2
    if [ -s "$smoke_stderr" ]; then
      /bin/cat "$smoke_stderr" >&2
    fi
    if [ -f "$smoke_sample" ]; then
      printf '%s\n' "Startup sample: $smoke_sample" >&2
    fi
    exit 1
  fi

  first_sequence="$smoke_sequence"
  /bin/sleep 0.5
  final_sequence="$(/usr/bin/plutil -extract sequence raw -o - "$smoke_heartbeat" 2>/dev/null || printf '0')"
  final_model_changes="$(/usr/bin/plutil -extract modelChanges raw -o - "$smoke_heartbeat" 2>/dev/null || printf '0')"
  case "$final_sequence" in
    ''|*[!0-9]*) final_sequence=0 ;;
  esac
  case "$final_model_changes" in
    ''|*[!0-9]*) final_model_changes=0 ;;
  esac
  if [ "$final_sequence" -le "$first_sequence" ] || [ "$final_model_changes" -ge 50 ]; then
    /usr/bin/sample "$smoke_app_pid" 2 10 -file "$smoke_sample" >/dev/null 2>&1 || true
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label launch heartbeat stopped or model updates exceeded the safe limit" >&2
    printf '%s\n' "Startup sample: $smoke_sample" >&2
    exit 1
  fi

  /bin/sleep 0.5
  if ! /usr/bin/log show --last 1m --style compact \
    --predicate "processIdentifier == $smoke_app_pid AND eventMessage CONTAINS \"Publishing changes from within view updates\"" \
    >"$smoke_runtime_log" 2>/dev/null; then
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label startup warnings could not be inspected" >&2
    exit 1
  fi
  smoke_warning_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$smoke_runtime_log")"
  if [ "$smoke_warning_count" -ne 0 ]; then
    /usr/bin/sample "$smoke_app_pid" 2 10 -file "$smoke_sample" >/dev/null 2>&1 || true
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label published model changes during a view update" >&2
    printf '%s\n' "Startup sample: $smoke_sample" >&2
    exit 1
  fi

  if ! /bin/kill -0 "$smoke_app_pid" 2>/dev/null; then
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label exited before startup verification completed" >&2
    exit 1
  fi

  smoke_rss="$(/bin/ps -o rss= -p "$smoke_app_pid" 2>/dev/null | /usr/bin/tr -d ' ')"
  case "$smoke_rss" in
    ''|*[!0-9]*|0)
      stop_smoke_app "$smoke_app_pid"
      ACTIVE_SMOKE_PID=""
      ACTIVE_SMOKE_DIR=""
      printf '%s\n' "FAIL: $smoke_label resource state could not be verified" >&2
      exit 1
      ;;
  esac
  if [ "$smoke_rss" -gt 524288 ]; then
    /usr/bin/sample "$smoke_app_pid" 2 10 -file "$smoke_sample" >/dev/null 2>&1 || true
    stop_smoke_app "$smoke_app_pid"
    ACTIVE_SMOKE_PID=""
    ACTIVE_SMOKE_DIR=""
    printf '%s\n' "FAIL: $smoke_label used more than 512 MiB during launch" >&2
    printf '%s\n' "Startup sample: $smoke_sample" >&2
    exit 1
  fi

  stop_smoke_app "$smoke_app_pid"
  ACTIVE_SMOKE_PID=""

  bridge_pid_after="$(launch_agent_pid com.vibestick.bridge)"
  hud_pid_after="$(launch_agent_pid com.vibestick.hud)"
  if [ "$bridge_pid_before" != "$bridge_pid_after" ] || [ "$hud_pid_before" != "$hud_pid_after" ]; then
    printf '%s\n' "FAIL: $smoke_label changed an existing Bridge or HUD process" >&2
    exit 1
  fi

  /bin/rm -rf "$smoke_dir"
  ACTIVE_SMOKE_DIR=""
  printf '%s\n' "PASS: $smoke_label launched responsively without changing Bridge or HUD"
}

assert_menu_bar_source_contract
assert_m1_polish_source_contract
"$ROOT_DIR/scripts/build-macos-app.sh"
assert_binary "$APP_BINARY" "VibeStick for Mac"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
assert_app_icon "$APP_PATH" "built app"
assert_menu_bar_icon "$APP_PATH" "built app"

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

assert_binary "$BRIDGE_APP/Contents/MacOS/VibeStickBridge" "VibeStick Bridge"
assert_binary "$HUD_APP/Contents/MacOS/VibeStickHUD" "VibeStick HUD"
assert_binary "$PASTE_APP/Contents/MacOS/VibeStickPaste" "VibeStick Paste"
sign_and_verify_bundle "$BRIDGE_APP" "VibeStick Bridge"
sign_and_verify_bundle "$HUD_APP" "VibeStick HUD"
sign_and_verify_bundle "$PASTE_APP" "VibeStick Paste"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme VibeStickForMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

sign_and_verify_bundle "$TEST_BUNDLE" "VibeStick hostless tests"
assert_binary "$TEST_BUNDLE/Contents/MacOS/VibeStickForMacTests" "VibeStick hostless tests"
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest "$TEST_BUNDLE"
printf '%s\n' "PASS: Swift unit tests executed"

assert_no_forbidden_files "$APP_PATH" "built app"
assert_app_launch_smoke "$APP_PATH" "built app"

if [ -d "$APP_PATH/Contents/Helpers/VibeStick Paste.app" ]; then
  printf '%s\n' "FAIL: M1 must not bundle or replace the installed Paste identity" >&2
  exit 1
fi

"$ROOT_DIR/scripts/build-macos-dmg.sh"

MOUNT_POINT="$(/usr/bin/mktemp -d "$BUILD_ROOT/dmg-verify.XXXXXX")"

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
mounted=1

if [ ! -d "$MOUNT_POINT/VibeStick for Mac.app" ]; then
  printf '%s\n' "FAIL: DMG does not contain VibeStick for Mac.app" >&2
  exit 1
fi
if [ ! -L "$MOUNT_POINT/Applications" ] || [ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" != "/Applications" ]; then
  printf '%s\n' "FAIL: DMG Applications link is missing or incorrect" >&2
  exit 1
fi

root_entry_count="$(/usr/bin/find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [ "$root_entry_count" != "2" ]; then
  printf '%s\n' "FAIL: DMG root contains unexpected entries" >&2
  /usr/bin/find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print >&2
  exit 1
fi

MOUNTED_APP="$MOUNT_POINT/VibeStick for Mac.app"
/usr/bin/codesign --verify --deep --strict "$MOUNTED_APP"
assert_binary "$MOUNTED_APP/Contents/MacOS/VibeStick for Mac" "DMG VibeStick for Mac"
assert_app_icon "$MOUNTED_APP" "DMG app"
assert_menu_bar_icon "$MOUNTED_APP" "DMG app"

assert_no_forbidden_files "$MOUNT_POINT" "mounted DMG"
assert_app_launch_smoke "$MOUNTED_APP" "DMG app"

/usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
mounted=0
/bin/rmdir "$MOUNT_POINT"
MOUNT_POINT=""

printf '%s\n' "PASS: app, helpers, tests, signatures, and DMG contents verified"
