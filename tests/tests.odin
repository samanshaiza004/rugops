package tests

import "core:os"
import "core:testing"
import "core:encoding/json"
import core "rugops:core"
import game "rugops:examples/unobserved/game"

Event_Trace :: struct {
	ids:   [dynamic]core.Event_ID,
	ticks: [dynamic]core.Tick,
	final: core.Tick,
}

run_nested_event_trace :: proc(deltas: []core.Tick) -> Event_Trace {
	timeline: core.Timeline
	core.schedule(&timeline, 10, 1)
	trace: Event_Trace
	for delta in deltas {
		target := timeline.now + delta
		for {
			event, has_event, err := core.advance_to(&timeline, target)
			if err != .None || !has_event { break }
			append(&trace.ids, event.id)
			append(&trace.ticks, timeline.now)
			if event.id == 1 {
				assert(core.schedule(&timeline, timeline.now+2, 2) == .None)
			}
		}
	}
	trace.final = timeline.now
	delete(timeline.pending)
	return trace
}

@(test)
large_time_step_processes_nested_events_at_their_own_ticks :: proc(t: ^testing.T) {
	coarse_deltas := [1]core.Tick{20}
	fine_deltas: [20]core.Tick
	for i in 0..<len(fine_deltas) { fine_deltas[i] = 1 }
	coarse := run_nested_event_trace(coarse_deltas[:])
	defer delete(coarse.ids)
	defer delete(coarse.ticks)
	fine := run_nested_event_trace(fine_deltas[:])
	defer delete(fine.ids)
	defer delete(fine.ticks)
	testing.expect_value(t, coarse.final, fine.final)
	testing.expect_value(t, len(coarse.ids), len(fine.ids))
	for i in 0..<len(coarse.ids) {
		testing.expect_value(t, coarse.ids[i], fine.ids[i])
		testing.expect_value(t, coarse.ticks[i], fine.ticks[i])
	}
}

@(test)
scheduling_before_current_tick_is_rejected :: proc(t: ^testing.T) {
	timeline := core.Timeline{now = 5}
	err := core.schedule(&timeline, 4, 1)
	testing.expect_value(t, err, core.Timeline_Error.Tick_In_Past)
	_, has_event, advance_err := core.advance_to(&timeline, 4)
	testing.expect_value(t, advance_err, core.Timeline_Error.Target_In_Past)
	testing.expect_value(t, has_event, false)
	testing.expect_value(t, timeline.now, core.Tick(5))
	testing.expect_value(t, len(timeline.pending), 0)
}

@(test)
load_rejects_structurally_invalid_world :: proc(t: ^testing.T) {
	path := "tests/.invalid-save-test.json"
	defer os.remove(path)
	invalid := game.new_world()
	defer game.destroy_world(&invalid)
	invalid.dialogue_node = 99
	testing.expect_value(t, game.save(&invalid, path), game.Save_Error.Invalid_Data)
	data, marshal_err := json.marshal(game.Save_Data{version = game.SAVE_VERSION, world = invalid})
	testing.expect_value(t, marshal_err == nil, true)
	defer delete(data)
	testing.expect_value(t, os.write_entire_file(path, data), os.ERROR_NONE)
	loaded, err := game.load(path)
	defer game.destroy_world(&loaded)
	testing.expect_value(t, err, game.Save_Error.Invalid_Data)
}

@(test)
load_rejects_older_save_version :: proc(t: ^testing.T) {
	path := "tests/.old-save-test.json"
	defer os.remove(path)
	old_world := game.new_world()
	defer game.destroy_world(&old_world)
	data, marshal_err := json.marshal(game.Save_Data{version = 1, world = old_world})
	testing.expect_value(t, marshal_err == nil, true)
	defer delete(data)
	testing.expect_value(t, os.write_entire_file(path, data), os.ERROR_NONE)
	loaded, err := game.load(path)
	defer game.destroy_world(&loaded)
	testing.expect_value(t, err, game.Save_Error.Unsupported_Version)
}

@(test)
stable_scheduled_event_order :: proc(t: ^testing.T) {
	timeline: core.Timeline
	defer delete(timeline.pending)
	testing.expect_value(t, core.schedule(&timeline, 12, 30), core.Timeline_Error.None)
	testing.expect_value(t, core.schedule(&timeline, 10, 20), core.Timeline_Error.None)
	testing.expect_value(t, core.schedule(&timeline, 12, 31), core.Timeline_Error.None)
	due: [dynamic]core.Scheduled_Event
	defer delete(due)
	for {
		event, has_event, err := core.advance_to(&timeline, 12)
		testing.expect_value(t, err, core.Timeline_Error.None)
		if !has_event { break }
		append(&due, event)
	}
	testing.expect_value(t, len(due), 3)
	testing.expect_value(t, due[0].id, core.Event_ID(20))
	testing.expect_value(t, due[1].id, core.Event_ID(30))
	testing.expect_value(t, due[2].id, core.Event_ID(31))
	testing.expect_value(t, len(timeline.pending), 0)
}

