package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import game "rugops:examples/unobserved/game"

Character_State :: struct {
	hana_departed: bool,
	hana_waiting:  bool,
	ren_letter:    string,
}

Inspection :: struct {
	tick:               u64,
	current_location:   string,
	active_speaker:     string,
	active_dialogue:    string,
	available_choices:  [dynamic]string,
	character_state:    Character_State,
	command_history:    int,
	ended:              bool,
}

inspect :: proc(w: ^game.World) -> Inspection {
	o := game.observe(w)
	result := Inspection{
		tick = o.tick,
		current_location = o.location,
		active_speaker = o.speaker,
		active_dialogue = o.dialogue,
		command_history = len(w.history.items),
		ended = o.ended,
		character_state = {
			hana_departed = o.hana_departed,
			hana_waiting = o.hana_waiting,
			ren_letter = o.letter_delivered ? "delivered" : o.letter_kept ? "kept" : "unresolved",
		},
	}
	for choice in o.choices { append(&result.available_choices, choice.label) }
	delete(o.choices)
	return result
}

print_json :: proc(value: any) {
	data, err := json.marshal(value)
	if err != nil {
		fmt.eprintln("could not encode JSON inspection")
		os.exit(1)
	}
	defer delete(data)
	fmt.println(string(data))
}

run_scenario :: proc(invite: bool) -> (w: game.World, ok: bool) {
	w = game.new_world()
	sequence := [4]game.Command{
		{kind = .Advance_Dialogue},
		{kind = .Advance_Dialogue},
		{kind = invite ? .Invite_Hana : .Leave_Without_Invitation},
		{kind = .Visit_Ren},
	}
	for command in sequence {
		if game.submit(&w, command) != .None { return w, false }
	}
	return w, true
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: rugops scenario [invite|leave] [save.json] | inspect [save.json] | replay [invite|leave]")
		os.exit(2)
	}
	command := string(os.args[1])
	switch command {
	case "scenario":
		invite := len(os.args) < 3 || string(os.args[2]) != "leave"
		w, ok := run_scenario(invite)
		if !ok { os.exit(1) }
		if len(os.args) >= 4 && game.save(&w, string(os.args[3])) != .None {
			fmt.eprintln("could not save scenario state")
			os.exit(1)
		}
		print_json(inspect(&w))
	case "inspect":
		w := game.new_world()
		if len(os.args) >= 3 {
			loaded, err := game.load(string(os.args[2]))
			if err != .None {
				fmt.eprintfln("could not load save (%v)", err)
				os.exit(1)
			}
			w = loaded
		}
		print_json(inspect(&w))
	case "replay":
		invite := len(os.args) < 3 || string(os.args[2]) != "leave"
		original, ok := run_scenario(invite)
		if !ok { os.exit(1) }
		replayed, replay_ok := game.replay(original.history.items[:])
		if !replay_ok || !game.same_authoritative_state(&original, &replayed) {
			fmt.eprintln("replay did not reproduce the same authoritative state")
			os.exit(1)
		}
		print_json(inspect(&replayed))
	case:
		fmt.eprintln("unknown command: ", command)
		os.exit(2)
	}
}
