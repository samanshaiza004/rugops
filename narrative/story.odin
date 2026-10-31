// Package narrative defines a small compiled representation for game-owned
// narrative runtimes. Authored scene IDs and anchors are stable source IDs;
// ordinary dialogue positions are compile-local and are not save identities.
package narrative

Anchor_Kind :: enum u8 {
	None,
	Start,
	Choice,
	Discovery,
	Outcome,
	Event,
}

Node_Kind :: enum u8 {
	Dialogue,
	Narration,
	Choice_Group,
	Branch,
	Jump,
	Anchor,
	End,
}

Scene :: struct {
	id:       string,
	title:    string,
	location: string,
	start:    int,
	end:      int,
}

Node :: struct {
	kind:          Node_Kind,
	speaker:       string,
	text:          string,
	condition:     string,
	branch_true:   int,
	branch_false:  int,
	jump_target:   string,
	target_scene:  int,
	target_pc:     int,
	choice_start:  int,
	choice_count:  int,
	anchor_id:     string,
	checkpoint:    bool,
	line:          int,
}

Choice :: struct {
	label:           string,
	action:          string,
	target:          string,
	condition:       string,
	condition_not:   bool,
	anchor_id:       string,
	target_scene:    int,
	target_pc:       int,
	line:            int,
}

Anchor :: struct {
	id:         string,
	title:      string,
	scene_id:   string,
	kind:       Anchor_Kind,
	hidden:     bool,
	checkpoint: bool,
	choice:     bool,
	scene:      int,
	pc:         int,
}

Edge :: struct {
	from: string,
	to:   string,
	kind: string,
}

Program :: struct {
	source:  []u8,
	scenes:  [dynamic]Scene,
	nodes:   [dynamic]Node,
	choices: [dynamic]Choice,
	anchors: [dynamic]Anchor,
	edges:   [dynamic]Edge,
	entry_scene: int,
}

Registry :: struct {
	speakers:   []string,
	actions:    []string,
	conditions: []string,
}

Diagnostic_Code :: enum u8 {
	Syntax,
	Invalid_ID,
	Duplicate_Scene,
	Duplicate_Anchor,
	Unknown_Speaker,
	Unknown_Action,
	Unknown_Condition,
	Unknown_Target,
	Missing_Action,
	Unreachable_Scene,
}

Diagnostic :: struct {
	code:   Diagnostic_Code,
	line:   int,
	column: int,
	token:  string,
}

Compilation :: struct {
	program:     Program,
	diagnostics: [dynamic]Diagnostic,
}

Cursor :: struct {
	scene:     int,
	scene_id:  string,
	pc:        int,
	anchor_id: string,
}

destroy_program :: proc(program: ^Program) {
	delete(program.source)
	delete(program.scenes)
	delete(program.nodes)
	delete(program.choices)
	delete(program.anchors)
	delete(program.edges)
	program^ = {}
}

destroy_compilation :: proc(compilation: ^Compilation) {
	destroy_program(&compilation.program)
	delete(compilation.diagnostics)
	compilation^ = {}
}

has_errors :: proc(compilation: ^Compilation) -> bool {
	return len(compilation.diagnostics) > 0
}

scene_index :: proc(program: ^Program, id: string) -> int {
	for i in 0..<len(program.scenes) {
		if program.scenes[i].id == id { return i }
	}
	return -1
}

anchor_index :: proc(program: ^Program, id: string) -> int {
	for i in 0..<len(program.anchors) {
		if program.anchors[i].id == id { return i }
	}
	return -1
}

anchor_pc :: proc(program: ^Program, scene: int, id: string) -> int {
	for i in 0..<len(program.anchors) {
		anchor := program.anchors[i]
		if anchor.scene == scene && anchor.id == id { return anchor.pc }
	}
	return -1
}

scene_entry :: proc(program: ^Program, scene: int) -> Cursor {
	if scene < 0 || scene >= len(program.scenes) { return {} }
	return Cursor{scene = scene, scene_id = program.scenes[scene].id, pc = program.scenes[scene].start}
}

cursor_at_anchor :: proc(program: ^Program, scene_id, anchor_id: string) -> (cursor: Cursor, ok: bool) {
	scene := scene_index(program, scene_id)
	anchor_index_value := anchor_index(program, anchor_id)
	if scene < 0 || anchor_index_value < 0 { return {}, false }
	anchor := program.anchors[anchor_index_value]
	if anchor.scene != scene { return {}, false }
	pc := anchor.pc
	if !anchor.choice { pc += 1 }
	return Cursor{scene = scene, scene_id = scene_id, pc = pc, anchor_id = anchor_id}, true
}

node_at :: proc(program: ^Program, cursor: Cursor) -> (node: ^Node, ok: bool) {
	if cursor.scene < 0 || cursor.scene >= len(program.scenes) { return nil, false }
	scene := program.scenes[cursor.scene]
	if cursor.pc < scene.start || cursor.pc >= scene.end || cursor.pc >= len(program.nodes) { return nil, false }
	return &program.nodes[cursor.pc], true
}
