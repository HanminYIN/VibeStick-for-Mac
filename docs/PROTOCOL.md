# VibeStick Local Protocol

VibeStick uses HTTP over the local Wi-Fi network between StickS3 and the Mac Bridge. Protocol v2 adds USB-only pairing, Bonjour discovery, revisioned device configuration, and dynamic quota windows while retaining the M1 endpoints and legacy shared-token path.

Default Bridge URL:

```text
http://<mac-ip>:8765
```

The protocol is local-only. It does not use a VibeStick cloud service, UPnP, public port mapping, or remote pairing.

## Compatibility boundary

- Existing M1 firmware may continue using its compiled Bridge host and `VIBE_STICK_BRIDGE_TOKEN`.
- M2 pairing is an explicit USB action. Starting the Mac app, Bridge, or firmware does not rotate a key automatically.
- The Mac app blocks pairing unless `/health` reports protocol 2 and a valid Bridge ID.
- The Bridge accepts either a valid device-specific pairing token or the legacy shared token on existing runtime endpoints.
- M2 configuration contains no Wi-Fi password, ASR key, Bridge token, or pairing token.

## Identity and authentication

Each M2 firmware request sends:

```text
X-Vibe-Stick-Firmware-Name: vibestick
X-Vibe-Stick-Firmware-Version: 0.2.0-dev
X-Vibe-Stick-Firmware-Transport: HTTP
X-Vibe-Stick-Firmware-Build-Date: <compile date>
X-Vibe-Stick-Device-ID: vs-<wifi-mac>
X-Vibe-Stick-Token: <device-specific-token>
```

Audio uploads also send:

```text
X-Vibe-Stick-Sample-Rate: 16000
X-Vibe-Stick-Channels: 1
X-Vibe-Stick-Bits-Per-Sample: 16
```

The random plaintext device token is written to StickS3 NVS through USB and stored in the Mac Keychain. The Bridge registry stores only a random salt and this digest:

```text
SHA-256("vibestick-pairing-v1\0" || salt || UTF-8(token))
```

The Bridge compares digests in constant time. Pairing or re-pairing is never exposed as a LAN endpoint.

## USB pairing transport

The Mac uses the ESP32-S3 USB Serial/JTAG device at 115200 baud. Commands are newline-delimited ASCII; structured payloads are JSON.

Identify:

```text
VIBESTICK IDENTIFY
```

```text
VIBESTICK_RESPONSE {"command":"identify","ok":true,"identity":{"device_id":"vs-001122334455","model":"M5Stack StickS3","firmware_version":"0.2.0-dev","protocol_version":2}}
```

Pair, where `<payload>` is standard Base64-encoded JSON:

```text
VIBESTICK PAIR <payload>
```

```json
{
  "schema_version": 1,
  "pairing_id": "90d71007-7734-44f7-8987-b2980437e6c6",
  "bridge_id": "90d71007-7734-44f7-8987-b2980437e6c6",
  "device_id": "vs-001122334455",
  "token": "<random-device-token>",
  "bridge_port": 8765,
  "fallback_host": "192.168.1.25"
}
```

The device validates its own ID, token length and alphabet, transaction UUID, Bridge UUID, host, and port before committing the pairing record to NVS. Repeating the same transaction is idempotent. If the final USB acknowledgement is lost, the Mac retries the identical command and can then use the non-secret `pairing_id` in the identify response to reconcile an already committed rotation. Logs and responses never contain the token.

## Bonjour discovery

The Bridge advertises `_vibestick._tcp` with these TXT records:

```text
bridge_id=<uuid>
protocol=2
auth=paired
```

Paired firmware selects only the service whose `bridge_id` exactly matches its USB pairing record. It resolves the current IPv4 address and port, and falls back to the validated manual host if mDNS is unavailable. A failed request invalidates the discovered address so resolution can be retried.

## GET /health

This endpoint is intentionally non-secret and supports readiness and discovery diagnostics:

```json
{
  "ok": true,
  "bridge_name": "vibestick-bridge",
  "bridge_version": "0.2.0-dev",
  "protocol_version": 2,
  "bridge_id": "90d71007-7734-44f7-8987-b2980437e6c6"
}
```

## GET /state

Loopback clients may read state without a token. LAN clients must present a valid paired-device identity/token or the configured legacy token.

```json
{
  "time": "13:01",
  "wifi": true,
  "ble": false,
  "battery": null,
  "active_provider": "codex",
  "provider": {
    "id": "codex",
    "display_name": "Codex",
    "implemented": true,
    "status": "RUNNING",
    "project": "vibestick",
    "quota_windows": [
      {
        "id": "7d",
        "label": "7D",
        "remaining_percent": 96,
        "updated_at": "13:01",
        "stale": false
      }
    ],
    "quota_5h_remaining": null,
    "quota_7d_remaining": 96,
    "quota_updated_at": "13:01",
    "quota_stale": false
  },
  "codex": {
    "status": "RUNNING",
    "project": "vibestick",
    "quota_windows": [],
    "quota_5h_remaining": null,
    "quota_7d_remaining": null,
    "quota_updated_at": "",
    "quota_stale": false
  },
  "alert": {"event_id": "", "type": "NONE", "message": ""},
  "bridge_name": "vibestick-bridge",
  "bridge_version": "0.2.0-dev"
}
```

`battery` remains `null` because StickS3 renders its local PMIC reading. Firmware prefers the first two `quota_windows` entries when present and falls back to the legacy 5H/7D fields.

## Configuration synchronization

The Mac owns `device-config-v1.json`; the Bridge validates it again before serving it. Codex and connection status are mandatory modules. Claude is optional and off by default.

### GET /v1/device/config

Requires paired-device authentication.

```json
{
  "schema_version": 1,
  "revision": 4,
  "modules": ["codex", "connection"],
  "default_page": "codex",
  "project": {"visible": true, "name": "M5StickS3"},
  "buttons": {
    "front_double": "refresh_quota",
    "side_single": "next_page"
  }
}
```

Firmware accepts only a strictly newer non-negative revision, validates the allow-listed fields, stores it in NVS, applies it without reflashing, and ignores an equal or older revision.

### POST /v1/device/config/ack

Requires paired-device authentication.

```json
{"revision":4}
```

```json
{"accepted":true,"current_revision":4}
```

The Bridge records the acknowledged revision and recent device presence in memory for the Mac control center.

### GET /v1/devices

Loopback-only management endpoint. It reports paired/revoked state, firmware version, last-seen state, and target versus acknowledged configuration revisions. Tokens and token hashes are never returned.

## Existing runtime endpoints

The following M1 paths remain stable:

- `POST /event`
- `POST /quota/refresh`
- `POST /recording/start`
- `POST /recording/audio?session_id=<id>`
- `POST /recording/stop`

They accept paired-device authentication or the legacy shared token. Loopback-only development remains allowed when the Bridge binds to loopback. Binding to a non-loopback address is refused unless at least one valid paired-device record or a non-placeholder legacy token exists.

The recording sequence and raw signed 16-bit, 16 kHz, mono PCM contract are unchanged. The default maximum upload is 2,000,000 bytes and remains bounded by `VIBE_STICK_MAX_RECORDING_AUDIO_BYTES`.
