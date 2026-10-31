package narrative

import "core:strings"

ACTION_OUTCOMES :: [4]Action_Outcome{.Accepted, .Refused, .Interrupted, .Deferred}

action_outcome_mask :: proc(action: Action_Definition) -> u8 {
	mask := u8(1) << u8(Action_Outcome.Accepted)
	if action.can_refuse { mask |= u8(1) << u8(Action_Outcome.Refused) }
	if action.can_interrupt { mask |= u8(1) << u8(Action_Outcome.Interrupted) }
	if action.can_defer { mask |= u8(1) << u8(Action_Outcome.Deferred) }
	return mask
}

compile :: proc(source: string, registry: Registry, metadata: Program_Metadata = {}) -> Compilation {
	result := Compilation{}
	result.program.source = make([]u8, len(source))
	copy(result.program.source, transmute([]u8)source)
	owned_source := string(result.program.source)
	program_id := metadata.id
	if program_id == "" { program_id = "anonymous" }
	program_version := metadata.version
	if program_version == 0 { program_version = 1 }
	result.program.identity_id_storage = make([]u8, len(program_id))
	copy(result.program.identity_id_storage, transmute([]u8)program_id)
	source_digest := source_hash(owned_source)
	result.program.identity = Program_Identity{
		id = string(result.program.identity_id_storage),
		version = program_version,
		source_hash = source_digest,
		identity_hash = identity_hash(program_id, program_version, source_digest),
	}
	validate_registry(&result, registry)
	copy_query_schema(&result, registry)
	lines, _ := strings.split_lines(owned_source, context.temp_allocator)
	current_scene := -1
	choice_node := -1
	current_choice := -1
	choice_condition := ""
	choice_condition_index := -1
	choice_condition_not := false
	selection_pool_index := -1
	branch_stack: [dynamic]int
	branch_else_jumps: [dynamic]int
	for raw_line, line_index in lines {
		line_no := line_index+1
		indent := indentation(raw_line)
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "//") { continue }
		if strings.has_prefix(line, ":: ") {
			if selection_pool_index >= 0 {
				diagnose(&result, .Invalid_Selection, line_no, 1, "@select must end with @endselect")
				selection_pool_index = -1
			}
			id := strings.trim_space(line[3:])
			if !valid_id(id) {
				diagnose(&result, .Invalid_ID, line_no, 4, id)
				continue
			}
			if scene_index(&result.program, id) >= 0 {
				diagnose(&result, .Duplicate_Scene, line_no, 4, id)
				continue
			}
			if current_scene >= 0 {
				result.program.scenes[current_scene].end = len(result.program.nodes)
			}
			append(&result.program.scenes, Scene{id = id, start = len(result.program.nodes)})
			current_scene = len(result.program.scenes)-1
			choice_node, current_choice = -1, -1
			choice_condition = ""
			choice_condition_index = -1
			choice_condition_not = false
			continue
		}
		if current_scene < 0 {
			diagnose(&result, .Syntax, line_no, 1, "expected a :: scene declaration")
			continue
		}
		if selection_pool_index >= 0 && !strings.has_prefix(line, "@beat ") && !strings.has_prefix(line, "@fallback ") && line != "@endselect" {
			diagnose(&result, .Invalid_Selection, line_no, indent+1, "@select accepts only @beat, @fallback, and @endselect")
			continue
		}
		if strings.has_prefix(line, "@select ") {
			if selection_pool_index >= 0 || choice_node >= 0 {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "@select cannot be nested or placed inside a choice group")
				continue
			}
			pool_id, policy, valid_header := parse_selection_header(line[8:])
			if !valid_header {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "expected @select pool_id priority")
				continue
			}
			duplicate := false
			for pool in result.program.contextual_pools { if pool.id == pool_id { duplicate = true; break } }
			if duplicate {
				diagnose(&result, .Duplicate_Selection_Pool, line_no, indent+1, pool_id)
				continue
			}
			pool_index := len(result.program.contextual_pools)
			append(&result.program.contextual_pools, Contextual_Pool{
				id = pool_id,
				policy = policy,
				beat_start = len(result.program.contextual_beats),
				fallback_beat = -1,
				line = line_no,
			})
			append(&result.program.nodes, Node{kind = .Contextual_Select, contextual_pool_index = pool_index, line = line_no})
			selection_pool_index = pool_index
			continue
		}
		if strings.has_prefix(line, "@endselect") {
			if selection_pool_index < 0 || line != "@endselect" {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "@endselect without a matching @select")
			} else {
				pool := &result.program.contextual_pools[selection_pool_index]
				if pool.fallback_beat < 0 {
					diagnose(&result, .Missing_Selection_Fallback, line_no, indent+1, pool.id)
				}
				selection_pool_index = -1
			}
			continue
		}
		if strings.has_prefix(line, "@beat ") {
			if selection_pool_index < 0 {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "@beat must be inside @select")
				continue
			}
			beat, valid_beat := parse_contextual_beat(line[6:], line_no)
			if !valid_beat {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "expected @beat id priority N if condition -> target")
				continue
			}
			pool := &result.program.contextual_pools[selection_pool_index]
			duplicate := false
			for existing in result.program.contextual_beats[pool.beat_start:] {
				if existing.id == beat.id { duplicate = true; break }
			}
			if duplicate {
				diagnose(&result, .Duplicate_Selection_Beat, line_no, indent+1, beat.id)
				continue
			}
			beat.condition_index, _ = compile_query(&result, registry, beat.condition, line_no, indent+1)
			append(&result.program.contextual_beats, beat)
			pool.beat_count += 1
			continue
		}
		if strings.has_prefix(line, "@fallback ") {
			if selection_pool_index < 0 {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "@fallback must be inside @select")
				continue
			}
			beat, valid_fallback := parse_contextual_fallback(line[10:], line_no)
			if !valid_fallback {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "expected @fallback id -> target")
				continue
			}
			pool := &result.program.contextual_pools[selection_pool_index]
			duplicate := false
			for existing in result.program.contextual_beats[pool.beat_start:] {
				if existing.id == beat.id { duplicate = true; break }
			}
			if duplicate {
				diagnose(&result, .Duplicate_Selection_Beat, line_no, indent+1, beat.id)
				continue
			}
			if pool.fallback_beat >= 0 {
				diagnose(&result, .Invalid_Selection, line_no, indent+1, "a selection can have only one @fallback")
				continue
			}
			pool.fallback_beat = len(result.program.contextual_beats)
			append(&result.program.contextual_beats, beat)
			pool.beat_count += 1
			continue
		}
		if strings.has_prefix(line, "@scene ") {
			result.program.scenes[current_scene].title = quoted_value(line[7:])
			continue
		}
		if strings.has_prefix(line, "@location ") {
			result.program.scenes[current_scene].location = strings.trim_space(line[10:])
			continue
		}
		if strings.has_prefix(line, "? ") {
			node := Node{kind = .Choice_Group, text = strings.trim_space(line[2:]), choice_start = len(result.program.choices), line = line_no}
			append(&result.program.nodes, node)
			choice_node = len(result.program.nodes)-1
			current_choice = -1
			choice_condition = ""
			choice_condition_index = -1
			choice_condition_not = false
			continue
		}
		if strings.has_prefix(line, "- ") {
			if choice_node < 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "choice option without a ? prompt")
				continue
			}
			choice := Choice{
				label = strings.trim_space(line[2:]),
				condition = choice_condition,
				condition_index = choice_condition_index,
				condition_not = choice_condition_not,
				target_scene = -1,
				target_pc = -1,
				line = line_no,
				outcome_start = len(result.program.outcome_routes),
			}
			append(&result.program.choices, choice)
			current_choice = len(result.program.choices)-1
			result.program.nodes[choice_node].choice_count += 1
			continue
		}
		if strings.has_prefix(line, "@if ") {
			condition := strings.trim_space(line[4:])
			condition_index, _ := compile_query(&result, registry, condition, line_no, indent+5)
			if choice_node >= 0 && indent > 0 {
				choice_condition = condition
				choice_condition_index = condition_index
				choice_condition_not = false
				continue
			}
			branch := Node{kind = .Branch, condition = condition, condition_index = condition_index, branch_true = len(result.program.nodes)+1, branch_false = -1, line = line_no}
			append(&result.program.nodes, branch)
			append(&branch_stack, len(result.program.nodes)-1)
			append(&branch_else_jumps, -1)
			continue
		}
		if line == "@else" {
			if choice_node >= 0 && indent > 0 {
				choice_condition_not = true
				continue
			}
			if len(branch_stack) == 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "@else without @if")
			} else {
				stack_index := len(branch_stack)-1
				branch_index := branch_stack[stack_index]
				branch := &result.program.nodes[branch_index]
				if branch_else_jumps[stack_index] >= 0 {
					diagnose(&result, .Syntax, line_no, indent+1, "duplicate @else")
				} else {
					jump_index := len(result.program.nodes)
					branch.branch_false = jump_index+1
					branch_else_jumps[stack_index] = jump_index
					append(&result.program.nodes, Node{kind = .Jump, target_scene = current_scene, target_pc = -1, line = line_no})
				}
			}
			continue
		}
		if line == "@endif" {
			if choice_node >= 0 && indent > 0 {
				choice_condition = ""
				choice_condition_index = -1
				choice_condition_not = false
				continue
			}
			if len(branch_stack) == 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "@endif without @if")
			} else {
				stack_index := len(branch_stack)-1
				index := branch_stack[stack_index]
				branch := &result.program.nodes[index]
				jump_index := branch_else_jumps[stack_index]
				if jump_index < 0 {
					branch.branch_false = len(result.program.nodes)
				} else {
					result.program.nodes[jump_index].target_pc = len(result.program.nodes)
				}
				_ = pop(&branch_stack)
				_ = pop(&branch_else_jumps)
			}
			continue
		}
		if strings.has_prefix(line, "@anchor ") {
			anchor, ok := parse_anchor(line[8:])
			if !ok || !valid_id(anchor.id) {
				diagnose(&result, .Syntax, line_no, indent+1, "expected @anchor id \"title\" kind [checkpoint] [hidden]")
				continue
			}
			if anchor_index(&result.program, anchor.id) >= 0 {
				diagnose(&result, .Duplicate_Anchor, line_no, indent+1, anchor.id)
				continue
			}
			anchor.scene_id = result.program.scenes[current_scene].id
			if current_choice >= 0 && choice_node >= 0 {
				choice := &result.program.choices[current_choice]
				choice.anchor_id = anchor.id
				append(&result.program.anchors, Anchor{
					id = anchor.id, title = anchor.title, scene_id = anchor.scene_id, kind = anchor.kind,
					checkpoint = anchor.checkpoint, hidden = anchor.hidden, choice = true,
					scene = current_scene, pc = choice_node,
				})
			} else {
				node := Node{kind = .Anchor, anchor_id = anchor.id, checkpoint = anchor.checkpoint, line = line_no}
				append(&result.program.nodes, node)
				append(&result.program.anchors, Anchor{
					id = anchor.id, title = anchor.title, scene_id = anchor.scene_id, kind = anchor.kind,
					checkpoint = anchor.checkpoint, hidden = anchor.hidden, scene = current_scene, pc = len(result.program.nodes)-1,
				})
			}
			continue
		}
		if strings.has_prefix(line, "@attempt ") || strings.has_prefix(line, "@intent ") {
			if current_choice < 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "@attempt must follow a choice option")
			} else {
				prefix_length := 9
				if strings.has_prefix(line, "@intent ") { prefix_length = 8 }
				action := strings.trim_space(line[prefix_length:])
				result.program.choices[current_choice].action = action
				if _, found := registry_action(registry, action); !found {
					diagnose(&result, .Unknown_Action, line_no, indent+9, action)
				}
			}
			continue
		}
		if strings.has_prefix(line, "@on ") {
			if current_choice < 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "@on must follow a choice option")
			} else if route, ok := parse_outcome_route(line[4:], line_no); !ok {
				diagnose(&result, .Syntax, line_no, indent+1, "expected @on outcome -> target")
			} else {
				choice := &result.program.choices[current_choice]
				duplicate := false
				for existing in result.program.outcome_routes[choice.outcome_start:] {
					if existing.outcome == route.outcome { duplicate = true; break }
				}
				if duplicate {
					diagnose(&result, .Duplicate_Outcome_Route, line_no, indent+1, action_outcome_name(route.outcome))
				} else {
					append(&result.program.outcome_routes, route)
					choice.outcome_count += 1
				}
			}
			continue
		}
		if strings.has_prefix(line, "-> ") {
			target := strings.trim_space(line[3:])
			if current_choice >= 0 {
				result.program.choices[current_choice].target = target
			} else {
				append(&result.program.nodes, Node{kind = .Jump, jump_target = target, target_scene = -1, target_pc = -1, line = line_no})
			}
			continue
		}
		if line == "@end" {
			append(&result.program.nodes, Node{kind = .End, line = line_no})
			choice_node, current_choice = -1, -1
			continue
		}
		if strings.has_prefix(line, "@") {
			diagnose(&result, .Syntax, line_no, indent+1, "unknown directive")
			continue
		}
		choice_node, current_choice = -1, -1
		colon := index_of(line, ":")
		if colon > 0 {
			speaker := strings.trim_space(line[:colon])
			if !registry_has_speaker(registry, speaker) {
				diagnose(&result, .Unknown_Speaker, line_no, indent+1, speaker)
			}
			append(&result.program.nodes, Node{kind = .Dialogue, speaker = speaker, text = strings.trim_space(line[colon+1:]), line = line_no})
		} else {
			append(&result.program.nodes, Node{kind = .Narration, text = line, line = line_no})
		}
	}
	if current_scene >= 0 { result.program.scenes[current_scene].end = len(result.program.nodes) }
	for index in branch_stack {
		diagnose(&result, .Syntax, result.program.nodes[index].line, 1, "unclosed @if")
		result.program.nodes[index].branch_false = result.program.scenes[current_scene].end
	}
	delete(branch_stack)
	delete(branch_else_jumps)
	if len(result.program.scenes) == 0 {
		diagnose(&result, .Syntax, 1, 1, "story must declare at least one scene")
	}
	resolve_targets(&result, registry)
	build_edges(&result.program)
	validate_reachability(&result)
	return result
}

