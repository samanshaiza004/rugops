package tests

import "core:testing"
import narrative "rugops:narrative"

NARRATIVE_TEST_SPEAKERS: [1]string = {"Narrator"}
NARRATIVE_TEST_ACTIONS: [3]narrative.Action_Definition = {
	{id = "continue_story"},
	{id = "ask_about_page", can_refuse = true},
	{id = "talk_to_masha", can_interrupt = true},
}
NARRATIVE_TEST_ENUM_VALUES: [2]string = {"archive", "courtyard"}
NARRATIVE_TEST_FIELDS: [5]narrative.Field_Definition = {
	{id = "page_found", type = .Boolean},
	{id = "bond", type = .Integer},
	{id = "location", type = .Enumeration, enum_type = "location", enum_values = NARRATIVE_TEST_ENUM_VALUES[:]},
	{id = "can_smell_trap", type = .Boolean, opaque = true, reads = {"page_found"}},
	{id = "rafael.suspects_player", type = .Boolean},
}

Narrative_Test_Context :: struct {
	page_found:      bool,
	bond:            i64,
	location:        string,
	refuse_action:   bool,
	interrupt_action: bool,
	reject_action:   bool,
	actions_applied: u32,
	scene_count:     u32,
	anchor_count:    u32,
	checkpoint_count: u32,
	resolver_calls:  u32,
	suspects_player: bool,
}

narrative_test_registry :: proc() -> narrative.Registry {
	return narrative.Registry{
		speakers = NARRATIVE_TEST_SPEAKERS[:],
		actions = NARRATIVE_TEST_ACTIONS[:],
		fields = NARRATIVE_TEST_FIELDS[:],
	}
}

narrative_test_field :: proc(user_data: rawptr, field_id: string) -> (narrative.Query_Value, narrative.Query_Error) {
	test_context := cast(^Narrative_Test_Context)user_data
	switch field_id {
	case "page_found": return narrative.Query_Value{type = .Boolean, boolean = test_context.page_found}, .None
	case "bond": return narrative.Query_Value{type = .Integer, integer = test_context.bond}, .None
	case "location": return narrative.Query_Value{type = .Enumeration, enum_type = "location", enum_value = test_context.location}, .None
	case "can_smell_trap": return narrative.Query_Value{type = .Boolean, boolean = test_context.page_found}, .None
	case "rafael.suspects_player": return narrative.Query_Value{type = .Boolean, boolean = test_context.suspects_player}, .None
	}
	return {}, .Unknown_Field
}

narrative_test_wrong_enum_field :: proc(user_data: rawptr, field_id: string) -> (narrative.Query_Value, narrative.Query_Error) {
	_ = user_data
	if field_id == "location" {
		return narrative.Query_Value{type = .Enumeration, enum_type = "weather", enum_value = "archive"}, .None
	}
	return {}, .Unknown_Field
}

narrative_test_short_circuit_field :: proc(user_data: rawptr, field_id: string) -> (narrative.Query_Value, narrative.Query_Error) {
	test_context := cast(^Narrative_Test_Context)user_data
	test_context.resolver_calls += 1
	if field_id == "page_found" {
		return narrative.Query_Value{type = .Boolean, boolean = test_context.page_found}, .None
	}
	if field_id == "rafael.suspects_player" {
		return narrative.Query_Value{type = .Boolean, boolean = test_context.suspects_player}, .None
	}
	return {}, .Resolver_Failed
}

narrative_test_action :: proc(user_data: rawptr, choice: ^narrative.Choice) -> narrative.Action_Execution {
	test_context := cast(^Narrative_Test_Context)user_data
	if test_context.reject_action { return narrative.Action_Execution{error = .Invalid_Command} }
	if choice.action == "ask_about_page" && test_context.refuse_action {
		assert(narrative.choice_declares_outcome(choice, .Refused))
		test_context.actions_applied += 1
		return narrative.Action_Execution{outcome = .Refused}
	}
	if choice.action == "talk_to_masha" && test_context.interrupt_action {
		assert(narrative.choice_declares_outcome(choice, .Interrupted))
		test_context.actions_applied += 1
		return narrative.Action_Execution{outcome = .Interrupted}
	}
	if choice.action == "continue_story" {
		assert(narrative.choice_declares_outcome(choice, .Accepted))
		test_context.actions_applied += 1
		return narrative.Action_Execution{outcome = .Accepted}
	}
	return narrative.Action_Execution{error = .Invalid_Command}
}

