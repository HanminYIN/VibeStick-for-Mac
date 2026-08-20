#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/macos/VibeStick.xcodeproj"
BUILD_ROOT="${VIBESTICK_BUILD_ROOT:-$ROOT_DIR/.build/macos.noindex}"
APP_PATH="$BUILD_ROOT/VibeStick for Mac.app"
APP_BINARY="$APP_PATH/Contents/MacOS/VibeStick for Mac"
DMG_PATH="$BUILD_ROOT/VibeStick-for-Mac-0.2.0-rc.2.dmg"
TEST_DERIVED_DATA="$BUILD_ROOT/VerificationTests-DerivedData"
TEST_BUNDLE="$TEST_DERIVED_DATA/Build/Products/Debug/VibeStickForMacTests.xctest"
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
RUN_LAUNCH_SMOKE="${VIBESTICK_RUN_LAUNCH_SMOKE:-1}"
TRUSTED_FIRMWARE_PAYLOAD="${VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD:-$ROOT_DIR/release/firmware/sticks3/0.2.0-m4.4a}"
SWIFT_MODULE_CACHE="$BUILD_ROOT/SwiftModuleCache.noindex"
mkdir -p "$SWIFT_MODULE_CACHE"

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

assert_bundle_version() {
  bundle_path="$1"
  bundle_label="$2"
  info_plist="$bundle_path/Contents/Info.plist"
  short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
  build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")"
  if [ "$short_version" != "0.2.0" ] || [ "$build_version" != "11" ]; then
    printf '%s\n' "FAIL: $bundle_label version is $short_version ($build_version), expected 0.2.0 (11)" >&2
    exit 1
  fi
  printf '%s\n' "PASS: $bundle_label version is 0.2.0 (11)"
}

assert_local_network_metadata() {
  app_bundle="$1"
  bridge_bundle="$2"
  bundle_label="$3"

  for info_plist in \
    "$app_bundle/Contents/Info.plist" \
    "$bridge_bundle/Contents/Info.plist"; do
    purpose="$(/usr/bin/plutil -extract NSLocalNetworkUsageDescription raw -o - "$info_plist" 2>/dev/null || true)"
    bonjour_service="$(/usr/bin/plutil -extract NSBonjourServices.0 raw -o - "$info_plist" 2>/dev/null || true)"
    if [ -z "$purpose" ] || [ "$bonjour_service" != "_vibestick._tcp" ]; then
      printf '%s\n' "FAIL: $bundle_label is missing the local-network purpose or _vibestick._tcp Bonjour declaration" >&2
      exit 1
    fi
  done

  printf '%s\n' "PASS: $bundle_label declares local-network use and _vibestick._tcp Bonjour service"
}

sign_and_verify_bundle() {
  bundle_path="$1"
  label="$2"
  /usr/bin/codesign --force --sign - "$bundle_path"
  /usr/bin/codesign --verify --deep --strict "$bundle_path"
  printf '%s\n' "PASS: $label ad-hoc signature verified"
}

verify_bundle_signature() {
  bundle_path="$1"
  label="$2"
  /usr/bin/codesign --verify --deep --strict "$bundle_path"
  printf '%s\n' "PASS: $label embedded signature verified without mutation"
}

assert_license_bundle() {
  license_app_path="$1"
  license_label="$2"
  license_root="$license_app_path/Contents/Resources/Licenses"
  for required_license in \
    VibeStick-MIT.txt \
    VibeStick-NOTICE.txt \
    SIL-OFL-1.1.txt \
    THIRD-PARTY-LICENSES.md \
    Firmware/ESP-IDF-Apache-2.0.txt \
    Firmware/LVGL-MIT.txt \
    Firmware/FatFs.txt \
    Firmware/GCC-GPL-3.0.txt \
    Firmware/GCC-Runtime-Library-Exception-3.1.txt \
    Firmware/Newlib-COPYING.txt \
    Firmware/wpa_supplicant-BSD.txt; do
    if [ ! -s "$license_root/$required_license" ]; then
      printf '%s\n' "FAIL: $license_label is missing $required_license" >&2
      exit 1
    fi
  done
  if /usr/bin/find "$license_root" -type l -print -quit | /usr/bin/grep -q .; then
    printf '%s\n' "FAIL: $license_label license inventory contains a symbolic link" >&2
    exit 1
  fi
  license_count="$(/usr/bin/find "$license_root" -type f -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if [ "$license_count" -lt 24 ]; then
    printf '%s\n' "FAIL: $license_label license inventory contains only $license_count files" >&2
    exit 1
  fi
  printf '%s\n' "PASS: $license_label contains the offline project, font, firmware, and toolchain notices"
}

