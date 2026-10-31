package tests

import "core:os"
import "core:testing"
import core "rugops:core"
import game "rugops:examples/unobserved/game"

@(test)
stable_scheduled_event_order :: proc(t: ^testing.T) {
	timeline: core.Timeline
	defer delete(timeline.pending)
	core.schedule(&timeline, 12, 30)
	core.schedule(&timeline, 10, 20)
	core.schedule(&timeline, 12, 31)
	due := core.advance(&timeline, 12)
	defer delete(due)
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
	testing.expect_value(t, replayed.timeline.now, w.timeline.now)
	testing.expect_value(t, replayed.location, w.location)
	testing.expect_value(t, replayed.hana_waiting, w.hana_waiting)
	testing.expect_value(t, replayed.letter_delivered, w.letter_delivered)
	testing.expect_value(t, replayed.letter_kept, w.letter_kept)
	testing.expect_value(t, replayed.dialogue_node, w.dialogue_node)
	testing.expect_value(t, len(replayed.history.items), len(w.history.items))
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
