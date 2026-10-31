package tests

import "core:testing"
import narrative "rugops:narrative"

NARRATIVE_TEST_SPEAKERS: [1]string = {"Narrator"}
NARRATIVE_TEST_ACTIONS: [1]string = {"continue_story"}
NARRATIVE_TEST_CONDITIONS: [1]string = {"page_found"}

Narrative_Test_Context :: struct {
	page_found:  bool,
	scene_count: u32,
	anchor_count: u32,
	checkpoint_count: u32,
}

narrative_test_registry :: proc() -> narrative.Registry {
	return narrative.Registry{
		speakers = NARRATIVE_TEST_SPEAKERS[:],
		actions = NARRATIVE_TEST_ACTIONS[:],
		conditions = NARRATIVE_TEST_CONDITIONS[:],
	}
}

narrative_test_query :: proc(user_data: rawptr, condition: string) -> bool {
	test_context := cast(^Narrative_Test_Context)user_data
	if condition == "page_found" { return test_context.page_found }
	return false
}

narrative_test_event :: proc(user_data: rawptr, event: narrative.Runtime_Event) {
	test_context := cast(^Narrative_Test_Context)user_data
	switch event.kind {
	case .Scene_Entered:
		test_context.scene_count += 1
	case .Anchor_Reached:
		test_context.anchor_count += 1
		if event.checkpoint { test_context.checkpoint_count += 1 }
	}
}

@(test)
narrative_runtime_executes_authored_control_flow_with_game_queries :: proc(t: ^testing.T) {
	_ = t
	source := `:: introduction
@anchor introduction "Introduction" start
Narrator: Masha mentioned the archive.
@if page_found
Narrator: She found the folded page.
@else
Narrator: The page is still missing.
@endif
@anchor afternoon_plan "Afternoon plans" choice checkpoint
? What should Rafael do?
  - Continue
    @intent continue_story
    -> ending#finished

:: ending
@anchor finished "Finished" outcome
Narrator: The scene is over.
@end
`
	compiled := narrative.compile(source, narrative_test_registry())
	defer narrative.destroy_compilation(&compiled)
	assert(!narrative.has_errors(&compiled))
	state := narrative.new_state(&compiled.program)
	test_context := Narrative_Test_Context{page_found = true}
	user_data := cast(rawptr)&test_context
	assert(narrative.advance(&compiled.program, &state, user_data, narrative_test_query, narrative_test_event) == .None)
	node, ok := narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.kind == .Dialogue)
	assert(node.text == "Masha mentioned the archive.")
	assert(test_context.scene_count == 1)
	assert(test_context.anchor_count == 1)
	assert(narrative.continue_dialogue(&compiled.program, &state) == .None)
	assert(narrative.advance(&compiled.program, &state, user_data, narrative_test_query, narrative_test_event) == .None)
	node, ok = narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "She found the folded page.")
	assert(narrative.continue_dialogue(&compiled.program, &state) == .None)
	assert(narrative.advance(&compiled.program, &state, user_data, narrative_test_query, narrative_test_event) == .None)
	node, ok = narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.kind == .Choice_Group)
	assert(state.cursor.anchor_id == "afternoon_plan")
	assert(test_context.checkpoint_count == 1)
	choice_index, choice_found := narrative.visible_choice(&compiled.program, &state, 0, user_data, narrative_test_query)
	assert(choice_found)
	choice := compiled.program.choices[choice_index]
	assert(choice.action == "continue_story")
	choice_cursor, target_found := narrative.choice_target(&compiled.program, choice_index)
	assert(target_found)
	assert(choice_cursor.scene_id == "ending")
	assert(narrative.commit_choice(&compiled.program, &state, choice_index) == .None)
	assert(narrative.advance(&compiled.program, &state, user_data, narrative_test_query, narrative_test_event) == .None)
	node, ok = narrative.node_at(&compiled.program, state.cursor)
	assert(ok && node.text == "The scene is over.")
	assert(test_context.scene_count == 2)
}

@(test)
narrative_runtime_rejects_continue_at_choices_and_invalid_visible_options :: proc(t: ^testing.T) {
	_ = t
	source := `:: start
? Choose
  - Finish
    @intent continue_story
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
	assert(narrative.advance(&compiled.program, &state, user_data, narrative_test_query, narrative_test_event) == .None)
	assert(narrative.continue_dialogue(&compiled.program, &state) == .Not_Dialogue)
	_, found := narrative.visible_choice(&compiled.program, &state, 1, user_data, narrative_test_query)
	assert(!found)
}