assert_trusted_firmware_payload() {
  candidate_root="$1"
  candidate_label="$2"
  python3 "$ROOT_DIR/scripts/firmware-payload-manifest.py" verify-source \
    "$TRUSTED_FIRMWARE_PAYLOAD" "$ROOT_DIR/firmware/sticks3"
  python3 "$ROOT_DIR/scripts/firmware-payload-manifest.py" verify "$candidate_root"
  for payload_file in bootloader.bin partition-table.bin vibe-stick.bin manifest-v1.json; do
    if ! /usr/bin/cmp -s "$TRUSTED_FIRMWARE_PAYLOAD/$payload_file" "$candidate_root/$payload_file"; then
      printf '%s\n' "FAIL: $candidate_label firmware payload differs from the accepted M4-5K payload" >&2
      exit 1
    fi
  done
  printf '%s\n' "PASS: $candidate_label firmware payload is byte-identical to the accepted M4-5K payload"
}

detach_disk_image() {
  detach_target="$1"
  detach_attempt=0
  while [ "$detach_attempt" -lt 10 ]; do
    if /usr/bin/hdiutil detach "$detach_target" >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.2
    detach_attempt=$((detach_attempt + 1))
  done
  /usr/bin/hdiutil detach -force "$detach_target" >/dev/null
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

assert_m3b_interface_source_contract() {
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"
  infrastructure="$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift"
  firmware_ui="$ROOT_DIR/firmware/sticks3/src/vibe_ui.c"

  if ! /usr/bin/grep -F 'Text("显示故障排查信息")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Button("打开本地数据文件夹（故障排查）")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Label("135 × 240", systemImage: "display")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'title: "Codex Focus 实时预览"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Toggle(' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '"在设备首页显示项目名称"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Text("LEFT")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'private var previewModel: CodexFocusPreviewModel' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'Image("CodexDeviceIcon")' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'batteryPercent.map { "\($0)%" } ?? "--%"' "$ROOT_DIR/app/macos/VibeStickApp/Core/Models.swift" >/dev/null \
    || ! /usr/bin/grep -F '.minimumScaleFactor(0.75)' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'make_label(screen, "LEFT", &lv_font_montserrat_12' "$firmware_ui" >/dev/null \
    || ! /usr/bin/grep -F 'focus_status_optics' "$firmware_ui" >/dev/null \
    || ! /usr/bin/grep -F 'NSWorkspace.shared.open(SupportPaths.supportDirectory)' "$infrastructure" >/dev/null \
    || ! /usr/bin/grep -F 'title: "当前语音链路"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'title: "最近一次设备语音"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'voiceInteractionVersion' "$ROOT_DIR/app/macos/VibeStickApp/Core/Models.swift" >/dev/null \
    || ! /usr/bin/grep -F 'to_persisted_jsonable' "$ROOT_DIR/bridge/src/vibe_stick/audio/recorder.py" >/dev/null; then
    printf '%s\n' "FAIL: the M3-B interface source contract is incomplete" >&2
    exit 1
  fi

  if /usr/bin/grep -E 'activateFileViewerSelecting|revealSupportDirectory|private var deviceStatus|bridgeSnapshot\.state\?\.codexState\?\.status|if let project = model\.configurationSummary\.projectName|显示技术名称和服务标识' \
    "$section_views" "$infrastructure" >/dev/null; then
    printf '%s\n' "FAIL: a misleading M1 preview or legacy Finder interaction remains" >&2
    exit 1
  fi
  if /usr/bin/grep -F 'Text("96%")' "$section_views" >/dev/null \
    || /usr/bin/grep -F 'Text("98%")' "$section_views" >/dev/null \
    || /usr/bin/grep -F 'Image(systemName: "terminal.fill")' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the Codex Focus preview still contains synthetic telemetry or a substitute icon" >&2
    exit 1
  fi
  printf '%s\n' "PASS: source keeps diagnostics understandable and the device preview tracks M3 Codex Focus"
}

assert_m3c_asr_source_contract() {
  m3c_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M3CInfrastructure.swift"
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"
  app_info="$ROOT_DIR/app/macos/VibeStickApp/Resources/Info.plist"
  transcriber="$ROOT_DIR/bridge/src/vibe_stick/audio/transcriber.py"
  native_runtime_configuration="$ROOT_DIR/app/macos/VibeStickBridge/NativeBridgeRuntimeConfiguration.swift"

  if ! /usr/bin/grep -F 'actor ASRKeychainManager' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F 'case siliconFlow = "siliconflow"' "$ROOT_DIR/app/macos/VibeStickApp/Core/Models.swift" >/dev/null \
    || ! /usr/bin/grep -F 'title: "独立供应方测试"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'currentMilestone: "M3-C"' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '不注入 · 不按 Return' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F 'actor ASRTestAudioGenerator' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F '"/usr/bin/say"' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F 'static let expectedTranscript = "语音测试成功"' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F 'ASRTestTranscriptComparator.matches' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F '.posixPermissions: 0o600' "$m3c_source" >/dev/null \
    || ! /usr/bin/grep -F 'SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess' "$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift" >/dev/null \
    || ! /usr/bin/grep -F 'SecTrustedApplicationCreateFromPath' "$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift" >/dev/null \
    || ! /usr/bin/grep -F 'kSecAttrAccess as String' "$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift" >/dev/null \
    || ! /usr/bin/grep -F 'asrAdditionalTrustedApplicationPaths = ["/usr/bin/security"]' "$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift" >/dev/null \
    || ! /usr/bin/grep -F 'securityExecutable = "/usr/bin/security"' "$native_runtime_configuration" >/dev/null \
    || ! /usr/bin/grep -F 'find-generic-password' "$native_runtime_configuration" >/dev/null \
    || ! /usr/bin/grep -F 'existingItemUpdateAttributes(data: data)' "$ROOT_DIR/app/macos/VibeStickApp/Core/Infrastructure.swift" >/dev/null \
    || ! /usr/bin/grep -F 'await asrSecretManager.containsAPIKey()' "$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift" >/dev/null \
    || ! /usr/bin/grep -F 'find-generic-password' "$transcriber" >/dev/null \
    || ! /usr/bin/grep -F 'config-v1.json' "$transcriber" >/dev/null; then
    printf '%s\n' "FAIL: the M3-C native ASR source contract is incomplete" >&2
    exit 1
  fi
  if /usr/bin/grep -F 'prepareAPIKeyAccess' "$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift" "$m3c_source" >/dev/null; then
    printf '%s\n' "FAIL: routine ASR saves must not rewrite an existing keychain ACL" >&2
    exit 1
  fi

  if /usr/bin/grep -F 'SecItemCopyMatching' "$native_runtime_configuration" >/dev/null; then
    printf '%s\n' "FAIL: the native Bridge must use the fixed Keychain tool already trusted by the managed ACL" >&2
    exit 1
  fi

  if /usr/bin/grep -E 'AVAudioRecorder|AVCaptureDevice|ASRMacAudioInputProbe|PasteInjector|NSPasteboard|confirm_return|recording/(start|audio|stop|send/confirm)' \
    "$m3c_source" >/dev/null \
    || /usr/bin/grep -F 'NSMicrophoneUsageDescription' "$app_info" >/dev/null; then
    printf '%s\n' "FAIL: the independent M3-C ASR test is coupled to a Mac microphone, text injection, or M3-B recording endpoints" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M3-C ASR configuration uses Keychain and a fixed injection-independent audio fixture"
}

assert_m4_install_source_contract() {
  installer_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4RuntimeInstaller.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"

  if ! /usr/bin/grep -F 'RuntimePayload.noindex' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'manifest-v1.json' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'Backups.noindex' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'revalidateBeforeMutation' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'runtimeInstallConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'allowsPayloadInstall' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F '重新安装已验证后台组件' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '继续并保留回退副本' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the M4-2 transaction, rollback, or explicit-confirmation source contract is incomplete" >&2
    exit 1
  fi
  if /usr/bin/grep -F 'scripts/install.sh' "$installer_source" "$app_model" >/dev/null \
    || /usr/bin/grep -E 'esptool|idf\.py|erase_flash|write_flash|VIBE_STICK_PYTHON_PATH|compatiblePythonPath|runtime/bridge' \
      "$installer_source" "$ROOT_DIR/scripts/build-macos-runtime-payload.sh" >/dev/null; then
    printf '%s\n' "FAIL: the distributed M4-2 installer references a developer installer or firmware mutation" >&2
    exit 1
  fi
  if ! /usr/bin/grep -F 'NativeBridgeProductionFactory.make' \
      "$ROOT_DIR/app/macos/VibeStickBridge/main.swift" >/dev/null \
    || [ ! -f "$ROOT_DIR/scripts/runtime-payload-manifest.swift" ] \
    || ! /usr/bin/grep -F 'AssociatedBundleIdentifiers' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'io.github.hanminyin.vibestick' "$installer_source" >/dev/null \
    || ! /usr/bin/grep -F 'serviceVerificationAttempts = 480' "$installer_source" >/dev/null; then
    printf '%s\n' "FAIL: the distributed Bridge or payload manifest is not native Swift" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-2 source keeps confirmation, revalidation, backup, local-network handoff, and firmware boundaries"
}

assert_m4_flashing_tool_source_contract() {
  tool_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4FlashingTool.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"

  if ! /usr/bin/grep -F 'esptool-v5.3.1-macos-arm64.tar.gz' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'size: 61_218_014' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'f63f7203d88cfe4c17aea34d6cf82769458ce204e49a05816c6384c2d299e6ca' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'HTTPSOnlyRedirectDelegate' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'session.download(for: request)' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'RuntimePayloadDigest.sha256(of: url)' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'Darwin.rename' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'flashingToolDownloadConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F '下载并校验固定版本的烧录工具？' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the M4-3 pinned HTTPS download and cache contract is incomplete" >&2
    exit 1
  fi

  if /usr/bin/grep -E 'write_flash|erase_flash|read_flash|verify_flash|idf\.py|/dev/(cu|tty)' \
    "$tool_source" >/dev/null; then
    printf '%s\n' "FAIL: the flashing-tool workflow contains serial or firmware mutation behavior" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-3 pins HTTPS, size, SHA-256, private cache, and no-flash boundaries"

  if ! /usr/bin/grep -F 'SystemTarFlashingToolExtractor' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'Set(listedNames).count == listedNames.count' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'cb6109272050558582626b676b2bbf3737ed126df5faef373c5c66fae9c27097' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'QWXF6GB4AV' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'SecStaticCodeCheckValidity' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'arguments: ["version"]' "$tool_source" >/dev/null \
    || ! /usr/bin/grep -F 'flashingToolPreparationConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F '解包并离线验证固定烧录工具？' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '不会扫描或打开串口' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the M4-4B extraction, identity, or offline-version contract is incomplete" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-4B pins archive entries, inner digests, arm64 identity, Espressif signature, and version-only execution"
}

assert_m4_firmware_payload_source_contract() {
  firmware_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4FirmwarePayload.swift"
  pairing_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M2Infrastructure.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"
  connection_view="$ROOT_DIR/app/macos/VibeStickApp/Features/ConnectionAndRuntimeView.swift"
  firmware_config="$ROOT_DIR/firmware/sticks3/include/vibe_stick_config.h"
  device_config="$ROOT_DIR/firmware/sticks3/src/vibe_device_config.c"
  pairing_firmware="$ROOT_DIR/firmware/sticks3/src/vibe_usb_pairing.c"
  payload_builder="$ROOT_DIR/scripts/build-macos-firmware-payload.sh"

  if ! /usr/bin/grep -F 'FirmwarePayload.noindex' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'VIBE_STICK_DISTRIBUTABLE_BUILD=ON' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'assert-no-secrets' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'VIBESTICK_ALLOW_FIRMWARE_REBUILD:-0' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'refusing to rebuild without VIBESTICK_ALLOW_FIRMWARE_REBUILD=1' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'release/firmware/sticks3/0.2.0-m4.4a' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'release/licenses/firmware' "$payload_builder" >/dev/null \
    || ! /usr/bin/grep -F 'static let preservedNVS' "$firmware_source" >/dev/null \
    || ! /usr/bin/grep -F '"partition-table.bin": 0x8000' "$firmware_source" >/dev/null \
    || ! /usr/bin/grep -F '"vibe-stick.bin": 0x10000' "$firmware_source" >/dev/null \
    || ! /usr/bin/grep -F '#if VIBE_STICK_DISTRIBUTABLE_BUILD' "$firmware_config" >/dev/null \
    || ! /usr/bin/grep -F 'schema_version == 1 || schema_version == 2' "$device_config" >/dev/null \
    || ! /usr/bin/grep -F '"wifi_ssid"' "$device_config" >/dev/null \
    || ! /usr/bin/grep -F '\"pairing_schema_version\":2' "$pairing_firmware" >/dev/null \
    || ! /usr/bin/grep -F 'struct WiFiProvisioningCredentials' "$pairing_source" >/dev/null \
    || ! /usr/bin/grep -F 'struct WiFiProvisioningDraft' "$pairing_source" >/dev/null \
    || ! /usr/bin/grep -F 'identity.wifiConfigured == false' "$pairing_source" >/dev/null \
    || ! /usr/bin/grep -F 'throw PairingError.wifiCredentialsRequired' "$pairing_source" >/dev/null \
    || ! /usr/bin/grep -F 'wifiCredentials: wifiCredentials' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'SecureField("Wi-Fi 密码"' "$connection_view" >/dev/null \
    || ! /usr/bin/grep -F '.privacySensitive()' "$connection_view" >/dev/null \
    || ! /usr/bin/grep -F 'wifiPassword = ""' "$connection_view" >/dev/null; then
    printf '%s\n' "FAIL: the M4-4A distributable firmware, USB provisioning, or payload contract is incomplete" >&2
    exit 1
  fi

  if /usr/bin/grep -E 'write.flash|erase.flash|read.flash|verify.flash|/dev/(cu|tty)|esptool' \
    "$firmware_source" "$payload_builder" >/dev/null; then
    printf '%s\n' "FAIL: M4-4A payload preparation contains device access or flashing behavior" >&2
    exit 1
  fi
  if /usr/bin/grep -E '@Published[^[:cntrl:]]*(wifiSSID|wifiPassword)' "$app_model" >/dev/null; then
    printf '%s\n' "FAIL: D0.2 must not retain Wi-Fi credentials in AppModel state" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-4A/D0.2 keeps secret-free firmware and fail-closed, ephemeral schema-v2 Wi-Fi provisioning"
}

assert_m4_device_backup_source_contract() {
  backup_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4DeviceBackup.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"

  if ! /usr/bin/grep -F 'FirmwareBackups.noindex' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '"get-security-info", "flash-id", "read-mac", "read-flash"' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '"--before", "no-reset"' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '"--no-stub"' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '"ESPTOOL_CFGFILE": workingDirectory.appendingPathComponent("esptool.cfg").path' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '"--after", resetAfterCommand ? "watchdog-reset" : "no-reset"' "$backup_source" >/dev/null \
    || [ "$(/usr/bin/grep -F -c '"read-flash", "--flash-size", descriptor.expectedFlashSizeLabel' "$backup_source")" -ne 2 ] \
    || ! /usr/bin/grep -F 'two-complete-reads-sha256-match' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '.posixPermissions: 0o700' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F '.posixPermissions: 0o600' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F 'device_fingerprint_sha256' "$backup_source" >/dev/null \
    || ! /usr/bin/grep -F 'deviceInspectionConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'deviceBackupConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F '建立私有 8 MiB 完整备份？' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the M4-4C device inspection, read-only backup, or explicit-confirmation contract is incomplete" >&2
    exit 1
  fi

  if /usr/bin/grep -E '"(write-flash|erase-flash|erase-region|verify-flash|write-mem|write-flash-status|load-ram)"' \
    "$backup_source" >/dev/null; then
    printf '%s\n' "FAIL: M4-4C contains a device mutation or M4-4D verification command" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-4C pins unique-device inspection, ROM-only commands, double-read verification, and private backup"
}

assert_m4_device_flash_source_contract() {
  flash_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4DeviceFlasher.swift"
  backup_source="$ROOT_DIR/app/macos/VibeStickApp/Core/M4DeviceBackup.swift"
  app_model="$ROOT_DIR/app/macos/VibeStickApp/App/AppModel.swift"
  section_views="$ROOT_DIR/app/macos/VibeStickApp/Features/SectionViews.swift"
  project_file="$ROOT_DIR/app/macos/VibeStick.xcodeproj/project.pbxproj"

  if [ ! -f "$flash_source" ] \
    || ! /usr/bin/grep -F 'M4DeviceFlasher.swift in Sources' "$project_file" >/dev/null \
    || ! /usr/bin/grep -F 'FirmwareTransactions.noindex' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'prewrite-nvs-v1.bin' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'prewrite_nvs_sha256' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'persistPrewriteNVSSnapshot' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'validatedPrewriteNVSSnapshotDigest' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'static let sectorSize: UInt64 = 0x1000' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'manifest.preservedRanges == [FirmwarePayloadValidator.preservedNVS]' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F '"write-flash", "--flash-size", "keep"' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F '"0x0", backupURL.path' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F '"--after", resetAfterCommand ? "watchdog-reset" : "no-reset"' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'Hash of data verified' "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F 'candidateFirmwareWriteConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'candidateFirmwareVerificationConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'deviceRestoreConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F 'deviceRestoreVerificationConfirmationPresented' "$app_model" >/dev/null \
    || ! /usr/bin/grep -F '写入 M4-4D 候选固件？' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '独立读回验证候选固件？' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '从 M4-4C 完整备份恢复设备？' "$section_views" >/dev/null \
    || ! /usr/bin/grep -F '独立验证完整恢复？' "$section_views" >/dev/null; then
    printf '%s\n' "FAIL: the M4-4D fixed-write, independent-verification, recovery, or confirmation contract is incomplete" >&2
    exit 1
  fi

  if ! /usr/bin/grep -F '"erase-flash", "erase-region", "--erase-all", "--force", "--encrypt"' \
    "$flash_source" >/dev/null \
    || ! /usr/bin/grep -F '不会自动重试、验证或恢复' "$section_views" >/dev/null \
    || /usr/bin/grep -E '"(write-flash|erase-flash|erase-region|verify-flash|write-mem|write-flash-status|load-ram)"' \
      "$backup_source" >/dev/null; then
    printf '%s\n' "FAIL: M4-4D does not preserve the no-standalone-erase, no-auto-retry, or M4-4C isolation boundary" >&2
    exit 1
  fi
  printf '%s\n' "PASS: M4-4D pins immediate prewrite NVS capture, fixed writes, separate readback, full restore, persistent recovery state, and four confirmations"
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
    -name 'FirmwareBackups.noindex' -o \
    -name 'FirmwareTransactions.noindex' -o \
    -name 'latest-v1.json' -o \
    -name 'prewrite-nvs-v1.bin' -o \
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
    -name 'esptool*.tar.gz' -o \
    -name 'FirmwareBackups.noindex' -o \
    -name 'flash-8MiB.bin' -o \
    -name 'receipt-v1.json' -o \
    -name '*Tests*' \
  \) -print)"
  if [ -n "$forbidden_files" ]; then
    printf '%s\n' "FAIL: $forbidden_label contains forbidden development or private files" >&2
    printf '%s\n' "$forbidden_files" >&2
    exit 1
  fi
}

