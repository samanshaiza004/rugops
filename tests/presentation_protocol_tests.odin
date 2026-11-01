package tests

import "core:testing"
import core "rugops:core"
import presentation "rugops:presentation"

test_stage :: proc(background: string) -> presentation.Stage_State {
	return presentation.Stage_State{
		background = presentation.Asset_ID(background),
	}
}

test_transition_request :: proc(id: u64, duration_ms: u64) -> presentation.Transition_Request {
	return presentation.Transition_Request{
		id       = presentation.Transition_ID(id),
		style    = .Crossfade,
		duration = presentation.Presentation_Milliseconds(duration_ms),
	}
}

@(test)
transition_progress_is_deterministic_and_host_timed :: proc(t: ^testing.T) {
	first := presentation.Presentation_State{stage = test_stage("background.before")}
	second := first
	target := test_stage("background.after")
	request := test_transition_request(1, 1000)
	testing.expect_value(t, presentation.request_transition(&first, request, target), presentation.Transition_Error.None)
	testing.expect_value(t, presentation.request_transition(&second, request, target), presentation.Transition_Error.None)
	testing.expect_value(t, first.transition.status, presentation.Transition_Status.Running)
	testing.expect_value(t, first.stage.background, presentation.Asset_ID("background.before"))

	deltas := [3]u64{125, 375, 500}
	for delta in deltas {
		presentation_delta := presentation.Presentation_Milliseconds(delta)
		testing.expect_value(t, presentation.advance_transition(&first, presentation_delta), presentation.Transition_Error.None)
		testing.expect_value(t, presentation.advance_transition(&second, presentation_delta), presentation.Transition_Error.None)
		testing.expect_value(t, first.transition.elapsed, second.transition.elapsed)
		testing.expect_value(t, first.transition.status, second.transition.status)
	}
	testing.expect_value(t, first.transition.status, presentation.Transition_Status.Completed)
	testing.expect_value(t, first.transition.elapsed, presentation.Presentation_Milliseconds(1000))
	testing.expect_value(t, first.stage.background, presentation.Asset_ID("background.after"))
	testing.expect_value(t, presentation.transition_progress(first.transition), f32(1))
}

@(test)
zero_duration_transition_completes_immediately_and_cuts_are_explicit :: proc(t: ^testing.T) {
	state := presentation.Presentation_State{stage = test_stage("old")}
	testing.expect_value(t, presentation.transition_progress(state.transition), f32(0))
	testing.expect_value(t, presentation.advance_transition(&state, presentation.Presentation_Milliseconds(1)), presentation.Transition_Error.Not_Running)
	cut := presentation.Transition_Request{
		id       = presentation.Transition_ID(5),
		style    = .Cut,
		duration = presentation.Presentation_Milliseconds(0),
	}
	testing.expect_value(t, presentation.request_transition(&state, cut, test_stage("new")), presentation.Transition_Error.None)
	testing.expect_value(t, state.transition.status, presentation.Transition_Status.Completed)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("new"))
	wrongly_timed_cut := cut
	wrongly_timed_cut.id = presentation.Transition_ID(6)
	wrongly_timed_cut.duration = presentation.Presentation_Milliseconds(10)
	testing.expect_value(t, presentation.request_transition(&state, wrongly_timed_cut, test_stage("never")), presentation.Transition_Error.Timed_Cut)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("new"))
}

@(test)
cancellation_records_explicit_source_or_target_settlement :: proc(t: ^testing.T) {
	state := presentation.Presentation_State{stage = test_stage("source")}
	testing.expect_value(t, presentation.request_transition(&state, test_transition_request(10, 1000), test_stage("target")), presentation.Transition_Error.None)
	testing.expect_value(t, presentation.advance_transition(&state, presentation.Presentation_Milliseconds(250)), presentation.Transition_Error.None)
	testing.expect_value(t, presentation.cancel_transition(&state, .Keep_Source), presentation.Transition_Error.None)
	testing.expect_value(t, state.transition.status, presentation.Transition_Status.Cancelled)
	testing.expect_value(t, state.transition.settlement, presentation.Transition_Settlement.Keep_Source)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("source"))
	testing.expect_value(t, presentation.transition_progress(state.transition), f32(0))
	testing.expect_value(t, presentation.cancel_transition(&state, .Settle_Target), presentation.Transition_Error.Not_Running)

	testing.expect_value(t, presentation.request_transition(&state, test_transition_request(11, 1000), test_stage("next")), presentation.Transition_Error.None)
	testing.expect_value(t, presentation.cancel_transition(&state, .Settle_Target), presentation.Transition_Error.None)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("next"))
	testing.expect_value(t, state.transition.status, presentation.Transition_Status.Cancelled)
	testing.expect_value(t, presentation.transition_progress(state.transition), f32(1))
}

@(test)
no_op_presenter_uses_same_stage_and_consumes_one_shot_cues_once :: proc(t: ^testing.T) {
	state := presentation.Presentation_State{stage = test_stage("cafe")}
	_ = presentation.set_character(&state.stage, presentation.Character_State{
		id         = presentation.Character_ID("masha"),
		portrait   = presentation.Asset_ID("portrait.masha.smile"),
		expression = presentation.Asset_ID("smile"),
		slot       = .Left,
		opacity    = 255,
		visible    = true,
	})

	noop: presentation.Noop_Presenter
	presentation.noop_present_stage(&noop, &state.stage)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("cafe"))
	testing.expect_value(t, state.stage.character_count, 1)
	testing.expect_value(t, presentation.request_transition(&state, test_transition_request(20, 400), test_stage("archive")), presentation.Transition_Error.None)
	// The host supplies this elapsed duration. The no-op presenter does not
	// need graphics to run the exact same protocol state to completion.
	testing.expect_value(t, presentation.advance_transition(&state, presentation.Presentation_Milliseconds(400)), presentation.Transition_Error.None)
	testing.expect_value(t, state.transition.status, presentation.Transition_Status.Completed)
	testing.expect_value(t, state.stage.background, presentation.Asset_ID("archive"))

	queue: presentation.Impulse_Queue
	defer presentation.destroy_impulse_queue(&queue)
	cue := presentation.Presentation_Impulse{
		id      = presentation.Impulse_ID(77),
		payload = presentation.Play_Sound_Impulse{
			asset        = presentation.Asset_ID("sfx.page_turn"),
			gain_percent = 65,
		},
	}
	testing.expect_value(t, presentation.queue_impulse(&queue, cue), presentation.Impulse_Error.None)
	testing.expect_value(t, presentation.queue_impulse(&queue, cue), presentation.Impulse_Error.Duplicate_ID)
	testing.expect_value(t, presentation.noop_deliver_impulses(&noop, &queue), 1)
	testing.expect_value(t, len(queue.items), 0)
	testing.expect_value(t, presentation.noop_deliver_impulses(&noop, &queue), 0)
}

@(test)
presentation_time_is_separate_from_authoritative_timeline_and_commands :: proc(t: ^testing.T) {
	timeline := core.Timeline{now = 123}
	defer delete(timeline.pending)
	history: core.Command_History
	defer delete(history.items)

	state := presentation.Presentation_State{stage = test_stage("before")}
	_ = presentation.request_transition(&state, test_transition_request(30, 9000), test_stage("after"))
	for _ in 0..<9 {
		_ = presentation.advance_transition(&state, presentation.Presentation_Milliseconds(1000))
	}
	testing.expect_value(t, state.transition.status, presentation.Transition_Status.Completed)
	testing.expect_value(t, timeline.now, core.Tick(123))
	testing.expect_value(t, len(history.items), 0)
}