copy_query_schema :: proc(result: ^Compilation, registry: Registry) {
	for field in registry.fields {
		owned_field := field
		owned_field.id = own_query_string(result, field.id)
		owned_field.enum_type = own_query_string(result, field.enum_type)
		owned_field.enum_values = make([]string, len(field.enum_values), context.allocator)
		for i in 0..<len(field.enum_values) {
			owned_field.enum_values[i] = own_query_string(result, field.enum_values[i])
		}
		owned_field.reads = make([]string, len(field.reads), context.allocator)
		for i in 0..<len(field.reads) {
			owned_field.reads[i] = own_query_string(result, field.reads[i])
		}
		append(&result.program.query_fields, owned_field)
	}
}

resolve_targets :: proc(result: ^Compilation, registry: Registry) {
	if len(result.program.scenes) == 0 { return }
	result.program.entry_scene = 0
	for i in 0..<len(result.program.choices) {
		choice := &result.program.choices[i]
		if choice.action == "" { diagnose(result, .Missing_Action, choice.line, 1, choice.label) }
		if choice.target == "" {
			diagnose(result, .Unknown_Target, choice.line, 1, "choice missing accepted -> target")
		} else {
			choice.target_scene, choice.target_pc = resolve_reference(&result.program, choice.target)
			if choice.target_scene < 0 { diagnose(result, .Unknown_Target, choice.line, 1, choice.target) }
		}
		if action, known := registry_action(registry, choice.action); known {
			choice.action_outcomes = action_outcome_mask(action)
			validate_action_routes(result, choice, action)
		}
		for route_index in choice.outcome_start..<choice.outcome_start+choice.outcome_count {
			route := &result.program.outcome_routes[route_index]
			route.target_scene, route.target_pc = resolve_reference(&result.program, route.target)
			if route.target_scene < 0 { diagnose(result, .Unknown_Target, route.line, 1, route.target) }
		}
	}
	for i in 0..<len(result.program.nodes) {
		node := &result.program.nodes[i]
		if node.kind != .Jump || node.target_scene >= 0 { continue }
		node.target_scene, node.target_pc = resolve_reference(&result.program, node.jump_target)
		if node.target_scene < 0 { diagnose(result, .Unknown_Target, node.line, 1, node.jump_target) }
	}
	for i in 0..<len(result.program.contextual_pools) {
		pool := &result.program.contextual_pools[i]
		if pool.fallback_beat < 0 {
			diagnose(result, .Missing_Selection_Fallback, pool.line, 1, pool.id)
		}
	}
	for i in 0..<len(result.program.contextual_beats) {
		beat := &result.program.contextual_beats[i]
		if beat.target == "" {
			diagnose(result, .Unknown_Target, beat.line, 1, "contextual beat missing target")
			continue
		}
		beat.target_scene, beat.target_pc = resolve_reference(&result.program, beat.target)
		if beat.target_scene < 0 { diagnose(result, .Unknown_Target, beat.line, 1, beat.target) }
	}
	for i in 0..<len(result.program.anchors) {
		anchor := &result.program.anchors[i]
		if anchor.checkpoint && anchor.kind != .Choice {
			diagnose(result, .Syntax, 1, 1, "checkpoint anchors must be choices")
		}
	}
}

