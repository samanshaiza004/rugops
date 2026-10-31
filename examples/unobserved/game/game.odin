// Package unobserved is a headless game: all decisions and state transitions
// here are independent of the raylib host in main.odin.
package unobserved

import "core:encoding/json"
import "core:os"
import core "rugops:core"

SAVE_VERSION :: 2

Location :: enum u32 { Station, River, Ren_Workshop, Home }
Command_Kind :: enum u32 { Advance_Dialogue, Invite_Hana, Leave_Without_Invitation, Visit_Ren, Go_Home }
Event_Kind :: core.Event_ID

EVENT_HANA_DEPARTS :: Event_Kind(1)
EVENT_REN_ARRIVES :: Event_Kind(2)

Command :: struct {
	kind: Command_Kind,
}

World :: struct {
	timeline:         core.Timeline,
	location:         Location,
	dialogue_node:    u32,
	hana_invited:     bool,
	hana_waiting:     bool,
	hana_departed:    bool,
	letter_delivered: bool,
	letter_kept:      bool,
	ended:            bool,
	history:          core.Command_History,
}

Save_Data :: struct {
	version: u32,
	world:   World,
}

Choice :: struct {
	label:   string,
	command: Command_Kind,
}

Observation :: struct {
	tick:             core.Tick,
	location:         string,
	speaker:          string,
	dialogue:         string,
	choices:          [dynamic]Choice,
	ended:            bool,
	hana_departed:    bool,
	hana_waiting:     bool,
	letter_delivered: bool,
	letter_kept:      bool,
}

Submit_Error :: enum { None, Invalid_Command, No_Choices, Already_Ended }
Save_Error :: enum { None, Read_Failed, Write_Failed, Invalid_Data, Unsupported_Version }

new_world :: proc() -> World {
	w := World{location = .Station}
	assert(core.schedule(&w.timeline, 10, EVENT_HANA_DEPARTS) == .None)
	return w
}

// destroy_world releases the dynamic arrays owned by a game snapshot.
destroy_world :: proc(w: ^World) {
	delete(w.timeline.pending)
	delete(w.history.items)
	w.timeline.pending = nil
	w.history.items = nil
}

// submit applies one explicit gameplay command. It never reads wall-clock time
// or platform input. Invalid commands leave the world untouched.
submit :: proc(w: ^World, command: Command) -> Submit_Error {
	if w.ended {
		return .Already_Ended
	}

	switch command.kind {
	case .Advance_Dialogue:
		switch w.dialogue_node {
		case 0, 1: w.dialogue_node += 1
		case 4: w.dialogue_node = 5
		case 5: w.ended = true
		case: return .No_Choices
		}
	case .Invite_Hana, .Leave_Without_Invitation:
		if w.dialogue_node != 2 { return .Invalid_Command }
		w.hana_invited = command.kind == .Invite_Hana
		w.location = .River
		w.dialogue_node = 3
		advance_time(w, 12)
	case .Visit_Ren:
		if w.dialogue_node != 3 { return .Invalid_Command }
		w.location = .Ren_Workshop
		w.dialogue_node = 4
		advance_time(w, 8)
	case .Go_Home:
		if w.dialogue_node != 3 { return .Invalid_Command }
		w.location = .Home
		w.dialogue_node = 6
		w.ended = true
		advance_time(w, 4)
	case:
		return .Invalid_Command
	}

	core.record(&w.history, core.Command_Record{kind = u32(command.kind)})
	return .None
}

advance_time :: proc(w: ^World, delta: core.Tick) {
	target := w.timeline.now + delta
	for {
		event, has_event, err := core.advance_to(&w.timeline, target)
		if err != .None { return }
		if !has_event { break }
		handle_event(w, event)
	}
}

handle_event :: proc(w: ^World, event: core.Scheduled_Event) {
	switch Event_Kind(event.id) {
	case EVENT_HANA_DEPARTS:
		if w.hana_invited {
			w.hana_waiting = true
		} else {
			w.hana_departed = true
		}
		// Ren's arrival is a consequence of this event, scheduled from its
		// logical time so a large advance still processes it at tick 12.
		assert(core.schedule(&w.timeline, w.timeline.now+2, EVENT_REN_ARRIVES) == .None)
	case EVENT_REN_ARRIVES:
		if w.hana_waiting {
			w.letter_delivered = true
		} else {
			w.letter_kept = true
		}
	case:
		// Unknown event IDs are ignored. Save versions remain explicit.
	}
}

replay :: proc(commands: []core.Command_Record) -> (w: World, ok: bool) {
	w = new_world()
	for record in commands {
		if record.kind > u32(max(Command_Kind)) {
			destroy_world(&w)
			return new_world(), false
		}
		if submit(&w, Command{kind = Command_Kind(record.kind)}) != .None {
			destroy_world(&w)
			return new_world(), false
		}
	}
	return w, true
}

