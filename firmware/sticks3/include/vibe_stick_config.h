#pragma once

#define VIBE_STICK_DEVICE_NAME "VibeStick"
#define FIRMWARE_NAME "vibestick"
#define FIRMWARE_VERSION "0.2.0-dev"
#define TRANSPORT "HTTP"
#define VIBE_STICK_STATE_PATH "/state"
#define VIBE_STICK_EVENT_PATH "/event"
#define VIBE_STICK_QUOTA_REFRESH_PATH "/quota/refresh"
#define VIBE_STICK_RECORDING_START_PATH "/recording/start"
#define VIBE_STICK_RECORDING_AUDIO_PATH "/recording/audio"
#define VIBE_STICK_RECORDING_STOP_PATH "/recording/stop"
#define VIBE_STICK_RECORDING_CONFIRM_PATH "/recording/send/confirm"
#define VIBE_STICK_HEALTH_PATH "/health"
#define VIBE_STICK_DEVICE_CONFIG_PATH "/v1/device/config"
#define VIBE_STICK_DEVICE_CONFIG_ACK_PATH "/v1/device/config/ack"
#define VIBE_STICK_STATE_POLL_MS 2000
#define VIBE_STICK_RECORDING_RESPONSE_CAPACITY 2048

#ifndef VIBE_STICK_ENABLE_M3B_VOICE
#define VIBE_STICK_ENABLE_M3B_VOICE 0
#endif

#ifndef VIBE_STICK_DISTRIBUTABLE_BUILD
#define VIBE_STICK_DISTRIBUTABLE_BUILD 0
#endif

#if VIBE_STICK_DISTRIBUTABLE_BUILD
#define VIBE_STICK_WIFI_SSID ""
#define VIBE_STICK_WIFI_PASSWORD ""
#define VIBE_STICK_BRIDGE_HOST "127.0.0.1"
#define VIBE_STICK_BRIDGE_PORT 8765
#define VIBE_STICK_BRIDGE_TOKEN ""
#elif __has_include("vibe_stick_secrets.h")
#include "vibe_stick_secrets.h"
#else
#define VIBE_STICK_WIFI_SSID ""
#define VIBE_STICK_WIFI_PASSWORD ""
#define VIBE_STICK_BRIDGE_HOST "127.0.0.1"
#define VIBE_STICK_BRIDGE_PORT 8765
#endif

#ifndef VIBE_STICK_BRIDGE_TOKEN
#define VIBE_STICK_BRIDGE_TOKEN ""
#endif