parse_selection_header :: proc(value: string) -> (id: string, policy: Selection_Policy, ok: bool) {
	s := strings.trim_space(value)
	space := index_of(s, " ")
	if space <= 0 { return "", .Priority, false }
	id = s[:space]
	policy_name := strings.trim_space(s[space+1:])
	if !valid_id(id) || policy_name != "priority" { return "", .Priority, false }
	return id, .Priority, true
}

parse_contextual_beat :: proc(value: string, line: int) -> (beat: Contextual_Beat, ok: bool) {
	s := strings.trim_space(value)
	arrow := index_of(s, " -> ")
	if arrow < 0 { return {}, false }
	declaration := strings.trim_space(s[:arrow])
	condition_marker := index_of(declaration, " if ")
	if condition_marker < 0 { return {}, false }
	header := strings.trim_space(declaration[:condition_marker])
	beat.condition = strings.trim_space(declaration[condition_marker+4:])
	beat.target = strings.trim_space(s[arrow+4:])
	first_space := index_of(header, " ")
	if first_space <= 0 || beat.condition == "" || beat.target == "" { return {}, false }
	beat.id = header[:first_space]
	priority_spec := strings.trim_space(header[first_space+1:])
	if !valid_id(beat.id) || !strings.has_prefix(priority_spec, "priority ") { return {}, false }
	priority, parsed := parse_i64(strings.trim_space(priority_spec[9:]))
	if !parsed { return {}, false }
	beat.priority = priority
	beat.target_scene, beat.target_pc = -1, -1
	beat.line = line
	return beat, true
}