// same_authoritative_state compares all game-owned state, including pending
// events and command history. Allocator capacity and slice addresses are not
// part of the state contract.
same_authoritative_state :: proc(a, b: ^World) -> bool {
	if a.timeline.now != b.timeline.now || a.timeline.next_order != b.timeline.next_order ||
		a.location != b.location || a.dialogue_node != b.dialogue_node ||
		a.hana_invited != b.hana_invited || a.hana_waiting != b.hana_waiting ||
		a.hana_departed != b.hana_departed || a.letter_delivered != b.letter_delivered ||
		a.letter_kept != b.letter_kept || a.ended != b.ended ||
		len(a.timeline.pending) != len(b.timeline.pending) ||
		len(a.history.items) != len(b.history.items) {
		return false
	}
	for i in 0..<len(a.timeline.pending) {
		if a.timeline.pending[i] != b.timeline.pending[i] { return false }
	}
	for i in 0..<len(a.history.items) {
		if a.history.items[i] != b.history.items[i] { return false }
	}
	return true
}

// validate_world confirms that the snapshot matches a deterministic replay
// of its own recorded commands.
validate_world :: proc(w: ^World) -> bool {
	replayed, ok := replay(w.history.items[:])
	defer destroy_world(&replayed)
	return ok && same_authoritative_state(w, &replayed)
}

observe :: proc(w: ^World) -> Observation {
	o := Observation{
		tick = w.timeline.now,
		location = location_name(w.location),
		ended = w.ended,
		hana_departed = w.hana_departed,
		hana_waiting = w.hana_waiting,
		letter_delivered = w.letter_delivered,
		letter_kept = w.letter_kept,
	}
	switch w.dialogue_node {
	case 0:
		o.speaker = "Narrator"
		o.dialogue = "The last local train waits at the edge of town.\nHana watches the clock; Ren still carries an undelivered letter."
	case 1:
		o.speaker = "Hana"
		o.dialogue = "If Ren comes by, tell him I can wait a little longer.\nI only need to know whether he meant to send this."
	case 2:
		o.speaker = "Narrator"
		o.dialogue = "The river path is quiet. What do you do before the evening moves on?"
		append(&o.choices, Choice{"Ask Hana to wait, then walk to the river", .Invite_Hana})
		append(&o.choices, Choice{"Let the evening move on and leave", .Leave_Without_Invitation})
	case 3:
		o.speaker = "Narrator"
		if w.hana_waiting {
			o.dialogue = "Across town, Hana stays beneath the station clock.\nRen arrives at tick 12 and gives her the letter."
		} else {
			o.dialogue = "Across town, Hana has already gone.\nRen arrives at tick 12 and keeps the letter."
		}
		append(&o.choices, Choice{"Visit Ren at his workshop", .Visit_Ren})
		append(&o.choices, Choice{"Head home", .Go_Home})
	case 4:
		o.speaker = "Ren"
		if w.letter_delivered {
			o.dialogue = "I gave her the letter. She said she will answer tomorrow.\nFor once, I did not let the train decide for me."
		} else {
			o.dialogue = "I kept the letter. Hana was gone when I reached the station.\nI suppose I can still write another."
		}
	case 5:
		o.speaker = "Narrator"
		o.dialogue = "The workshop lamp stays on as the town settles into evening."
	case 6:
		o.speaker = "Narrator"
		o.dialogue = "You take the long way home. Somewhere behind you, the station clock keeps moving."
	}
	return o
}

location_name :: proc(location: Location) -> string {
	switch location {
	case .Station: return "station"
	case .River: return "river"
	case .Ren_Workshop: return "ren_workshop"
	case .Home: return "home"
	}
	return "unknown"
}

save :: proc(w: ^World, path: string) -> Save_Error {
	if !validate_world(w) { return .Invalid_Data }
	data, err := json.marshal(Save_Data{version = SAVE_VERSION, world = w^})
	if err != nil { return .Invalid_Data }
	defer delete(data)
	if os.write_entire_file(path, data) != os.ERROR_NONE { return .Write_Failed }
	return .None
}

load :: proc(path: string) -> (w: World, err: Save_Error) {
	data, os_err := os.read_entire_file(path, context.allocator)
	if os_err != os.ERROR_NONE { return new_world(), .Read_Failed }
	defer delete(data)
	parsed: Save_Data
	if json.unmarshal(data, &parsed) != nil {
		destroy_world(&parsed.world)
		return new_world(), .Invalid_Data
	}
	if parsed.version != SAVE_VERSION {
		destroy_world(&parsed.world)
		return new_world(), .Unsupported_Version
	}
	if !validate_world(&parsed.world) {
		destroy_world(&parsed.world)
		return new_world(), .Invalid_Data
	}
	return parsed.world, .None
}