assert_firmware_binary_scope() {
  binary_root="$1"
  binary_label="$2"
  allowed_suffix='/Contents/Resources/FirmwarePayload.noindex/'
  found_bootloader=0
  found_partitions=0
  found_app=0

  while IFS= read -r binary_path; do
    case "$binary_path" in
      *"$allowed_suffix"bootloader.bin) found_bootloader=$((found_bootloader + 1)) ;;
      *"$allowed_suffix"partition-table.bin) found_partitions=$((found_partitions + 1)) ;;
      *"$allowed_suffix"vibe-stick.bin) found_app=$((found_app + 1)) ;;
      *)
        printf '%s\n' "FAIL: $binary_label contains a firmware binary outside the verified payload" >&2
        printf '%s\n' "$binary_path" >&2
        exit 1
        ;;
    esac
  done <<EOF
$(/usr/bin/find "$binary_root" -type f -name '*.bin' -print)
EOF

  if [ "$found_bootloader" -ne 1 ] || [ "$found_partitions" -ne 1 ] || [ "$found_app" -ne 1 ]; then
    printf '%s\n' "FAIL: $binary_label does not contain exactly one copy of each verified firmware image" >&2
    exit 1
  fi
  printf '%s\n' "PASS: $binary_label firmware binaries are confined to the exact verified payload"
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
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT/VibeStick for Mac.app" ]; then
    "$LSREGISTER_PATH" -u "$MOUNT_POINT/VibeStick for Mac.app" >/dev/null 2>&1 || true
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
  /usr/bin/find "$BUILD_ROOT" -type d -name 'VibeStick*.app' -prune \
    -exec "$LSREGISTER_PATH" -u '{}' + >/dev/null 2>&1 || true
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
    "$smoke_app_binary" -ApplePersistenceIgnoreState YES \
    >"$smoke_stdout" 2>"$smoke_stderr" &
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
assert_m3b_interface_source_contract
assert_m3c_asr_source_contract
assert_m4_install_source_contract
assert_m4_flashing_tool_source_contract
assert_m4_firmware_payload_source_contract
assert_m4_device_backup_source_contract
assert_m4_device_flash_source_contract
"$ROOT_DIR/scripts/build-macos-app.sh"
assert_binary "$APP_BINARY" "VibeStick for Mac"
assert_bundle_version "$APP_PATH" "VibeStick for Mac"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
assert_app_icon "$APP_PATH" "built app"
assert_menu_bar_icon "$APP_PATH" "built app"
assert_license_bundle "$APP_PATH" "built app"