parse_contextual_fallback :: proc(value: string, line: int) -> (beat: Contextual_Beat, ok: bool) {
	s := strings.trim_space(value)
	arrow := index_of(s, " -> ")
	if arrow < 0 { return {}, false }
	beat.id = strings.trim_space(s[:arrow])
	beat.target = strings.trim_space(s[arrow+4:])
	if !valid_id(beat.id) || beat.target == "" { return {}, false }
	beat.condition_index = -1
	beat.fallback = true
	beat.target_scene, beat.target_pc = -1, -1
	beat.line = line
	return beat, true
}

validate_action_routes :: proc(result: ^Compilation, choice: ^Choice, action: Action_Definition) {
	for route in result.program.outcome_routes[choice.outcome_start:choice.outcome_start+choice.outcome_count] {
		if route.outcome == .Accepted || !action_supports_outcome(action, route.outcome) {
			diagnose(result, .Unexpected_Outcome_Route, route.line, 1, action_outcome_name(route.outcome))
		}
	}
	for outcome in ACTION_OUTCOMES {
		if outcome == .Accepted || !action_supports_outcome(action, outcome) { continue }
		if !choice_has_route(result.program, choice, outcome) {
			diagnose(result, .Missing_Outcome_Route, choice.line, 1, action.id)
		}
	}
}