narrative_test_missing_outcome :: proc(user_data: rawptr, choice: ^narrative.Choice) -> narrative.Action_Execution {
	_, _ = user_data, choice
	return {}
}

narrative_test_event :: proc(user_data: rawptr, event: narrative.Runtime_Event) {
	test_context := cast(^Narrative_Test_Context)user_data
	switch event.kind {
	case .Scene_Entered: test_context.scene_count += 1
	case .Anchor_Reached:
		test_context.anchor_count += 1
		if event.checkpoint { test_context.checkpoint_count += 1 }
	case .Contextual_Beat_Selected:
	}
}

narrative_test_advance :: proc(program: ^narrative.Program, state: ^narrative.State, user_data: rawptr) -> bool {
	runtime_error, query_error := narrative.advance(program, state, user_data, narrative_test_field, narrative_test_event)
	return runtime_error == .None && query_error == .None
}

narrative_test_compile_errors :: proc(source: string) -> bool {
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	return narrative.has_errors(&compiled)
}

@(test)
narrative_runtime_evaluates_typed_queries_and_explains_results :: proc(t: ^testing.T) {
	_ = t
	source := `:: introduction
@anchor introduction "Introduction" start
@if page_found and (bond >= 3 or location == archive)
Narrator: The evidence is ready.
@else
Narrator: The evidence is incomplete.
@endif
@end
`
	compiled := narrative.compile(source, narrative_test_registry(), narrative.Program_Metadata{id = "query-test", version = 3})
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	assert(compiled.program.identity.id == "query-test")
	assert(compiled.program.identity.version == 3)
	assert(compiled.program.identity.source_hash != 0)
	assert(len(compiled.program.query_fields) == len(NARRATIVE_TEST_FIELDS))
	assert(compiled.program.query_fields[3].reads[0] == "page_found")
	state := narrative.new_state(&compiled.program)
	test_context := Narrative_Test_Context{page_found = true, bond = 1, location = "archive"}
	user_data := cast(rawptr)&test_context
	assert(narrative_test_advance(&compiled.program, &state, user_data))
	node, ok := narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "The evidence is ready.")
	query := narrative.explain_query(&compiled.program, 0, user_data, narrative_test_field)
	defer narrative.destroy_query_explanation(&query)
	assert(query.error == .None && query.value)
	assert(len(query.steps) >= 7)
	test_context.page_found = false
	query_false := narrative.explain_query(&compiled.program, 0, user_data, narrative_test_field)
	defer narrative.destroy_query_explanation(&query_false)
	assert(query_false.error == .None && !query_false.value)
}

@(test)
narrative_boolean_queries_short_circuit_and_explain_skipped_fields :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: start
@if page_found and opaque:can_smell_trap
Narrator: both
@endif
@if page_found or opaque:can_smell_trap
Narrator: either
@endif
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	context_value := Narrative_Test_Context{}
	user_data := cast(rawptr)&context_value
	and_explanation := narrative.explain_query(&compiled.program, 0, user_data, narrative_test_short_circuit_field)
	defer narrative.destroy_query_explanation(&and_explanation)
	assert(and_explanation.error == .None && !and_explanation.value)
	assert(context_value.resolver_calls == 1)
	assert(len(and_explanation.steps) > 0)
	skipped_and_field := false
	for step in and_explanation.steps {
		if step.field_id == "can_smell_trap" && step.skipped { skipped_and_field = true }
	}
	assert(skipped_and_field)
	context_value.page_found = true
	context_value.resolver_calls = 0
	or_explanation := narrative.explain_query(&compiled.program, 1, user_data, narrative_test_short_circuit_field)
	defer narrative.destroy_query_explanation(&or_explanation)
	assert(or_explanation.error == .None && or_explanation.value)
	assert(context_value.resolver_calls == 1)
	skipped_or_field := false
	for step in or_explanation.steps {
		if step.field_id == "can_smell_trap" && step.skipped { skipped_or_field = true }
	}
	assert(skipped_or_field)
}

