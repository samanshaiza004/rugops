package narrative

import "core:strings"

compile :: proc(source: string, registry: Registry) -> Compilation {
	result := Compilation{}
	result.program.source = make([]u8, len(source))
	copy(result.program.source, transmute([]u8)source)
	owned_source := string(result.program.source)
	lines, _ := strings.split_lines(owned_source, context.temp_allocator)
	current_scene := -1
	choice_node := -1
	current_choice := -1
	choice_condition := ""
	choice_condition_not := false
	branch_stack: [dynamic]int
	branch_else_jumps: [dynamic]int
	for raw_line, line_index in lines {
		line_no := line_index+1
		indent := indentation(raw_line)
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "//") { continue }
		if strings.has_prefix(line, ":: ") {
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
			choice_condition_not = false
			continue
		}
		if current_scene < 0 {
			diagnose(&result, .Syntax, line_no, 1, "expected a :: scene declaration")
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
				condition_not = choice_condition_not,
				target_scene = -1,
				target_pc = -1,
				line = line_no,
			}
			append(&result.program.choices, choice)
			current_choice = len(result.program.choices)-1
			result.program.nodes[choice_node].choice_count += 1
			continue
		}
		if strings.has_prefix(line, "@if ") {
			condition := strings.trim_space(line[4:])
			if !registry_has_condition(registry, condition) {
				diagnose(&result, .Unknown_Condition, line_no, indent+5, condition)
			}
			if choice_node >= 0 && indent > 0 {
				choice_condition = condition
				choice_condition_not = false
				continue
			}
			branch := Node{kind = .Branch, condition = condition, branch_true = len(result.program.nodes)+1, branch_false = -1, line = line_no}
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
		if strings.has_prefix(line, "@intent ") {
			if current_choice < 0 {
				diagnose(&result, .Syntax, line_no, indent+1, "@intent must follow a choice option")
			} else {
				action := strings.trim_space(line[8:])
				result.program.choices[current_choice].action = action
				if !registry_has_action(registry, action) {
					diagnose(&result, .Unknown_Action, line_no, indent+9, action)
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
	resolve_targets(&result)
	build_edges(&result.program)
	validate_reachability(&result)
	return result
}

resolve_targets :: proc(result: ^Compilation) {
	if len(result.program.scenes) == 0 { return }
	result.program.entry_scene = 0
	for i in 0..<len(result.program.choices) {
		choice := &result.program.choices[i]
		if choice.action == "" { diagnose(result, .Missing_Action, choice.line, 1, choice.label) }
		if choice.target == "" { diagnose(result, .Unknown_Target, choice.line, 1, "choice missing -> target"); continue }
		choice.target_scene, choice.target_pc = resolve_reference(&result.program, choice.target)
		if choice.target_scene < 0 { diagnose(result, .Unknown_Target, choice.line, 1, choice.target) }
	}
	for i in 0..<len(result.program.nodes) {
		node := &result.program.nodes[i]
		if node.kind != .Jump || node.target_scene >= 0 { continue }
		node.target_scene, node.target_pc = resolve_reference(&result.program, node.jump_target)
		if node.target_scene < 0 { diagnose(result, .Unknown_Target, node.line, 1, node.jump_target) }
	}
	for i in 0..<len(result.program.anchors) {
		anchor := &result.program.anchors[i]
		if anchor.checkpoint && anchor.kind != .Choice {
			diagnose(result, .Syntax, 1, 1, "checkpoint anchors must be choices")
		}
	}
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
					}
				}
			} else if node.kind == .Jump && node.target_scene >= 0 && node.jump_target != "" {
				source_anchor := previous_anchor(program, scene_index_value, node_index)
				target_anchor := referenced_anchor(program, node.target_scene, node.target_pc)
				if source_anchor != "" && target_anchor != "" { append_edge(program, source_anchor, target_anchor, "jump") }
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
	append(&result.diagnostics, Diagnostic{code = code, line = line, column = column, token = token})
}

registry_has_speaker :: proc(registry: Registry, value: string) -> bool {
	for candidate in registry.speakers { if candidate == value { return true } }
	return false
}

registry_has_action :: proc(registry: Registry, value: string) -> bool {
	for candidate in registry.actions { if candidate == value { return true } }
	return false
}

registry_has_condition :: proc(registry: Registry, value: string) -> bool {
	for candidate in registry.conditions { if candidate == value { return true } }
	return false
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