choice_has_route :: proc(program: Program, choice: ^Choice, outcome: Action_Outcome) -> bool {
	for route in program.outcome_routes[choice.outcome_start:choice.outcome_start+choice.outcome_count] {
		if route.outcome == outcome { return true }
	}
	return false
}

action_supports_outcome :: proc(action: Action_Definition, outcome: Action_Outcome) -> bool {
	switch outcome {
	case .Invalid: return false
	case .Accepted: return true
	case .Refused: return action.can_refuse
	case .Interrupted: return action.can_interrupt
	case .Deferred: return action.can_defer
	}
	return false
}

registry_action :: proc(registry: Registry, id: string) -> (action: Action_Definition, found: bool) {
	for candidate in registry.actions {
		if candidate.id == id { return candidate, true }
	}
	return {}, false
}

resolve_reference :: proc(program: ^Program, reference: string) -> (scene, pc: int) {
	marker := index_of(reference, "#")
	scene_id := reference
	anchor_id := ""
	if marker >= 0 {
		scene_id = reference[:marker]
		anchor_id = reference[marker+1:]
	}
	scene = scene_index(program, scene_id)
	if scene < 0 { return -1, -1 }
	pc = program.scenes[scene].start
	if anchor_id != "" {
		index := anchor_index(program, anchor_id)
		if index < 0 || program.anchors[index].scene != scene { return -1, -1 }
		pc = program.anchors[index].pc
	}
	return scene, pc
}