@(test)
narrative_contextual_selection_uses_priority_stable_ties_fallback_and_explanations :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: ask
@anchor ask "Masha answers" start
@select masha_response priority
  @beat distrustful priority 20 if rafael.suspects_player -> reply.distrustful
  @beat suspicious priority 10 if page_found -> reply.suspicious
  @beat suspicious_alt priority 10 if page_found -> reply.alternate
  @fallback ordinary -> reply.ordinary
@endselect

:: reply.ordinary
Narrator: ordinary response
@end

:: reply.suspicious
Narrator: suspicious response
@end

:: reply.alternate
Narrator: alternate response
@end

:: reply.distrustful
Narrator: distrustful response
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	context_value := Narrative_Test_Context{}
	user_data := cast(rawptr)&context_value
	ordinary := narrative.explain_contextual_selection(&compiled.program, "masha_response", user_data, narrative_test_field)
	defer narrative.destroy_contextual_selection_explanation(&ordinary)
	assert(ordinary.error == .None && ordinary.selected_beat_id == "ordinary")
	assert(ordinary.beats[0].eligible == false && ordinary.beats[0].query.value == false)
	assert(ordinary.beats[3].fallback && ordinary.beats[3].selected)

	context_value.page_found = true
	suspicious := narrative.explain_contextual_selection(&compiled.program, "masha_response", user_data, narrative_test_field)
	defer narrative.destroy_contextual_selection_explanation(&suspicious)
	assert(suspicious.error == .None && suspicious.selected_beat_id == "suspicious")
	assert(suspicious.beats[1].eligible && suspicious.beats[1].selected)
	assert(suspicious.beats[2].eligible && !suspicious.beats[2].selected)

	context_value.suspects_player = true
	distrustful := narrative.explain_contextual_selection(&compiled.program, "masha_response", user_data, narrative_test_field)
	defer narrative.destroy_contextual_selection_explanation(&distrustful)
	assert(distrustful.error == .None && distrustful.selected_beat_id == "distrustful")
	assert(distrustful.beats[0].eligible && distrustful.beats[0].selected)

	state := narrative.new_state(&compiled.program)
	runtime_error, query_error := narrative.advance(&compiled.program, &state, user_data, narrative_test_field, nil)
	assert(runtime_error == .None && query_error == .None)
	assert(state.cursor.scene_id == "reply.distrustful")
	assert(state.cursor.anchor_id == "ask")
}

@(test)
narrative_contextual_selection_requires_a_fallback_and_valid_targets :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: start
@select response priority
  @beat matched priority 1 if page_found -> missing.target
@endselect

:: unused
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(has_diagnostic(&compiled, .Missing_Selection_Fallback))
	assert(has_diagnostic(&compiled, .Unknown_Target))
}

@(test)
narrative_program_owns_registry_text_used_at_runtime :: proc(t: ^testing.T) {
	_ = t
	field_name_bytes := make([]u8, len("page_found"), context.allocator)
	copy(field_name_bytes, "page_found")
	field_name := string(field_name_bytes)
	fields := [1]narrative.Field_Definition{{id = field_name, type = .Boolean}}
	registry := narrative.Registry{speakers = NARRATIVE_TEST_SPEAKERS[:], fields = fields[:], actions = NARRATIVE_TEST_ACTIONS[:1]}
	compiled := narrative.compile(`:: start
@if page_found
Narrator: yes
@endif
@end
`, registry)
	defer narrative.destroy_compilation(&compiled)
	delete(field_name_bytes)
	assert(!narrative.has_errors(&compiled))
	assert(compiled.program.query_fields[0].id == "page_found")
	assert(compiled.program.query_nodes[0].field_id == "page_found")
	context_value := Narrative_Test_Context{page_found = true}
	state := narrative.new_state(&compiled.program)
	runtime_error, query_error := narrative.advance(&compiled.program, &state, cast(rawptr)&context_value, narrative_test_field, nil)
	assert(runtime_error == .None && query_error == .None)
	node, ok := narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "yes")
}

