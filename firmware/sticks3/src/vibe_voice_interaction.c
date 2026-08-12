#include "vibe_voice_interaction.h"

#include <stddef.h>
#include <string.h>

static void reset_session(vibe_voice_interaction_t *state)
{
    state->phase = VIBE_VOICE_IDLE;
    state->session_id[0] = '\0';
    state->expires_at_ms = 0;
    state->dismiss_at_ms = 0;
    state->failure_reason = VIBE_VOICE_FAILURE_NONE;
}

static bool valid_session_id(const char *session_id)
{
    if (!session_id) {
        return false;
    }
    size_t length = strlen(session_id);
    if (length < 8 || length >= VIBE_VOICE_SESSION_ID_CAPACITY) {
        return false;
    }
    for (size_t index = 0; index < length; ++index) {
        const char value = session_id[index];
        const bool valid = (value >= 'a' && value <= 'z') ||
                           (value >= 'A' && value <= 'Z') ||
                           (value >= '0' && value <= '9') ||
                           value == '-' || value == '_';
        if (!valid) {
            return false;
        }
    }
    return true;
}

static bool session_matches(const vibe_voice_interaction_t *state, const char *session_id)
{
    return state && valid_session_id(session_id) &&
           strcmp(state->session_id, session_id) == 0;
}

static void set_terminal(vibe_voice_interaction_t *state,
                         vibe_voice_phase_t phase,
                         int64_t now_ms,
                         int64_t hold_ms)
{
    state->phase = phase;
    state->expires_at_ms = 0;
    state->dismiss_at_ms = now_ms + hold_ms;
}

static vibe_voice_failure_reason_t failure_reason_for_status(const char *status)
{
    if (strcmp(status, "audio_skipped") == 0 ||
        strcmp(status, "transcript_rejected") == 0) {
        return VIBE_VOICE_FAILURE_UNCLEAR;
    }
    if (strcmp(status, "transcription_failed") == 0 ||
        strcmp(status, "audio_failed") == 0 ||
        strcmp(status, "start_failed") == 0 ||
        strcmp(status, "stop_failed") == 0) {
        return VIBE_VOICE_FAILURE_TRANSCRIPTION;
    }
    return VIBE_VOICE_FAILURE_SEND;
}

void vibe_voice_interaction_init(vibe_voice_interaction_t *state)
{
    if (!state) {
        return;
    }
    memset(state, 0, sizeof(*state));
    state->phase = VIBE_VOICE_IDLE;
}

void vibe_voice_set_bridge_version(vibe_voice_interaction_t *state, int version)
{
    if (!state) {
        return;
    }
    state->bridge_supports_v2 = version >= VIBE_VOICE_INTERACTION_VERSION;
    if (!state->bridge_supports_v2 && state->phase != VIBE_VOICE_IDLE) {
        reset_session(state);
    }
}

bool vibe_voice_is_enabled(const vibe_voice_interaction_t *state)
{
    return state && state->bridge_supports_v2;
}

bool vibe_voice_overlay_active(const vibe_voice_interaction_t *state)
{
    return state && state->phase != VIBE_VOICE_IDLE;
}

bool vibe_voice_begin_recording(vibe_voice_interaction_t *state, const char *session_id)
{
    if (!vibe_voice_is_enabled(state) || !valid_session_id(session_id)) {
        return false;
    }
    if (state->phase == VIBE_VOICE_RECORDING ||
        state->phase == VIBE_VOICE_TRANSCRIBING ||
        state->phase == VIBE_VOICE_SENDING) {
        return false;
    }
    size_t length = strlen(session_id);
    memcpy(state->session_id, session_id, length + 1);
    state->phase = VIBE_VOICE_RECORDING;
    state->expires_at_ms = 0;
    state->dismiss_at_ms = 0;
    state->failure_reason = VIBE_VOICE_FAILURE_NONE;
    return true;
}

bool vibe_voice_begin_transcribing(vibe_voice_interaction_t *state, const char *session_id)
{
    if (!session_matches(state, session_id) || state->phase != VIBE_VOICE_RECORDING) {
        return false;
    }
    state->phase = VIBE_VOICE_TRANSCRIBING;
    return true;
}

