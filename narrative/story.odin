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

Query_Type :: enum u8 {
	Invalid,
	Boolean,
	Integer,
	Enumeration,
}

Query_Operator :: enum u8 {
	Field,
	Opaque_Field,
	Boolean_Literal,
	Integer_Literal,
	Enumeration_Literal,
	Not,
	And,
	Or,
	Equal,
	Not_Equal,
	Less,
	Less_Equal,
	Greater,
	Greater_Equal,
}

Query_Error :: enum u8 {
	None,
	Invalid_Expression,
	Unknown_Field,
	Resolver_Failed,
	Type_Mismatch,
}

Query_Value :: struct {
	type:         Query_Type,
	boolean:      bool,
	integer:      i64,
	enum_type:    string,
	enum_value:   string,
}

Query_Node :: struct {
	operator:      Query_Operator,
	type:          Query_Type,
	field_id:      string,
	enum_type:     string,
	enum_value:    string,
	boolean:       bool,
	integer:       i64,
	left:          int,
	right:         int,
	line:          int,
	column:        int,
}

Query_Expression :: struct {
	source: string,
	root:   int,
	line:   int,
}

Query_Evaluation_Step :: struct {
	node_index: int,
	operator:   Query_Operator,
	field_id:   string,
	failed_field: string,
	value:      Query_Value,
	error:      Query_Error,
	skipped:    bool,
}

Query_Explanation :: struct {
	expression:  string,
	value:       bool,
	error:       Query_Error,
	failed_field: string,
	steps:       [dynamic]Query_Evaluation_Step,
}

Action_Outcome :: enum u8 {
	Invalid,
	Accepted,
	Refused,
	Interrupted,
	Deferred,
}

Action_Definition :: struct {
	id:              string,
	can_refuse:      bool,
	can_interrupt:   bool,
	can_defer:       bool,
}

Action_Error :: enum u8 {
	None,
	Invalid_Command,
}

Action_Execution :: struct {
	error:   Action_Error,
	outcome: Action_Outcome,
}

Action_Resolver :: #type proc(user_data: rawptr, choice: ^Choice) -> Action_Execution

Choice_ID :: struct {
	program_hash: u64,
	index:        u32,
}

Field_Definition :: struct {
	id:          string,
	type:        Query_Type,
	enum_type:   string,
	enum_values: []string,
	opaque:      bool,
	reads:       []string,
}

Field_Resolver :: #type proc(user_data: rawptr, field_id: string) -> (Query_Value, Query_Error)

Program_Metadata :: struct {
	id:      string,
	version: u32,
}

Program_Identity :: struct {
	id:          string,
	version:     u32,
	source_hash: u64,
	identity_hash: u64,
}

Node_Kind :: enum u8 {
	Dialogue,
	Narration,
	Choice_Group,
	Contextual_Select,
	Branch,
	Jump,
	Anchor,
	End,
}

// Rich text syntax in source uses paired [b], [i], [u], [s], and
// [color=semantic_name] tags. [pause=250ms] and [sfx=stable_key] add cues at
// their source position; [speed=24]...[/speed] changes reveal speed for a
// span and restores the previous speed at its end. Double brackets ([[ and ]])
// produce literal brackets. Compilation strips tags into plain visible text
// plus grapheme-indexed spans and cues, leaving rendering to the host.
Text_Style :: enum u8 {
	Bold,
	Italic,
	Underline,
	Strike,
	Color,
}

Text_Span :: struct {
	start: int,
	end:   int,
	depth: int, // Outer spans have smaller depth than nested spans.
	style: Text_Style,
	value: string, // Used by semantic styles such as Color; otherwise empty.
}

Presentation_Cue_Kind :: enum u8 {
	Pause,
	Speed,
	Sound_Effect,
}

Presentation_Cue :: struct {
	position:   int, // Grapheme index in the owning Node.text.
	kind:       Presentation_Cue_Kind,
	duration_ms: int, // Pause duration; zero for other cue kinds.
	speed:      int, // Graphemes per second; zero restores host default.
	value:      string, // Sound-effect key; empty for pause/speed.
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
	condition_index: int,
	branch_true:   int,
	branch_false:  int,
	jump_target:   string,
	target_scene:  int,
	target_pc:     int,
	choice_start:  int,
	choice_count:  int,
	contextual_pool_index: int,
	anchor_id:     string,
	checkpoint:    bool,
	line:          int,
	line_id:       string, // Stable only when authored with @line; otherwise empty.
	text_span_start: int,
	text_span_count: int,
	presentation_cue_start: int,
	presentation_cue_count: int,
}

Selection_Policy :: enum u8 {
	Priority,
}

Contextual_Pool :: struct {
	id:            string,
	policy:        Selection_Policy,
	beat_start:    int,
	beat_count:    int,
	fallback_beat: int,
	line:          int,
}

