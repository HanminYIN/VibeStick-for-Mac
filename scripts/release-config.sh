#!/usr/bin/env sh

load_release_configuration() {
  vibestick_release_root="$1"
  vibestick_release_config_path="${VIBESTICK_RELEASE_CONFIG:-$vibestick_release_root/release/release-config-v1.json}"
  vibestick_release_python="${VIBESTICK_PYTHON:-$(command -v python3)}"
  vibestick_release_assignments="$($vibestick_release_python \
    "$vibestick_release_root/scripts/release_configuration.py" \
    shell \
    "$vibestick_release_config_path")" || return 1
  eval "$vibestick_release_assignments"
  vibestick_release_payload="${VIBESTICK_TRUSTED_FIRMWARE_PAYLOAD:-$vibestick_release_root/$VIBESTICK_FIRMWARE_PAYLOAD_PATH}"
  "$vibestick_release_python" \
    "$vibestick_release_root/scripts/release_configuration.py" \
    validate-inputs \
    "$VIBESTICK_RELEASE_CONFIG_PATH" \
    "$vibestick_release_root" \
    "$vibestick_release_payload" || return 1
  "$vibestick_release_python" \
    "$vibestick_release_root/scripts/firmware-payload-manifest.py" \
    verify \
    "$vibestick_release_root/$VIBESTICK_FIRMWARE_PAYLOAD_PATH" || return 1
  if [ "$vibestick_release_payload" != "$vibestick_release_root/$VIBESTICK_FIRMWARE_PAYLOAD_PATH" ]; then
    "$vibestick_release_python" \
      "$vibestick_release_root/scripts/firmware-payload-manifest.py" \
      verify \
      "$vibestick_release_payload" || return 1
  fi
  unset vibestick_release_assignments vibestick_release_config_path \
    vibestick_release_payload vibestick_release_python
}