PAYLOAD_ROOT="$APP_PATH/Contents/Resources/RuntimePayload.noindex"
BRIDGE_APP="$PAYLOAD_ROOT/Components.noindex/VibeStick Bridge.app"
HUD_APP="$PAYLOAD_ROOT/Components.noindex/VibeStick HUD.app"
PASTE_APP="$PAYLOAD_ROOT/Components.noindex/VibeStick Paste.app"
assert_local_network_metadata "$APP_PATH" "$BRIDGE_APP" "built app and Bridge"

/usr/bin/xcrun swift -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT_DIR/scripts/runtime-payload-manifest.swift" verify "$PAYLOAD_ROOT"
printf '%s\n' "PASS: embedded native Swift runtime payload manifest and exact file set verified"
FIRMWARE_PAYLOAD_ROOT="$APP_PATH/Contents/Resources/FirmwarePayload.noindex"
assert_trusted_firmware_payload "$FIRMWARE_PAYLOAD_ROOT" "embedded M4-4A"
paste_source_digest="$(/usr/bin/shasum -a 256 "$ROOT_DIR/app/macos/VibeStickPaste/main.swift" | /usr/bin/awk '{print $1}')"
paste_plist_digest="$(/usr/bin/shasum -a 256 "$ROOT_DIR/app/macos/VibeStickPaste/Info.install.plist" | /usr/bin/awk '{print $1}')"
expected_paste_fingerprint="$({
  printf '%s\n' "$paste_source_digest"
  printf '%s\n' "$paste_plist_digest"
  printf '%s\n' 'swiftc-frameworks:AppKit,ApplicationServices'
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
actual_paste_fingerprint="$(/usr/bin/sed -n '1p' "$PASTE_APP/Contents/Resources/VibeStickPaste.build")"
if [ "$actual_paste_fingerprint" != "$expected_paste_fingerprint" ]; then
  printf '%s\n' "FAIL: embedded Paste identity fingerprint is not compatible with the developer installer" >&2
  exit 1