@(test)
narrative_program_identity_changes_with_source_or_version :: proc(t: ^testing.T) {
	_ = t
	metadata := narrative.Program_Metadata{id = "identity-test.chapter_01", version = 1}
	first := narrative.compile(`:: start
@anchor start "Start" start
Narrator: First line.
@end
`, narrative_test_registry(), metadata)
	defer narrative.destroy_compilation(&first)
	same := narrative.compile(`:: start
@anchor start "Start" start
Narrator: First line.
@end
`, narrative_test_registry(), metadata)
	defer narrative.destroy_compilation(&same)
	edited := narrative.compile(`:: start
@anchor start "Start" start
Narrator: An edited first line.
@end
`, narrative_test_registry(), metadata)
	defer narrative.destroy_compilation(&edited)
	new_version := narrative.compile(`:: start
@anchor start "Start" start
Narrator: First line.
@end
`, narrative_test_registry(), narrative.Program_Metadata{id = metadata.id, version = 2})
	defer narrative.destroy_compilation(&new_version)
	assert(first.program.identity.identity_hash == same.program.identity.identity_hash)
	assert(first.program.identity.identity_hash != edited.program.identity.identity_hash)
	assert(first.program.identity.identity_hash != new_version.program.identity.identity_hash)
}

@(test)
narrative_opaque_predicates_stay_typed_and_keep_declared_dependencies :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: start
@if opaque:can_smell_trap
Narrator: The smell is familiar.
@endif
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	assert(compiled.program.query_nodes[0].operator == .Opaque_Field)
	assert(compiled.program.query_nodes[0].field_id == "can_smell_trap")
	assert(compiled.program.query_fields[3].reads[0] == "page_found")
	context_value := Narrative_Test_Context{page_found = true}
	state := narrative.new_state(&compiled.program)
	runtime_error, query_error := narrative.advance(&compiled.program, &state, cast(rawptr)&context_value, narrative_test_field, nil)
	assert(runtime_error == .None && query_error == .None)
	node, ok := narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "The smell is familiar.")
}

@(test)
narrative_compiler_rejects_unknown_fields_and_type_mismatches :: proc(t: ^testing.T) {
	_ = t
	unknown_field := `:: start
@if page.missing
Narrator: unreachable
@endif
@end
`
	compiled := narrative.compile(unknown_field, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(narrative.has_errors(&compiled))
	assert(has_diagnostic(&compiled, .Unknown_Field))
	type_mismatch := `:: start
@if bond and page_found
Narrator: impossible
@endif
@end
`
	assert(narrative_test_compile_errors(type_mismatch))
}

@(test)
narrative_runtime_returns_query_failures_instead_of_false :: proc(t: ^testing.T) {
	_ = t
	source := `:: start
@if page_found
Narrator: yes
@endif
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	runtime_error, query_error := narrative.advance(&compiled.program, &state, nil, nil, nil)
	assert(runtime_error == .Query_Evaluation_Failed)
	assert(query_error == .Resolver_Failed)
}

@(test)
narrative_runtime_rejects_enum_values_outside_the_registered_schema :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: start
@if location == archive
Narrator: Here.
@endif
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	runtime_error, query_error := narrative.advance(&compiled.program, &state, nil, narrative_test_wrong_enum_field, nil)
	assert(runtime_error == .Query_Evaluation_Failed)
	assert(query_error == .Type_Mismatch)
}

@(test)
narrative_submit_rechecks_the_same_choice_and_routes_action_outcomes :: proc(t: ^testing.T) {
	_ = t
	source := `:: introduction
@anchor start "Start" start
? What should Rafael do?
  - Ask about the page
    @anchor ask "Ask about the page" choice
    @attempt ask_about_page
    -> accepted#accepted
    @on refused -> refused#refused
  @if page_found
  - Continue the conversation
    @anchor continue "Continue" choice
    @attempt continue_story
    -> accepted#accepted
  @endif

:: accepted
@anchor accepted "Accepted" outcome
Narrator: accepted
@end

:: refused
@anchor refused "Refused" outcome
Narrator: refused
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	test_context := Narrative_Test_Context{page_found = true, refuse_action = true}
	user_data := cast(rawptr)&test_context
	assert(narrative_test_advance(&compiled.program, &state, user_data))
	visible_index, found, query_error := narrative.visible_choice(&compiled.program, &state, 1, user_data, narrative_test_field)
	assert(found && query_error == .None)
	stale_offer, stale_offer_ok := narrative.choice_id(&compiled.program, visible_index)
	assert(stale_offer_ok)
	test_context.page_found = false
	stale := narrative.submit_choice(&compiled.program, &state, stale_offer, user_data, narrative_test_field, narrative_test_action)
	assert(stale.error == .Ineligible_Choice)
	assert(test_context.actions_applied == 0)
	refusal_offer, refusal_offer_ok := narrative.choice_id(&compiled.program, 0)
	assert(refusal_offer_ok)
	refusal := narrative.submit_choice(&compiled.program, &state, refusal_offer, user_data, narrative_test_field, narrative_test_action)
	assert(refusal.error == .None && refusal.outcome == .Refused)
	assert(state.cursor.scene_id == "refused")
	assert(test_context.actions_applied == 1)
	assert(narrative_test_advance(&compiled.program, &state, user_data))
	node, ok := narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "refused")
}