bool vibe_voice_apply_recording_status(vibe_voice_interaction_t *state,
                                       const char *session_id,
                                       const char *status,
                                       int64_t now_ms)
{
    if (!session_matches(state, session_id) ||
        state->phase != VIBE_VOICE_TRANSCRIBING || !status) {
        return false;
    }
    if (strcmp(status, "pending_send") == 0) {
        state->phase = VIBE_VOICE_PENDING_SEND;
        state->expires_at_ms = now_ms + VIBE_VOICE_PENDING_TTL_MS;
        state->dismiss_at_ms = 0;
        state->failure_reason = VIBE_VOICE_FAILURE_NONE;
    } else if (strcmp(status, "sent") == 0) {
        state->failure_reason = VIBE_VOICE_FAILURE_NONE;
        set_terminal(state, VIBE_VOICE_SENT, now_ms, VIBE_VOICE_SUCCESS_HOLD_MS);
    } else if (strcmp(status, "copied") == 0) {
        state->failure_reason = VIBE_VOICE_FAILURE_NONE;
        set_terminal(state, VIBE_VOICE_COPIED, now_ms, VIBE_VOICE_SUCCESS_HOLD_MS);
    } else if (strcmp(status, "pasted") == 0 || strcmp(status, "transcribed") == 0) {
        state->failure_reason = VIBE_VOICE_FAILURE_NONE;
        set_terminal(state, VIBE_VOICE_PASTED, now_ms, VIBE_VOICE_SUCCESS_HOLD_MS);
    } else {
        state->failure_reason = failure_reason_for_status(status);
        set_terminal(state, VIBE_VOICE_FAILED, now_ms, VIBE_VOICE_FAILURE_HOLD_MS);
    }
    return true;
}

bool vibe_voice_begin_confirmation(vibe_voice_interaction_t *state, int64_t now_ms)
{
    if (!state) {
        return false;
    }
    (void)vibe_voice_tick(state, now_ms);
    if (state->phase != VIBE_VOICE_PENDING_SEND) {
        return false;
    }
    state->phase = VIBE_VOICE_SENDING;
    state->expires_at_ms = 0;
    return true;
}

void vibe_voice_finish_confirmation(vibe_voice_interaction_t *state,
                                    bool success,
                                    int64_t now_ms)
{
    if (!state || state->phase != VIBE_VOICE_SENDING) {
        return;
    }
    set_terminal(
        state,
        success ? VIBE_VOICE_SENT : VIBE_VOICE_FAILED,
        now_ms,
        success ? VIBE_VOICE_SUCCESS_HOLD_MS : VIBE_VOICE_FAILURE_HOLD_MS
    );
    state->failure_reason = success ? VIBE_VOICE_FAILURE_NONE : VIBE_VOICE_FAILURE_SEND;
}

void vibe_voice_fail(vibe_voice_interaction_t *state, int64_t now_ms)
{
    if (!state || state->phase == VIBE_VOICE_IDLE) {
        return;
    }
    if (state->failure_reason == VIBE_VOICE_FAILURE_NONE) {
        state->failure_reason = VIBE_VOICE_FAILURE_SEND;
    }
    set_terminal(state, VIBE_VOICE_FAILED, now_ms, VIBE_VOICE_FAILURE_HOLD_MS);
}

bool vibe_voice_tick(vibe_voice_interaction_t *state, int64_t now_ms)
{
    if (!state) {
        return false;
    }
    if (state->phase == VIBE_VOICE_PENDING_SEND &&
        state->expires_at_ms > 0 && now_ms >= state->expires_at_ms) {
        state->failure_reason = VIBE_VOICE_FAILURE_EXPIRED;
        set_terminal(state, VIBE_VOICE_EXPIRED, now_ms, VIBE_VOICE_FAILURE_HOLD_MS);
        return true;
    }
    if ((state->phase == VIBE_VOICE_PASTED ||
         state->phase == VIBE_VOICE_COPIED ||
         state->phase == VIBE_VOICE_SENT ||
         state->phase == VIBE_VOICE_FAILED ||
         state->phase == VIBE_VOICE_EXPIRED) &&
        state->dismiss_at_ms > 0 && now_ms >= state->dismiss_at_ms) {
        reset_session(state);
        return true;
    }
    return false;
}

void vibe_voice_dismiss(vibe_voice_interaction_t *state)
{
    if (!state || state->phase == VIBE_VOICE_RECORDING ||
        state->phase == VIBE_VOICE_TRANSCRIBING ||
        state->phase == VIBE_VOICE_PENDING_SEND ||
        state->phase == VIBE_VOICE_SENDING) {
        return;
    }
    reset_session(state);
}

const char *vibe_voice_phase_name(vibe_voice_phase_t phase)
{
    switch (phase) {
    case VIBE_VOICE_IDLE: return "idle";
    case VIBE_VOICE_RECORDING: return "recording";
    case VIBE_VOICE_TRANSCRIBING: return "transcribing";
    case VIBE_VOICE_PENDING_SEND: return "pending_send";
    case VIBE_VOICE_SENDING: return "sending";
    case VIBE_VOICE_PASTED: return "pasted";
    case VIBE_VOICE_COPIED: return "copied";
    case VIBE_VOICE_SENT: return "sent";
    case VIBE_VOICE_FAILED: return "failed";
    case VIBE_VOICE_EXPIRED: return "expired";
    }
    return "unknown";
}