fi
printf '%s\n' "PASS: unchanged Paste builds retain the stable Accessibility identity fingerprint"

assert_binary "$BRIDGE_APP/Contents/MacOS/VibeStickBridge" "VibeStick Bridge"
assert_binary "$HUD_APP/Contents/MacOS/VibeStickHUD" "VibeStick HUD"
assert_binary "$PASTE_APP/Contents/MacOS/VibeStickPaste" "VibeStick Paste"
assert_bundle_version "$BRIDGE_APP" "VibeStick Bridge"
assert_bundle_version "$HUD_APP" "VibeStick HUD"
assert_bundle_version "$PASTE_APP" "VibeStick Paste"
verify_bundle_signature "$BRIDGE_APP" "VibeStick Bridge"
verify_bundle_signature "$HUD_APP" "VibeStick HUD"
verify_bundle_signature "$PASTE_APP" "VibeStick Paste"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme VibeStickForMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

"$LSREGISTER_PATH" -u "$TEST_DERIVED_DATA/Build/Products/Debug/VibeStick for Mac.app" >/dev/null 2>&1 || true

sign_and_verify_bundle "$TEST_BUNDLE" "VibeStick hostless tests"
assert_binary "$TEST_BUNDLE/Contents/MacOS/VibeStickForMacTests" "VibeStick hostless tests"
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest "$TEST_BUNDLE"
printf '%s\n' "PASS: Swift unit tests executed"