@(test)
dialogue_reading_does_not_advance_time :: proc(t: ^testing.T) {
	w := game.new_world()
	defer game.destroy_world(&w)
	testing.expect_value(t, game.submit(&w, game.Command{.Advance_Dialogue}), game.Submit_Error.None)
	testing.expect_value(t, game.submit(&w, game.Command{.Advance_Dialogue}), game.Submit_Error.None)
	testing.expect_value(t, w.timeline.now, core.Tick(0))
	o := game.observe(&w)
	defer delete(o.choices)
	testing.expect_value(t, len(o.choices), 2)
	testing.expect_value(t, o.location, "station")
}

@(test)
offscreen_events_change_later_dialogue :: proc(t: ^testing.T) {
	w := game.new_world()
	defer game.destroy_world(&w)
	_ = game.submit(&w, game.Command{.Advance_Dialogue})
	_ = game.submit(&w, game.Command{.Advance_Dialogue})
	_ = game.submit(&w, game.Command{.Leave_Without_Invitation})
	testing.expect_value(t, w.timeline.now, core.Tick(12))
	testing.expect_value(t, w.location, game.Location.River)
	testing.expect_value(t, w.hana_departed, true)
	testing.expect_value(t, w.letter_kept, true)
	_ = game.submit(&w, game.Command{.Visit_Ren})
	testing.expect_value(t, w.timeline.now, core.Tick(20))
	o := game.observe(&w)
	defer delete(o.choices)
	testing.expect_value(t, o.location, "ren_workshop")
	testing.expect_value(t, o.letter_kept, true)
	testing.expect_value(t, o.letter_delivered, false)
	testing.expect_value(t, o.speaker, "Ren")
}

@(test)
same_commands_replay_to_same_state :: proc(t: ^testing.T) {
	w := game.new_world()
	defer game.destroy_world(&w)
	commands := [4]game.Command{
		{.Advance_Dialogue}, {.Advance_Dialogue}, {.Invite_Hana}, {.Visit_Ren},
	}
	for command in commands { testing.expect_value(t, game.submit(&w, command), game.Submit_Error.None) }
	replayed, ok := game.replay(w.history.items[:])
	defer game.destroy_world(&replayed)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, game.same_authoritative_state(&replayed, &w), true)
	testing.expect_value(t, replayed.timeline.now, w.timeline.now)
	testing.expect_value(t, replayed.location, w.location)
	testing.expect_value(t, replayed.hana_waiting, w.hana_waiting)
	testing.expect_value(t, replayed.letter_delivered, w.letter_delivered)
	testing.expect_value(t, replayed.letter_kept, w.letter_kept)
	testing.expect_value(t, replayed.dialogue_node, w.dialogue_node)
	testing.expect_value(t, len(replayed.history.items), len(w.history.items))
}

@(test)
authoritative_state_comparison_includes_pending_events :: proc(t: ^testing.T) {
	a := game.new_world()
	defer game.destroy_world(&a)
	b := game.new_world()
	defer game.destroy_world(&b)
	o_a := game.observe(&a)
	defer delete(o_a.choices)
	o_b := game.observe(&b)
	defer delete(o_b.choices)
	testing.expect_value(t, o_a.dialogue, o_b.dialogue)
	b.timeline.pending[0].tick += 1
	testing.expect_value(t, game.same_authoritative_state(&a, &b), false)
}

@(test)
versioned_save_restores_pending_events_and_state :: proc(t: ^testing.T) {
	path := "tests/.save-test.json"
	defer os.remove(path)
	w := game.new_world()
	defer game.destroy_world(&w)
	_ = game.submit(&w, game.Command{.Advance_Dialogue})
	_ = game.submit(&w, game.Command{.Advance_Dialogue})
	testing.expect_value(t, game.save(&w, path), game.Save_Error.None)
	loaded, err := game.load(path)
	defer game.destroy_world(&loaded)
	testing.expect_value(t, err, game.Save_Error.None)
	testing.expect_value(t, loaded.timeline.now, w.timeline.now)
	testing.expect_value(t, len(loaded.timeline.pending), len(w.timeline.pending))
	testing.expect_value(t, len(loaded.history.items), len(w.history.items))
	_ = game.submit(&w, game.Command{.Invite_Hana})
	_ = game.submit(&loaded, game.Command{.Invite_Hana})
	testing.expect_value(t, loaded.timeline.now, w.timeline.now)
	testing.expect_value(t, loaded.letter_delivered, w.letter_delivered)
	testing.expect_value(t, loaded.hana_waiting, w.hana_waiting)
}

@(test)
invalid_command_does_not_change_world :: proc(t: ^testing.T) {
	w := game.new_world()
	defer game.destroy_world(&w)
	err := game.submit(&w, game.Command{.Visit_Ren})
	testing.expect_value(t, err, game.Submit_Error.Invalid_Command)
	testing.expect_value(t, w.timeline.now, core.Tick(0))
	testing.expect_value(t, len(w.history.items), 0)
}
