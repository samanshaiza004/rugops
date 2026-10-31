package tests

import "core:testing"
import core "rugops:core"

Explore_Test_State :: struct {
	node: u32,
}

Explore_Test_Context :: struct {
	goal:          u32,
	cycle_graph:   bool,
	constant_hash: bool,
	fail_enumeration: bool,
	fail_application: bool,
	clones:        u32,
	destroys:      u32,
}

explore_test_clone :: proc(user_data: rawptr, source: rawptr) -> rawptr {
	ctx := cast(^Explore_Test_Context)user_data
	ctx.clones += 1
	copy := new(Explore_Test_State)
	source_state := cast(^Explore_Test_State)source
	copy^ = source_state^
	return cast(rawptr)copy
}

explore_test_destroy :: proc(user_data: rawptr, state: rawptr) {
	ctx := cast(^Explore_Test_Context)user_data
	ctx.destroys += 1
	free(cast(^Explore_Test_State)state)
}

explore_test_hash :: proc(user_data: rawptr, state: rawptr) -> u64 {
	ctx := cast(^Explore_Test_Context)user_data
	if ctx.constant_hash { return 1 }
	state_ptr := cast(^Explore_Test_State)state
	return u64(state_ptr.node)
}

explore_test_equal :: proc(user_data: rawptr, a, b: rawptr) -> bool {
	_ = user_data
	a_state := cast(^Explore_Test_State)a
	b_state := cast(^Explore_Test_State)b
	return a_state^ == b_state^
}

explore_test_goal :: proc(user_data: rawptr, state: rawptr) -> bool {
	ctx := cast(^Explore_Test_Context)user_data
	state_ptr := cast(^Explore_Test_State)state
	return state_ptr.node == ctx.goal
}

explore_test_commands :: proc(user_data: rawptr, state: rawptr, commands: ^[dynamic]core.Explore_Command) -> bool {
	ctx := cast(^Explore_Test_Context)user_data
	if ctx.fail_enumeration { return false }
	state_ptr := cast(^Explore_Test_State)state
	node := state_ptr.node
	if ctx.cycle_graph {
		switch node {
		case 0: append(commands, core.Explore_Command{kind = 1, argument = 1})
		case 1: append(commands, core.Explore_Command{kind = 1, argument = 0})
		}
		return true
	}
	switch node {
	case 0:
		append(commands, core.Explore_Command{kind = 1, argument = 1})
		append(commands, core.Explore_Command{kind = 1, argument = 2})
	case 1, 2:
		append(commands, core.Explore_Command{kind = 1, argument = 3})
	case 3:
		append(commands, core.Explore_Command{kind = 1, argument = 4})
	}
	return true
}

explore_test_apply :: proc(user_data: rawptr, state: rawptr, command: core.Explore_Command) -> bool {
	ctx := cast(^Explore_Test_Context)user_data
	state_ptr := cast(^Explore_Test_State)state
	if ctx.fail_application { return false }
	if command.kind != 1 { return false }
	if ctx.cycle_graph {
		if (state_ptr.node == 0 && command.argument == 1) || (state_ptr.node == 1 && command.argument == 0) {
			state_ptr.node = u32(command.argument)
			return true
		}
		return false
	}
	legal := (state_ptr.node == 0 && (command.argument == 1 || command.argument == 2)) ||
		((state_ptr.node == 1 || state_ptr.node == 2) && command.argument == 3) ||
		(state_ptr.node == 3 && command.argument == 4)
	if !legal { return false }
	state_ptr.node = u32(command.argument)
	return true
}

@(test)
explorer_reports_adapter_errors_instead_of_claiming_unreachable :: proc(t: ^testing.T) {
	initial := Explore_Test_State{}
	enumeration := Explore_Test_Context{goal = 4, fail_enumeration = true}
	enumeration_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&enumeration,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&enumeration_result)
	assert(enumeration_result.status == .Failed)
	assert(enumeration_result.error == .Command_Enumeration_Failed)
	assert(enumeration.clones == enumeration.destroys)

	application := Explore_Test_Context{goal = 4, fail_application = true}
	application_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&application,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&application_result)
	assert(application_result.status == .Failed)
	assert(application_result.error == .Command_Application_Failed)
	assert(application.clones == application.destroys)
	_ = t
}

@(test)
explorer_breadth_first_returns_shortest_witness_and_verifies_hash_collisions :: proc(t: ^testing.T) {
	context_value := Explore_Test_Context{goal = 4, constant_hash = true}
	initial := Explore_Test_State{}
	result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&context_value,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&result)
	assert(result.status == .Reachable)
	assert(result.error == .None)
	assert(len(result.witness) == 3)
	assert(result.witness[0].argument == 1)
	assert(result.witness[1].argument == 3)
	assert(result.witness[2].argument == 4)
	assert(result.states_discovered == 5)
	assert(result.duplicate_states == 1)
	assert(len(result.command_coverage) == 4)
	assert(result.command_coverage[0].argument == 1)
	assert(context_value.clones == context_value.destroys)
}

@(test)
explorer_distinguishes_closed_unreachable_open_and_budget_limited_searches :: proc(t: ^testing.T) {
	initial := Explore_Test_State{}
	closed := Explore_Test_Context{goal = 2, cycle_graph = true}
	closed_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&closed,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&closed_result)
	assert(closed_result.status == .Exhaustively_Unreachable)
	assert(closed_result.frontier_exhausted)
	assert(closed_result.states_discovered == 2)

	open := Explore_Test_Context{goal = 2, cycle_graph = true}
	open_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&open,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 20, closed_finite = false},
	})
	defer core.destroy_explore_result(&open_result)
	assert(open_result.status == .Not_Found_Within_Budget)
	assert(open_result.frontier_exhausted)
	assert(open_result.limit == .Open_State_Space)

	bounded := Explore_Test_Context{goal = 4}
	bounded_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&bounded,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 100, max_depth = 0, closed_finite = true},
	})
	defer core.destroy_explore_result(&bounded_result)
	assert(bounded_result.status == .Not_Found_Within_Budget)
	assert(bounded_result.limit == .Max_Depth)
	assert(!bounded_result.frontier_exhausted)

	state_limited := Explore_Test_Context{goal = 4}
	state_limited_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&state_limited,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 100, max_discovered_states = 1, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&state_limited_result)
	assert(state_limited_result.status == .Not_Found_Within_Budget)
	assert(state_limited_result.limit == .Max_Discovered_States)
	assert(state_limited_result.states_discovered == 1 && !state_limited_result.frontier_exhausted)

	expansion_limited := Explore_Test_Context{goal = 4}
	expansion_limited_result := core.explore(core.Explore_Request{
		user_data = cast(rawptr)&expansion_limited,
		initial_state = cast(rawptr)&initial,
		clone_state = explore_test_clone,
		destroy_state = explore_test_destroy,
		state_hash = explore_test_hash,
		states_equal = explore_test_equal,
		is_goal = explore_test_goal,
		enumerate_commands = explore_test_commands,
		apply_command = explore_test_apply,
		limits = core.Explore_Limits{max_expanded_states = 1, max_discovered_states = 100, max_depth = 20, closed_finite = true},
	})
	defer core.destroy_explore_result(&expansion_limited_result)
	assert(expansion_limited_result.status == .Not_Found_Within_Budget)
	assert(expansion_limited_result.limit == .Max_Expanded_States)
	assert(expansion_limited_result.states_expanded == 1 && !expansion_limited_result.frontier_exhausted)
}
