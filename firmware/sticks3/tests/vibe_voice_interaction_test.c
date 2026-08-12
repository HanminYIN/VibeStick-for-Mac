#include "vibe_voice_interaction.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static const char *SESSION_A = "0123456789abcdef0123456789abcdef";
static const char *SESSION_B = "11111111111111111111111111111111";

static vibe_voice_interaction_t enabled_state(void)
{
    vibe_voice_interaction_t state;
    vibe_voice_interaction_init(&state);
    vibe_voice_set_bridge_version(&state, 2);
    return state;
}

static void test_capability_gate(void)
{
    vibe_voice_interaction_t state;
    vibe_voice_interaction_init(&state);
    assert(!vibe_voice_is_enabled(&state));
    assert(!vibe_voice_begin_recording(&state, SESSION_A));
    assert(state.phase == VIBE_VOICE_IDLE);

    vibe_voice_set_bridge_version(&state, 2);
    assert(vibe_voice_begin_recording(&state, SESSION_A));
    vibe_voice_set_bridge_version(&state, 1);
    assert(state.phase == VIBE_VOICE_IDLE);
    assert(state.session_id[0] == '\0');
}

static void test_confirm_is_consumed_once(void)
{
    vibe_voice_interaction_t state = enabled_state();
    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "pending_send", 1000));
    assert(state.phase == VIBE_VOICE_PENDING_SEND);
    assert(state.expires_at_ms == 31000);
    assert(vibe_voice_begin_confirmation(&state, 2000));
    assert(state.phase == VIBE_VOICE_SENDING);
    assert(!vibe_voice_begin_confirmation(&state, 2001));
    assert(!vibe_voice_begin_recording(&state, SESSION_B));
    vibe_voice_finish_confirmation(&state, true, 2100);
    assert(state.phase == VIBE_VOICE_SENT);
    assert(!vibe_voice_begin_confirmation(&state, 2101));
    assert(!vibe_voice_tick(&state, 3299));
    assert(vibe_voice_tick(&state, 3300));
    assert(state.phase == VIBE_VOICE_IDLE);
}

static void test_pending_expiration_is_fail_closed(void)
{
    vibe_voice_interaction_t state = enabled_state();
    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "pending_send", 1000));
    assert(!vibe_voice_tick(&state, 30999));
    assert(vibe_voice_tick(&state, 31000));
    assert(state.phase == VIBE_VOICE_EXPIRED);
    assert(state.failure_reason == VIBE_VOICE_FAILURE_EXPIRED);
    assert(!vibe_voice_begin_confirmation(&state, 31000));
    assert(vibe_voice_tick(&state, 32500));
    assert(state.phase == VIBE_VOICE_IDLE);
}

static void test_new_recording_invalidates_pending(void)
{
    vibe_voice_interaction_t state = enabled_state();
    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "pending_send", 1000));
    assert(vibe_voice_begin_recording(&state, SESSION_B));
    assert(state.phase == VIBE_VOICE_RECORDING);
    assert(strcmp(state.session_id, SESSION_B) == 0);
}

static void test_mismatched_and_terminal_results(void)
{
    vibe_voice_interaction_t state = enabled_state();
    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(!vibe_voice_apply_recording_status(&state, SESSION_B, "sent", 1000));
    assert(state.phase == VIBE_VOICE_TRANSCRIBING);
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "pasted", 1000));
    assert(state.phase == VIBE_VOICE_PASTED);
    assert(!vibe_voice_tick(&state, 2199));
    assert(vibe_voice_tick(&state, 2200));
    assert(state.phase == VIBE_VOICE_IDLE);

    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "copied", 1800));
    assert(state.phase == VIBE_VOICE_COPIED);
    assert(!vibe_voice_tick(&state, 2999));
    assert(vibe_voice_tick(&state, 3000));
    assert(state.phase == VIBE_VOICE_IDLE);

    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "send_failed", 2000));
    assert(state.phase == VIBE_VOICE_FAILED);
    assert(state.failure_reason == VIBE_VOICE_FAILURE_SEND);
    assert(!vibe_voice_tick(&state, 3499));
    assert(vibe_voice_tick(&state, 3500));
    assert(state.phase == VIBE_VOICE_IDLE);

    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "audio_skipped", 4000));
    assert(state.phase == VIBE_VOICE_FAILED);
    assert(state.failure_reason == VIBE_VOICE_FAILURE_UNCLEAR);
    assert(vibe_voice_tick(&state, 5500));

    assert(vibe_voice_begin_recording(&state, SESSION_A));
    assert(vibe_voice_begin_transcribing(&state, SESSION_A));
    assert(vibe_voice_apply_recording_status(&state, SESSION_A, "transcription_failed", 6000));
    assert(state.phase == VIBE_VOICE_FAILED);
    assert(state.failure_reason == VIBE_VOICE_FAILURE_TRANSCRIPTION);
}

int main(void)
{
    test_capability_gate();
    test_confirm_is_consumed_once();
    test_pending_expiration_is_fail_closed();
    test_new_recording_invalidates_pending();
    test_mismatched_and_terminal_results();
    puts("vibe_voice_interaction_test: ok");
    return 0;
}