assert_no_forbidden_files "$APP_PATH" "built app"
assert_firmware_binary_scope "$APP_PATH" "built app"
if [ "$RUN_LAUNCH_SMOKE" = "1" ]; then
  assert_app_launch_smoke "$APP_PATH" "built app"
else
  printf '%s\n' "SKIP: built App launch smoke was not authorized"
fi

if [ -d "$APP_PATH/Contents/Helpers/VibeStick Paste.app" ]; then
  printf '%s\n' "FAIL: Paste payload must remain in the no-index transaction resources, not Contents/Helpers" >&2
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
assert_bundle_version "$MOUNTED_APP" "DMG VibeStick for Mac"
assert_local_network_metadata \
  "$MOUNTED_APP" \
  "$MOUNTED_APP/Contents/Resources/RuntimePayload.noindex/Components.noindex/VibeStick Bridge.app" \
  "DMG app and Bridge"
assert_app_icon "$MOUNTED_APP" "DMG app"
assert_menu_bar_icon "$MOUNTED_APP" "DMG app"
assert_license_bundle "$MOUNTED_APP" "DMG app"
/usr/bin/xcrun swift -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT_DIR/scripts/runtime-payload-manifest.swift" verify \
  "$MOUNTED_APP/Contents/Resources/RuntimePayload.noindex"