build_edges :: proc(program: ^Program) {
	for scene_index_value in 0..<len(program.scenes) {
		previous := ""
		for anchor in program.anchors {
			if anchor.scene != scene_index_value || anchor.choice { continue }
			if anchor.kind == .Event {
				if previous != "" { append_edge(program, anchor.id, previous, "reveals") }
				continue
			}
			if previous != "" { append_edge(program, previous, anchor.id, "story") }
			previous = anchor.id
		}
	}
	for scene_index_value in 0..<len(program.scenes) {
		scene := program.scenes[scene_index_value]
		for node_index in scene.start..<scene.end {
			node := program.nodes[node_index]
			if node.kind == .Choice_Group {
				source_anchor := previous_anchor(program, scene_index_value, node_index)
				for choice in program.choices[node.choice_start:node.choice_start+node.choice_count] {
					if choice.anchor_id != "" {
						if source_anchor != "" { append_edge(program, source_anchor, choice.anchor_id, "choice") }
						target_anchor := referenced_anchor(program, choice.target_scene, choice.target_pc)
						if target_anchor != "" { append_edge(program, choice.anchor_id, target_anchor, "consequence") }
						for route in program.outcome_routes[choice.outcome_start:choice.outcome_start+choice.outcome_count] {
							route_anchor := referenced_anchor(program, route.target_scene, route.target_pc)
							if route_anchor != "" {
								append_edge(program, choice.anchor_id, route_anchor, outcome_edge_name(route.outcome))
							}
						}
					}
				}
			} else if node.kind == .Jump && node.target_scene >= 0 && node.jump_target != "" {
				source_anchor := previous_anchor(program, scene_index_value, node_index)
				target_anchor := referenced_anchor(program, node.target_scene, node.target_pc)
				if source_anchor != "" && target_anchor != "" { append_edge(program, source_anchor, target_anchor, "jump") }
			} else if node.kind == .Contextual_Select && node.contextual_pool_index >= 0 && node.contextual_pool_index < len(program.contextual_pools) {
				source_anchor := previous_anchor(program, scene_index_value, node_index)
				pool := program.contextual_pools[node.contextual_pool_index]
				for beat in program.contextual_beats[pool.beat_start:pool.beat_start+pool.beat_count] {
					target_anchor := referenced_anchor(program, beat.target_scene, beat.target_pc)
					if source_anchor != "" && target_anchor != "" { append_edge(program, source_anchor, target_anchor, "contextual") }
				}
			}
		}
	}
}

referenced_anchor :: proc(program: ^Program, scene, pc: int) -> string {
	for anchor in program.anchors {
		if anchor.scene == scene && anchor.pc == pc { return anchor.id }
	}
	return first_anchor_in_scene(program, scene)
}

previous_anchor :: proc(program: ^Program, scene, pc: int) -> string {
	latest := ""
	for anchor in program.anchors {
		if anchor.scene == scene && !anchor.choice && anchor.kind != .Event && anchor.pc < pc && anchor.pc >= program.scenes[scene].start { latest = anchor.id }
	}
	return latest
}

first_anchor_in_scene :: proc(program: ^Program, scene: int) -> string {
	if scene < 0 || scene >= len(program.scenes) { return "" }
	for anchor in program.anchors {
		if anchor.scene == scene && !anchor.choice { return anchor.id }
	}
	for anchor in program.anchors {
		if anchor.scene == scene { return anchor.id }
	}
	return ""
}

append_edge :: proc(program: ^Program, from, to, kind: string) {
	for edge in program.edges { if edge.from == from && edge.to == to && edge.kind == kind { return } }
	append(&program.edges, Edge{from = from, to = to, kind = kind})
}

