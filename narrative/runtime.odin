// Package narrative provides a renderer-independent narrative compiler and
// deterministic interpreter. Game-specific conditions, actions, and world
// consequences are supplied by the consuming game.
package narrative

Runtime_Event_Kind :: enum u8 {
	Scene_Entered,
	Anchor_Reached,
	Contextual_Beat_Selected,
}

Runtime_Event :: struct {
	kind:               Runtime_Event_Kind,
	scene_id:           string,
	previous_scene_id:  string,
	location:           string,
	anchor_id:          string,
	pool_id:            string,
	beat_id:            string,
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

choice_declares_outcome :: proc(choice: ^Choice, outcome: Action_Outcome) -> bool {
	if choice == nil || outcome <= .Invalid || outcome > .Deferred { return false }
	return choice.action_outcomes&(u8(1)<<u8(outcome)) != 0
}

// advance resolves branches, jumps, contextual selections, and stable anchors
// until it reaches a dialogue, narration, choice group, or end instruction.
// A resolver failure is returned explicitly and is never treated as false.
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
		case .Contextual_Select:
			selection := select_contextual_beat(program, node.contextual_pool_index, user_data, resolve_field)
			if selection.error == .Query_Evaluation_Failed {
				return .Query_Evaluation_Failed, selection.query_error
			}
			if selection.error != .None { return .Invalid_State, .None }
			pool := program.contextual_pools[node.contextual_pool_index]
			beat := program.contextual_beats[selection.beat_index]
			if handle_event != nil {
				handle_event(user_data, Runtime_Event{
					kind = .Contextual_Beat_Selected,
					scene_id = scene.id,
					pool_id = pool.id,
					beat_id = beat.id,
				})
			}
			target := selection.target
			target.anchor_id = state.cursor.anchor_id
			state.cursor = target
		case .End:
			state.ended = true
			return .None, .None
		}
	}
	return .Control_Flow_Limit, .None
}

select_contextual_beat :: proc(
	program: ^Program,
	pool_index: int,
	user_data: rawptr,
	resolve_field: Field_Resolver,
) -> Contextual_Selection {
	result := Contextual_Selection{beat_index = -1}
	if program == nil || pool_index < 0 || pool_index >= len(program.contextual_pools) {
		result.error = .Unknown_Pool
		return result
	}
	pool := program.contextual_pools[pool_index]
	selected := -1
	for i in pool.beat_start..<pool.beat_start+pool.beat_count {
		beat := program.contextual_beats[i]
		if beat.fallback { continue }
		query := evaluate_condition(program, beat.condition_index, user_data, resolve_field)
		if query.error != .None {
			result.error = .Query_Evaluation_Failed
			result.query_error = query.error
			return result
		}
		if !query.value.boolean { continue }
		if selected < 0 || contextual_beat_precedes(beat, program.contextual_beats[selected], pool.policy) {
			selected = i
		}
	}
	if selected < 0 { selected = pool.fallback_beat }
	if selected < pool.beat_start || selected >= pool.beat_start+pool.beat_count {
		result.error = .Missing_Fallback
		return result
	}
	beat := program.contextual_beats[selected]
	if beat.target_scene < 0 || beat.target_scene >= len(program.scenes) || beat.target_pc < 0 {
		result.error = .Invalid_Target
		return result
	}
	result.beat_index = selected
	result.target = Cursor{
		scene = beat.target_scene,
		scene_id = program.scenes[beat.target_scene].id,
		pc = beat.target_pc,
	}
	return result
}

explain_contextual_selection :: proc(
	program: ^Program,
	pool_id: string,
	user_data: rawptr,
	resolve_field: Field_Resolver,
) -> (explanation: Contextual_Selection_Explanation) {
	if program == nil {
		explanation.error = .Unknown_Pool
		return
	}
	pool_index := -1
	for i in 0..<len(program.contextual_pools) {
		if program.contextual_pools[i].id == pool_id { pool_index = i; break }
	}
	if pool_index < 0 {
		explanation.error = .Unknown_Pool
		return
	}
	pool := program.contextual_pools[pool_index]
	explanation.pool_id = pool.id
	selected := -1
	for i in pool.beat_start..<pool.beat_start+pool.beat_count {
		beat := program.contextual_beats[i]
		entry := Contextual_Beat_Explanation{
			beat_id = beat.id,
			condition = beat.condition,
			priority = beat.priority,
			fallback = beat.fallback,
		}
		if beat.fallback {
			entry.eligible = true
		} else {
			entry.query = explain_query(program, beat.condition_index, user_data, resolve_field)
			entry.eligible = entry.query.error == .None && entry.query.value
			if entry.query.error != .None {
				explanation.error = .Query_Evaluation_Failed
			}
		}
		append(&explanation.beats, entry)
		if explanation.error != .None { return }
		if !entry.fallback && entry.eligible && (selected < 0 || contextual_beat_precedes(beat, program.contextual_beats[selected], pool.policy)) {
			selected = i
		}
	}
	if explanation.error != .None { return }
	if selected < 0 { selected = pool.fallback_beat }
	if selected < pool.beat_start || selected >= pool.beat_start+pool.beat_count {
		explanation.error = .Missing_Fallback
		return
	}
	beat := program.contextual_beats[selected]
	explanation.selected_beat_id = beat.id
	for i in 0..<len(explanation.beats) {
		if pool.beat_start+i == selected { explanation.beats[i].selected = true }
	}
	return
}

destroy_contextual_selection_explanation :: proc(explanation: ^Contextual_Selection_Explanation) {
	for beat in explanation.beats { delete(beat.query.steps) }
	delete(explanation.beats)
	explanation^ = {}
}

contextual_beat_precedes :: proc(candidate, current: Contextual_Beat, policy: Selection_Policy) -> bool {
	switch policy {
	case .Priority:
		if candidate.priority != current.priority { return candidate.priority > current.priority }
		return candidate.id < current.id
	}
	return candidate.id < current.id
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
	if !choice_declares_outcome(choice, action_result.outcome) {
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
