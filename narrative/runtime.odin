// Package narrative provides a renderer-independent narrative compiler and
// deterministic interpreter. Game-specific conditions, actions, and world
// consequences are supplied by the consuming game.
package narrative

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
	Stale_Choice,
	Ineligible_Choice,
	Query_Evaluation_Failed,
	Action_Rejected,
	Action_Contract_Violation,
	Missing_Outcome_Route,
	Control_Flow_Limit,
}

Choice_Submission :: struct {
	error:        Runtime_Error,
	query_error:  Query_Error,
	action_error: Action_Error,
	choice_index: int,
	outcome:      Action_Outcome,
}

new_state :: proc(program: ^Program) -> State {
	if program == nil || len(program.scenes) == 0 { return State{ended = true} }
	return State{cursor = scene_entry(program, program.entry_scene)}
}

choice_id :: proc(program: ^Program, index: int) -> (id: Choice_ID, ok: bool) {
	if program == nil || index < 0 || index >= len(program.choices) { return {}, false }
	return Choice_ID{program_hash = program.identity.identity_hash, index = u32(index)}, true
}

// advance resolves branches, jumps, and stable anchors until it reaches a
// dialogue, narration, choice group, or end instruction. A resolver failure
// is returned explicitly and is never treated as a false predicate.
advance :: proc(
	program: ^Program,
	state: ^State,
	user_data: rawptr,
	resolve_field: Field_Resolver,
	handle_event: Runtime_Event_Handler,
) -> (runtime_error: Runtime_Error, query_error: Query_Error) {
	if program == nil || state == nil { return .Invalid_State, .None }
	if state.ended { return .None, .None }
	limit := max(32, len(program.nodes)*4+8)
	for _ in 0..<limit {
		if state.cursor.scene < 0 || state.cursor.scene >= len(program.scenes) {
			state.ended = true
			return .None, .None
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
			return .None, .None
		}
		switch node.kind {
		case .Dialogue, .Narration, .Choice_Group:
			return .None, .None
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
			query := evaluate_condition(program, node.condition_index, user_data, resolve_field)
			if query.error != .None { return .Query_Evaluation_Failed, query.error }
			if query.value.boolean {
				state.cursor.pc = node.branch_true
			} else {
				state.cursor.pc = node.branch_false
			}
		case .Jump:
			if node.target_scene < 0 || node.target_scene >= len(program.scenes) || node.target_pc < 0 {
				state.ended = true
				return .Invalid_State, .None
			}
			state.cursor = Cursor{
				scene = node.target_scene,
				scene_id = program.scenes[node.target_scene].id,
				pc = node.target_pc,
				anchor_id = state.cursor.anchor_id,
			}
		case .End:
			state.ended = true
			return .None, .None
		}
	}
	return .Control_Flow_Limit, .None
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

// visible_choice maps a visible option ordinal to its current compiled choice
// index. Use choice_id to retain identity between observation and submission.
visible_choice :: proc(
	program: ^Program,
	state: ^State,
	visible_index: int,
	user_data: rawptr,
	resolve_field: Field_Resolver,
) -> (choice_index: int, ok: bool, query_error: Query_Error) {
	if program == nil || state == nil || visible_index < 0 { return -1, false, .None }
	node, valid := node_at(program, state.cursor)
	if !valid || node.kind != .Choice_Group { return -1, false, .None }
	visible := 0
	for i in node.choice_start..<node.choice_start+node.choice_count {
		choice := program.choices[i]
		eligible := true
		if choice.condition_index >= 0 {
			query := evaluate_condition(program, choice.condition_index, user_data, resolve_field)
			if query.error != .None { return -1, false, query.error }
			eligible = query.value.boolean
		}
		if eligible == choice.condition_not { continue }
		if visible == visible_index { return i, true, .None }
		visible += 1
	}
	return -1, false, .None
}

choice_target :: proc(program: ^Program, choice_index: int) -> (cursor: Cursor, ok: bool) {
	return choice_target_for_outcome(program, choice_index, .Accepted)
}

choice_target_for_outcome :: proc(program: ^Program, choice_index: int, outcome: Action_Outcome) -> (cursor: Cursor, ok: bool) {
	if program == nil || choice_index < 0 || choice_index >= len(program.choices) { return {}, false }
	choice := program.choices[choice_index]
	target_scene, target_pc := choice.target_scene, choice.target_pc
	if outcome != .Accepted {
		found := false
		for route in program.outcome_routes[choice.outcome_start:choice.outcome_start+choice.outcome_count] {
			if route.outcome == outcome {
				target_scene, target_pc = route.target_scene, route.target_pc
				found = true
				break
			}
		}
		if !found { return {}, false }
	}
	if target_scene < 0 || target_scene >= len(program.scenes) || target_pc < 0 { return {}, false }
	return Cursor{
		scene = target_scene,
		scene_id = program.scenes[target_scene].id,
		pc = target_pc,
		anchor_id = choice.anchor_id,
	}, true
}

// submit_choice re-resolves a stable offer against the current state, validates
// all declared continuations before invoking the game action, and changes the
// narrative cursor only after the game reports a valid action outcome. The
// game resolver must leave game state unchanged when it returns an error.
submit_choice :: proc(
	program: ^Program,
	state: ^State,
	offered_id: Choice_ID,
	user_data: rawptr,
	resolve_field: Field_Resolver,
	resolve_action: Action_Resolver,
) -> Choice_Submission {
	result := Choice_Submission{choice_index = -1}
	if program == nil || state == nil || state.ended {
		result.error = .Invalid_State
		return result
	}
	if offered_id.program_hash != program.identity.identity_hash || offered_id.index >= u32(len(program.choices)) {
		result.error = .Stale_Choice
		return result
	}
	node, valid := node_at(program, state.cursor)
	if !valid || node.kind != .Choice_Group {
		result.error = .Not_Choice_Group
		return result
	}
	index := int(offered_id.index)
	if index < node.choice_start || index >= node.choice_start+node.choice_count {
		result.error = .Stale_Choice
		return result
	}
	choice := &program.choices[index]
	if choice.condition_index >= 0 {
		query := evaluate_condition(program, choice.condition_index, user_data, resolve_field)
		if query.error != .None {
			result.error = .Query_Evaluation_Failed
			result.query_error = query.error
			return result
		}
		if query.value.boolean == choice.condition_not {
			result.error = .Ineligible_Choice
			return result
		}
	}
	for outcome in ACTION_OUTCOMES {
		if choice.action_outcomes&(u8(1)<<u8(outcome)) == 0 { continue }
		if _, found := choice_target_for_outcome(program, index, outcome); !found {
			result.error = .Missing_Outcome_Route
			return result
		}
	}
	if resolve_action == nil {
		result.error = .Action_Rejected
		result.action_error = .Invalid_Command
		return result
	}
	action_result := resolve_action(user_data, choice)
	if action_result.error != .None {
		result.error = .Action_Rejected
		result.action_error = action_result.error
		return result
	}
	if choice.action_outcomes&(u8(1)<<u8(action_result.outcome)) == 0 {
		result.error = .Action_Contract_Violation
		return result
	}
	target, found := choice_target_for_outcome(program, index, action_result.outcome)
	assert(found, "validated action outcome must have a narrative continuation")
	state.cursor = target
	result.choice_index = index
	result.outcome = action_result.outcome
	return result
}