printf '%s\n' "PASS: DMG native Swift runtime payload manifest verified after mounting"
assert_bundle_version \
  "$MOUNTED_APP/Contents/Resources/RuntimePayload.noindex/Components.noindex/VibeStick Bridge.app" \
  "DMG VibeStick Bridge"
assert_bundle_version \
  "$MOUNTED_APP/Contents/Resources/RuntimePayload.noindex/Components.noindex/VibeStick HUD.app" \
  "DMG VibeStick HUD"
assert_bundle_version \
  "$MOUNTED_APP/Contents/Resources/RuntimePayload.noindex/Components.noindex/VibeStick Paste.app" \
  "DMG VibeStick Paste"
assert_trusted_firmware_payload \
  "$MOUNTED_APP/Contents/Resources/FirmwarePayload.noindex" \
  "DMG M4-4A"

assert_no_forbidden_files "$MOUNT_POINT" "mounted DMG"
assert_firmware_binary_scope "$MOUNT_POINT" "mounted DMG"
if [ "$RUN_LAUNCH_SMOKE" = "1" ]; then
  assert_app_launch_smoke "$MOUNTED_APP" "DMG app"
else
  printf '%s\n' "SKIP: mounted App launch smoke was not authorized"
fi

"$LSREGISTER_PATH" -u "$MOUNTED_APP" >/dev/null 2>&1 || true
detach_disk_image "$MOUNT_POINT"
mounted=0
/bin/rmdir "$MOUNT_POINT"
MOUNT_POINT=""

printf '%s\n' "PASS: app, helpers, tests, signatures, and DMG contents verified"