@(test)
narrative_submit_rejects_invalid_actions_without_advancing :: proc(t: ^testing.T) {
	_ = t
	source := `:: start
? Choose
  - Continue
    @attempt continue_story
    -> done

:: done
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	test_context := Narrative_Test_Context{reject_action = true}
	user_data := cast(rawptr)&test_context
	assert(narrative_test_advance(&compiled.program, &state, user_data))
	offer, found := narrative.choice_id(&compiled.program, 0)
	assert(found)
	before := state.cursor
	submission := narrative.submit_choice(&compiled.program, &state, offer, user_data, narrative_test_field, narrative_test_action)
	assert(submission.error == .Action_Rejected)
	assert(state.cursor == before)
	assert(test_context.actions_applied == 0)
}

@(test)
narrative_submit_rejects_an_implicit_action_outcome :: proc(t: ^testing.T) {
	_ = t
	source := `:: start
? Choose
  - Continue
    @attempt continue_story
    -> done

:: done
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	test_context := Narrative_Test_Context{}
	user_data := cast(rawptr)&test_context
	assert(narrative_test_advance(&compiled.program, &state, user_data))
	offer, found := narrative.choice_id(&compiled.program, 0)
	assert(found)
	before := state.cursor
	submission := narrative.submit_choice(&compiled.program, &state, offer, user_data, narrative_test_field, narrative_test_missing_outcome)
	assert(submission.error == .Action_Contract_Violation)
	assert(state.cursor == before)
	assert(test_context.actions_applied == 0)
}