Contextual_Beat :: struct {
	id:              string,
	condition:       string,
	condition_index: int,
	priority:        i64,
	fallback:        bool,
	target:          string,
	target_scene:    int,
	target_pc:       int,
	line:            int,
}

Contextual_Selection_Error :: enum u8 {
	None,
	Unknown_Pool,
	Missing_Fallback,
	Query_Evaluation_Failed,
	Invalid_Target,
}

Contextual_Beat_Explanation :: struct {
	beat_id:   string,
	condition: string,
	priority:  i64,
	fallback:  bool,
	eligible:  bool,
	selected:  bool,
	query:     Query_Explanation,
}

Contextual_Selection_Explanation :: struct {
	pool_id:          string,
	selected_beat_id: string,
	error:            Contextual_Selection_Error,
	beats:            [dynamic]Contextual_Beat_Explanation,
}

Contextual_Selection :: struct {
	beat_index:  int,
	target:      Cursor,
	error:       Contextual_Selection_Error,
	query_error: Query_Error,
}

Choice :: struct {
	label:           string,
	action:          string,
	target:          string,
	condition:       string,
	condition_index: int,
	condition_not:   bool,
	anchor_id:       string,
	target_scene:    int,
	target_pc:       int,
	line:            int,
	outcome_start:   int,
	outcome_count:   int,
	action_outcomes: u8,
}

Choice_Outcome_Route :: struct {
	outcome:       Action_Outcome,
	target:        string,
	target_scene:  int,
	target_pc:     int,
	line:          int,
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
	identity: Program_Identity,
	identity_id_storage: []u8,
	query_string_storage: [dynamic][]u8,
	rich_text_string_storage: [dynamic][]u8,
	query_fields: [dynamic]Field_Definition,
	scenes:  [dynamic]Scene,
	nodes:   [dynamic]Node,
	choices: [dynamic]Choice,
	outcome_routes: [dynamic]Choice_Outcome_Route,
	contextual_pools: [dynamic]Contextual_Pool,
	contextual_beats: [dynamic]Contextual_Beat,
	anchors: [dynamic]Anchor,
	edges:   [dynamic]Edge,
	query_nodes: [dynamic]Query_Node,
	queries: [dynamic]Query_Expression,
	text_spans: [dynamic]Text_Span,
	presentation_cues: [dynamic]Presentation_Cue,
	entry_scene: int,
}

Registry :: struct {
	speakers:   []string,
	actions:    []Action_Definition,
	fields:     []Field_Definition,
}

Diagnostic_Code :: enum u8 {
	Syntax,
	Invalid_ID,
	Duplicate_Scene,
	Duplicate_Anchor,
	Unknown_Speaker,
	Unknown_Action,
	Unknown_Condition,
	Unknown_Field,
	Invalid_Query,
	Query_Type_Mismatch,
	Invalid_Field_Definition,
	Duplicate_Field,
	Duplicate_Action,
	Unknown_Target,
	Missing_Action,
	Missing_Outcome_Route,
	Unexpected_Outcome_Route,
	Duplicate_Outcome_Route,
	Unreachable_Scene,
	Duplicate_Selection_Pool,
	Duplicate_Selection_Beat,
	Invalid_Selection,
	Missing_Selection_Fallback,
	Invalid_Line_ID,
	Duplicate_Line_ID,
	Misplaced_Line_ID,
	Malformed_Rich_Text,
}

Diagnostic :: struct {
	code:   Diagnostic_Code,
	line:   int,
	column: int,
	token:  string,
}

Compilation :: struct {
	program:                   Program,
	diagnostics:               [dynamic]Diagnostic,
	diagnostic_string_storage: [dynamic][]u8,
}

Cursor :: struct {
	scene:     int,
	scene_id:  string,
	pc:        int,
	anchor_id: string,
}

destroy_program :: proc(program: ^Program) {
	delete(program.source)
	delete(program.identity_id_storage)
	for value in program.query_string_storage { delete(value) }
	delete(program.query_string_storage)
	for value in program.rich_text_string_storage { delete(value) }
	delete(program.rich_text_string_storage)
	for field in program.query_fields {
		delete(field.enum_values)
		delete(field.reads)
	}
	delete(program.query_fields)
	delete(program.scenes)
	delete(program.nodes)
	delete(program.choices)
	delete(program.outcome_routes)
	delete(program.contextual_pools)
	delete(program.contextual_beats)
	delete(program.anchors)
	delete(program.edges)
	delete(program.query_nodes)
	delete(program.queries)
	delete(program.text_spans)
	delete(program.presentation_cues)
	program^ = {}
}

destroy_compilation :: proc(compilation: ^Compilation) {
	destroy_program(&compilation.program)
	for value in compilation.diagnostic_string_storage { delete(value) }
	delete(compilation.diagnostic_string_storage)
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