validate_reachability :: proc(result: ^Compilation) {
	if len(result.program.scenes) == 0 { return }
	reachable := make([]bool, len(result.program.scenes), context.temp_allocator)
	reachable[0] = true
	changed := true
	for changed {
		changed = false
		// All outgoing jumps and options from a reachable scene are considered.
		for i in 0..<len(result.program.scenes) {
			if !reachable[i] { continue }
			scene := result.program.scenes[i]
			for node in result.program.nodes[scene.start:scene.end] {
				if node.kind == .Jump && node.target_scene >= 0 && !reachable[node.target_scene] { reachable[node.target_scene] = true; changed = true }
				if node.kind == .Choice_Group {
					for option in result.program.choices[node.choice_start:node.choice_start+node.choice_count] {
						if option.target_scene >= 0 && !reachable[option.target_scene] { reachable[option.target_scene] = true; changed = true }
						for route in result.program.outcome_routes[option.outcome_start:option.outcome_start+option.outcome_count] {
							if route.target_scene >= 0 && !reachable[route.target_scene] { reachable[route.target_scene] = true; changed = true }
						}
					}
				}
				if node.kind == .Contextual_Select && node.contextual_pool_index >= 0 && node.contextual_pool_index < len(result.program.contextual_pools) {
					pool := result.program.contextual_pools[node.contextual_pool_index]
					for beat in result.program.contextual_beats[pool.beat_start:pool.beat_start+pool.beat_count] {
						if beat.target_scene >= 0 && !reachable[beat.target_scene] { reachable[beat.target_scene] = true; changed = true }
					}
				}
			}
		}
	}
	for i in 0..<len(result.program.scenes) {
		if !reachable[i] { diagnose(result, .Unreachable_Scene, 1, 1, result.program.scenes[i].id) }
	}
}

diagnose :: proc(result: ^Compilation, code: Diagnostic_Code, line, column: int, token: string) {
	owned_token := own_diagnostic_string(result, token)
	append(&result.diagnostics, Diagnostic{code = code, line = line, column = column, token = owned_token})
}

own_diagnostic_string :: proc(result: ^Compilation, value: string) -> string {
	if value == "" { return "" }
	bytes := make([]u8, len(value), context.allocator)
	copy(bytes, transmute([]u8)value)
	append(&result.diagnostic_string_storage, bytes)
	return string(bytes)
}

own_query_string :: proc(result: ^Compilation, value: string) -> string {
	if value == "" { return "" }
	bytes := make([]u8, len(value), context.allocator)
	copy(bytes, transmute([]u8)value)
	append(&result.program.query_string_storage, bytes)
	return string(bytes)
}

validate_registry :: proc(result: ^Compilation, registry: Registry) {
	for i in 0..<len(registry.actions) {
		action := registry.actions[i]
		if !valid_id(action.id) { diagnose(result, .Invalid_ID, 1, 1, action.id) }
		for previous in registry.actions[:i] {
			if previous.id == action.id { diagnose(result, .Duplicate_Action, 1, 1, action.id) }
		}
	}
	for i in 0..<len(registry.fields) {
		field := registry.fields[i]
		if !valid_id(field.id) {
			diagnose(result, .Invalid_Field_Definition, 1, 1, field.id)
			continue
		}
		for previous in registry.fields[:i] {
			if previous.id == field.id { diagnose(result, .Duplicate_Field, 1, 1, field.id) }
		}
		if field.type == .Invalid || (field.opaque && field.type != .Boolean) {
			diagnose(result, .Invalid_Field_Definition, 1, 1, field.id)
		}
		if field.type == .Enumeration {
			if field.enum_type == "" || len(field.enum_values) == 0 {
				diagnose(result, .Invalid_Field_Definition, 1, 1, field.id)
			}
			for enum_index in 0..<len(field.enum_values) {
				value := field.enum_values[enum_index]
				if !valid_id(value) { diagnose(result, .Invalid_Field_Definition, 1, 1, value) }
				for previous in field.enum_values[:enum_index] {
					if previous == value { diagnose(result, .Invalid_Field_Definition, 1, 1, value) }
				}
			}
		} else if field.enum_type != "" || len(field.enum_values) != 0 {
			diagnose(result, .Invalid_Field_Definition, 1, 1, field.id)
		}
		for dependency in field.reads {
			if _, found := registry_field(registry, dependency); !found {
				diagnose(result, .Unknown_Field, 1, 1, dependency)
			}
		}
	}
}

registry_field :: proc(registry: Registry, id: string) -> (field: Field_Definition, found: bool) {
	for candidate in registry.fields {
		if candidate.id == id { return candidate, true }
	}
	return {}, false
}

registry_has_speaker :: proc(registry: Registry, value: string) -> bool {
	for candidate in registry.speakers { if candidate == value { return true } }
	return false
}

