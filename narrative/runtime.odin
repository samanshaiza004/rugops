// Package narrative provides a renderer-independent narrative compiler and
// deterministic interpreter. Game-specific conditions, actions, and world
// consequences are supplied by the consuming game.
package narrative

Condition_Query :: #type proc(user_data: rawptr, condition: string) -> bool

Runtime_Event_Kind :: enum u8 {
	Scene_Entered,
	Anchor_Reached,
}

Runtime_Event :: struct {
	kind:               Runtime_Event_Kind,
	scene_id:           string,
	previous_scene_id:  string,
	location:           string,
	anchor_id:          string,
	checkpoint:         bool,
}

Runtime_Event_Handler :: #type proc(user_data: rawptr, event: Runtime_Event)

State :: struct {
	cursor:           Cursor,
	entered_scene_id: string,
	ended:            bool,
}

Runtime_Error :: enum u8 {
	None,
	Invalid_State,
	Not_Dialogue,
	Not_Choice_Group,
	Invalid_Choice,
	Control_Flow_Limit,
}

new_state :: proc(program: ^Program) -> State {
	if program == nil || len(program.scenes) == 0 { return State{ended = true} }
	return State{cursor = scene_entry(program, program.entry_scene)}
}

// advance resolves branches, jumps, and stable anchors until a dialogue,
// narration, choice group, or end instruction is reached. It never changes
// game-owned state; queries and trace events are delegated to the caller.
advance :: proc(
	program: ^Program,
	state: ^State,
	user_data: rawptr,
	query: Condition_Query,
	handle_event: Runtime_Event_Handler,
) -> Runtime_Error {
	if program == nil || state == nil { return .Invalid_State }
	if state.ended { return .None }
	limit := max(32, len(program.nodes)*4+8)
	for _ in 0..<limit {
		if state.cursor.scene < 0 || state.cursor.scene >= len(program.scenes) {
			state.ended = true
			return .None
		}
		scene := program.scenes[state.cursor.scene]
		if state.entered_scene_id != scene.id {
			previous := state.entered_scene_id
			state.entered_scene_id = scene.id
			if handle_event != nil {
				handle_event(user_data, Runtime_Event{
					kind = .Scene_Entered,
					scene_id = scene.id,
					previous_scene_id = previous,
					location = scene.location,
				})
			}
		}
		node, ok := node_at(program, state.cursor)
		if !ok {
			state.ended = true
			return .None
		}
		switch node.kind {
		case .Dialogue, .Narration, .Choice_Group:
			return .None
		case .Anchor:
			state.cursor.anchor_id = node.anchor_id
			if handle_event != nil {
				handle_event(user_data, Runtime_Event{
					kind = .Anchor_Reached,
					scene_id = scene.id,
					anchor_id = node.anchor_id,
					checkpoint = node.checkpoint,
				})
			}
			state.cursor.pc += 1
		case .Branch:
			if query != nil && query(user_data, node.condition) {
				state.cursor.pc = node.branch_true
			} else {
				state.cursor.pc = node.branch_false
			}
		case .Jump:
			if node.target_scene < 0 || node.target_scene >= len(program.scenes) || node.target_pc < 0 {
				state.ended = true
				return .Invalid_State
			}
			state.cursor = Cursor{
				scene = node.target_scene,
				scene_id = program.scenes[node.target_scene].id,
				pc = node.target_pc,
				anchor_id = state.cursor.anchor_id,
			}
		case .End:
			state.ended = true
			return .None
		}
	}
	return .Control_Flow_Limit
}

// continue_dialogue advances past the current line or narration. Call advance
// afterward to resolve control flow and produce the next presentable node.
continue_dialogue :: proc(program: ^Program, state: ^State) -> Runtime_Error {
	if program == nil || state == nil || state.ended { return .Invalid_State }
	node, ok := node_at(program, state.cursor)
	if !ok { return .Invalid_State }
	if node.kind != .Dialogue && node.kind != .Narration { return .Not_Dialogue }
	state.cursor.pc += 1
	return .None
}

// visible_choice returns an index in Program.choices for the requested
// player-visible option, evaluating only the choice's pure condition.
visible_choice :: proc(
	program: ^Program,
	state: ^State,
	visible_index: int,
	user_data: rawptr,
	query: Condition_Query,
) -> (choice_index: int, ok: bool) {
	if program == nil || state == nil || visible_index < 0 { return -1, false }
	node, valid := node_at(program, state.cursor)
	if !valid || node.kind != .Choice_Group { return -1, false }
	visible := 0
	for i in node.choice_start..<node.choice_start+node.choice_count {
		choice := program.choices[i]
		condition := true
		if choice.condition != "" {
			condition = query != nil && query(user_data, choice.condition)
		}
		if condition == choice.condition_not { continue }
		if visible == visible_index { return i, true }
		visible += 1
	}
	return -1, false
}

choice_target :: proc(program: ^Program, choice_index: int) -> (cursor: Cursor, ok: bool) {
	if program == nil || choice_index < 0 || choice_index >= len(program.choices) { return {}, false }
	choice := program.choices[choice_index]
	if choice.target_scene < 0 || choice.target_scene >= len(program.scenes) || choice.target_pc < 0 { return {}, false }
	return Cursor{
		scene = choice.target_scene,
		scene_id = program.scenes[choice.target_scene].id,
		pc = choice.target_pc,
		anchor_id = choice.anchor_id,
	}, true
}

// commit_choice moves the narrative cursor after the game has accepted the
// selected action. The game remains responsible for validating and applying
// that action before calling this procedure.
commit_choice :: proc(program: ^Program, state: ^State, choice_index: int) -> Runtime_Error {
	if program == nil || state == nil || state.ended { return .Invalid_State }
	node, valid := node_at(program, state.cursor)
	if !valid || node.kind != .Choice_Group { return .Not_Choice_Group }
	if choice_index < node.choice_start || choice_index >= node.choice_start+node.choice_count { return .Invalid_Choice }
	target, found := choice_target(program, choice_index)
	if !found { return .Invalid_Choice }
	state.cursor = target
	return .None
}