@(test)
narrative_compiler_requires_routes_for_declared_refusal_and_interruption :: proc(t: ^testing.T) {
	_ = t
	missing_refusal := `:: start
? Choose
  - Ask
    @attempt ask_about_page
    -> done

:: done
@end
`
	compiled := narrative.compile(missing_refusal, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(has_diagnostic(&compiled, .Missing_Outcome_Route))
	interrupted := `:: start
? Choose
  - Talk
    @attempt talk_to_masha
    -> done
    @on interrupted -> done

:: done
@end
`
	compiled_interrupted := narrative.compile(interrupted, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled_interrupted)
	assert(!narrative.has_errors(&compiled_interrupted))
}

@(test)
narrative_compiler_builds_grapheme_indexed_rich_text_and_cues :: proc(t: ^testing.T) {
	_ = t
	source := `:: opening
@line opening.greeting
Narrator: [pause=50ms][speed=24][sfx=page_turn]Café [pause=180ms][b]bold [i]nested[/i][/b] ending[/speed]
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	assert(len(compiled.program.nodes) == 2)
	node := compiled.program.nodes[0]
	assert(node.line_id == "opening.greeting")
	assert(node.text == "Café bold nested ending")
	assert(node.text_span_count == 2)
	spans := compiled.program.text_spans[node.text_span_start:node.text_span_start+node.text_span_count]
	// Outer spans precede their nested spans, and offsets count the decomposed
	// e + combining mark as one user-visible grapheme.
	assert(spans[0].style == .Bold && spans[0].start == 5 && spans[0].end == 16 && spans[0].depth == 0)
	assert(spans[1].style == .Italic && spans[1].start == 10 && spans[1].end == 16 && spans[1].depth == 1)
	assert(node.presentation_cue_count == 5)
	cues := compiled.program.presentation_cues[node.presentation_cue_start:node.presentation_cue_start+node.presentation_cue_count]
	assert(cues[0].kind == .Pause && cues[0].position == 0 && cues[0].duration_ms == 50)
	assert(cues[1].kind == .Speed && cues[1].position == 0 && cues[1].speed == 24)
	assert(cues[2].kind == .Sound_Effect && cues[2].position == 0 && cues[2].value == "page_turn")
	assert(cues[3].kind == .Pause && cues[3].position == 5 && cues[3].duration_ms == 180)
	assert(cues[4].kind == .Speed && cues[4].position == 23 && cues[4].speed == 0)
}

@(test)
narrative_compiler_preserves_explicit_line_ids_across_prose_edits :: proc(t: ^testing.T) {
	_ = t
	first := narrative.compile(`:: opening
@line opening.answer
Narrator: The first wording.
Narrator: An unlabelled line.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&first)
	second := narrative.compile(`:: opening
@line opening.answer
Narrator: A much longer replacement sentence, with different words.
Narrator: An unlabelled line.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&second)
	assert(!narrative.has_errors(&first) && !narrative.has_errors(&second))
	assert(first.program.nodes[0].line_id == second.program.nodes[0].line_id)
	assert(first.program.nodes[0].line_id == "opening.answer")
	assert(first.program.nodes[1].line_id == "" && second.program.nodes[1].line_id == "")
	duplicate := narrative.compile(`:: opening
@line repeated
Narrator: First.
@line repeated
Narrator: Second.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&duplicate)
	assert(has_diagnostic(&duplicate, .Duplicate_Line_ID))
}

@(test)
narrative_compiler_reports_malformed_rich_text_with_source_location :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: opening
Narrator: A malformed [/i] tag.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(narrative.has_errors(&compiled))
	found_location := false
	for diagnostic in compiled.diagnostics {
		if diagnostic.code == .Malformed_Rich_Text && diagnostic.line == 2 && diagnostic.column > 1 {
			found_location = true
		}
	}
	assert(found_location)
	valid_bad_tag := narrative.compile(`:: opening
Narrator: [mystery] tag.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&valid_bad_tag)
	assert(has_diagnostic(&valid_bad_tag, .Malformed_Rich_Text))
	invalid_opacity := narrative.compile(`:: opening
Narrator: [opacity=101]Too opaque.[/opacity]
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&invalid_opacity)
	assert(has_diagnostic(&invalid_opacity, .Malformed_Rich_Text))
}

@(test)
narrative_compiler_preserves_typed_opacity_spans :: proc(t: ^testing.T) {
	_ = t
	compiled := narrative.compile(`:: opening
Narrator: Before [opacity=65][i]a softer phrase[/i][/opacity] after.
@end
`, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	node := compiled.program.nodes[0]
	assert(node.text == "Before a softer phrase after.")
	spans := compiled.program.text_spans[node.text_span_start:node.text_span_start+node.text_span_count]
	assert(len(spans) == 2)
	assert(spans[0].style == .Opacity && spans[0].start == 7 && spans[0].end == 22)
	assert(spans[0].opacity_percent == 65)
	assert(spans[1].style == .Italic && spans[1].opacity_percent == 100)
}

has_diagnostic :: proc(compiled: ^narrative.Compilation, code: narrative.Diagnostic_Code) -> bool {
	for diagnostic in compiled.diagnostics {
		if diagnostic.code == code { return true }
	}
	return false
}
