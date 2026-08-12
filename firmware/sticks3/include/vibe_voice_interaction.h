#pragma once

#include <stdbool.h>
#include <stdint.h>

#define VIBE_VOICE_INTERACTION_VERSION 2
#define VIBE_VOICE_SESSION_ID_CAPACITY 40
#define VIBE_VOICE_PENDING_TTL_MS 30000
#define VIBE_VOICE_SUCCESS_HOLD_MS 1200
#define VIBE_VOICE_FAILURE_HOLD_MS 1500

typedef enum {
    VIBE_VOICE_IDLE = 0,
    VIBE_VOICE_RECORDING,
    VIBE_VOICE_TRANSCRIBING,
    VIBE_VOICE_PENDING_SEND,
    VIBE_VOICE_SENDING,
    VIBE_VOICE_PASTED,
    VIBE_VOICE_COPIED,
    VIBE_VOICE_SENT,
    VIBE_VOICE_FAILED,
    VIBE_VOICE_EXPIRED,
} vibe_voice_phase_t;

typedef enum {
    VIBE_VOICE_FAILURE_NONE = 0,
    VIBE_VOICE_FAILURE_UNCLEAR,
    VIBE_VOICE_FAILURE_TRANSCRIPTION,
    VIBE_VOICE_FAILURE_SEND,
    VIBE_VOICE_FAILURE_EXPIRED,
} vibe_voice_failure_reason_t;

typedef struct {
    vibe_voice_phase_t phase;
    char session_id[VIBE_VOICE_SESSION_ID_CAPACITY];
    int64_t expires_at_ms;
    int64_t dismiss_at_ms;
    bool bridge_supports_v2;
    vibe_voice_failure_reason_t failure_reason;
} vibe_voice_interaction_t;

void vibe_voice_interaction_init(vibe_voice_interaction_t *state);
void vibe_voice_set_bridge_version(vibe_voice_interaction_t *state, int version);
bool vibe_voice_is_enabled(const vibe_voice_interaction_t *state);
bool vibe_voice_overlay_active(const vibe_voice_interaction_t *state);
bool vibe_voice_begin_recording(vibe_voice_interaction_t *state, const char *session_id);
bool vibe_voice_begin_transcribing(vibe_voice_interaction_t *state, const char *session_id);
bool vibe_voice_apply_recording_status(vibe_voice_interaction_t *state,
                                       const char *session_id,
                                       const char *status,
                                       int64_t now_ms);
bool vibe_voice_begin_confirmation(vibe_voice_interaction_t *state, int64_t now_ms);
void vibe_voice_finish_confirmation(vibe_voice_interaction_t *state,
                                    bool success,
                                    int64_t now_ms);
void vibe_voice_fail(vibe_voice_interaction_t *state, int64_t now_ms);
bool vibe_voice_tick(vibe_voice_interaction_t *state, int64_t now_ms);
void vibe_voice_dismiss(vibe_voice_interaction_t *state);
const char *vibe_voice_phase_name(vibe_voice_phase_t phase);