parse_outcome_route :: proc(value: string, line: int) -> (route: Choice_Outcome_Route, ok: bool) {
	s := strings.trim_space(value)
	arrow := index_of(s, "->")
	if arrow < 0 { return {}, false }
	name := strings.trim_space(s[:arrow])
	route.outcome, ok = parse_action_outcome(name)
	if !ok { return {}, false }
	route.target = strings.trim_space(s[arrow+2:])
	route.target_scene, route.target_pc = -1, -1
	route.line = line
	return route, route.target != ""
}

parse_action_outcome :: proc(name: string) -> (outcome: Action_Outcome, ok: bool) {
	switch name {
	case "accepted": return .Accepted, true
	case "refused": return .Refused, true
	case "interrupted": return .Interrupted, true
	case "deferred": return .Deferred, true
	}
	return .Invalid, false
}

action_outcome_name :: proc(outcome: Action_Outcome) -> string {
	switch outcome {
	case .Invalid: return "invalid"
	case .Accepted: return "accepted"
	case .Refused: return "refused"
	case .Interrupted: return "interrupted"
	case .Deferred: return "deferred"
	}
	return "unknown"
}

outcome_edge_name :: proc(outcome: Action_Outcome) -> string {
	switch outcome {
	case .Invalid: return "outcome_invalid"
	case .Accepted: return "outcome_accepted"
	case .Refused: return "outcome_refused"
	case .Interrupted: return "outcome_interrupted"
	case .Deferred: return "outcome_deferred"
	}
	return "outcome_unknown"
}

indentation :: proc(line: string) -> int {
	count := 0
	for ch in line {
		if ch == ' ' { count += 1 } else if ch == '\t' { count += 2 } else { break }
	}
	return count
}

valid_id :: proc(id: string) -> bool {
	if id == "" { return false }
	for ch, i in id {
		if !(ch >= 'a' && ch <= 'z') && !(ch >= 'A' && ch <= 'Z') && !(ch >= '0' && ch <= '9') && ch != '_' && ch != '.' && ch != '-' {
			return false
		}
		if i == 0 && ch >= '0' && ch <= '9' { return false }
	}
	return true
}

parse_anchor :: proc(value: string) -> (anchor: Anchor, ok: bool) {
	s := strings.trim_space(value)
	first_space := index_of(s, " ")
	if first_space <= 0 { return {}, false }
	anchor.id = s[:first_space]
	rest := strings.trim_space(s[first_space:])
	if len(rest) < 2 || rest[0] != '"' { return {}, false }
	close_quote := index_of(rest[1:], "\"")
	if close_quote < 0 { return {}, false }
	anchor.title = rest[1:close_quote+1]
	rest = strings.trim_space(rest[close_quote+2:])
	kind_end := index_of(rest, " ")
	kind := rest
	if kind_end >= 0 { kind = rest[:kind_end]; rest = strings.trim_space(rest[kind_end:]) } else { rest = "" }
	switch kind {
	case "start": anchor.kind = .Start
	case "choice": anchor.kind = .Choice
	case "discovery": anchor.kind = .Discovery
	case "outcome": anchor.kind = .Outcome
	case "event": anchor.kind = .Event
	case: return {}, false
	}
	for token in strings.split(rest, " ", context.temp_allocator) {
		if token == "checkpoint" { anchor.checkpoint = true }
		if token == "hidden" { anchor.hidden = true }
	}
	return anchor, true
}

quoted_value :: proc(value: string) -> string {
	s := strings.trim_space(value)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' { return s[1:len(s)-1] }
	return s
}

index_of :: proc(value, needle: string) -> int {
	if needle == "" { return 0 }
	if len(value) < len(needle) { return -1 }
	for i in 0..=len(value)-len(needle) {
		if value[i:i+len(needle)] == needle { return i }
	}
	return -1
}

source_hash :: proc(source: string) -> u64 {
	hash: u64 = 14695981039346656037
	for byte in source {
		hash = (hash~u64(byte))*1099511628211
	}
	return hash
}

identity_hash :: proc(program_id: string, version: u32, source_digest: u64) -> u64 {
	hash := source_hash(program_id)
	for shift in 0..<4 { hash = (hash~u64((version >> u32(shift*8))&0xff))*1099511628211 }
	for shift in 0..<8 { hash = (hash~u64((source_digest >> u32(shift*8))&0xff))*1099511628211 }
	return hash
}
