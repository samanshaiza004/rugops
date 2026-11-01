package rugops_core

// Explore_Command is a game-defined command token. The explorer does not
// interpret its kind or argument; it preserves them in a replayable witness.
Explore_Command :: struct {
	kind:     u32,
	argument: i64,
}

Explore_Status :: enum u8 {
	Failed,
	Reachable,
	Exhaustively_Unreachable,
	Not_Found_Within_Budget,
}

Explore_Limit :: enum u8 {
	None,
	Open_State_Space,
	Max_Expanded_States,
	Max_Discovered_States,
	Max_Depth,
}

Explore_Error :: enum u8 {
	None,
	Invalid_Request,
	Clone_Failed,
	Command_Enumeration_Failed,
	Command_Application_Failed,
}

Explore_Limits :: struct {
	max_expanded_states:   u64,
	max_discovered_states: u64,
	max_depth:             u32,
	closed_finite:         bool,
}

Explore_State_Clone :: #type proc(user_data: rawptr, state: rawptr) -> rawptr
Explore_State_Destroy :: #type proc(user_data: rawptr, state: rawptr)
Explore_State_Hash :: #type proc(user_data: rawptr, state: rawptr) -> u64
Explore_States_Equal :: #type proc(user_data: rawptr, a, b: rawptr) -> bool
Explore_Goal :: #type proc(user_data: rawptr, state: rawptr) -> bool
Explore_Command_Enumerator :: #type proc(
	user_data: rawptr,
	state: rawptr,
	commands: ^[dynamic]Explore_Command,
) -> bool
Explore_Command_Apply :: #type proc(user_data: rawptr, state: rawptr, command: Explore_Command) -> bool

// Explore_Request is an adapter for one game's state and command model.
// Callbacks must be deterministic. enumerate_commands must emit every legal
// command once, in a stable order. apply_command mutates only its cloned state
// and must accept every enumerated command; a false result fails the search.
// states_equal must compare all fields that can affect future transitions or
// the goal; logs and witness history should be excluded unless game rules read
// them as state.
Explore_Request :: struct {
	user_data:         rawptr,
	initial_state:    rawptr,
	clone_state:      Explore_State_Clone,
	destroy_state:    Explore_State_Destroy,
	state_hash:       Explore_State_Hash,
	states_equal:     Explore_States_Equal,
	is_goal:          Explore_Goal,
	enumerate_commands: Explore_Command_Enumerator,
	apply_command:    Explore_Command_Apply,
	limits:           Explore_Limits,
}

Explore_Result :: struct {
	status:               Explore_Status,
	error:                Explore_Error,
	limit:                Explore_Limit,
	frontier_exhausted:   bool,
	states_discovered:    u64,
	states_expanded:      u64,
	duplicate_states:     u64,
	commands_considered:  u64,
	max_depth_reached:    u32,
	command_coverage:     [dynamic]Explore_Command,
	witness:              [dynamic]Explore_Command,
}

Explore_Search_Node :: struct {
	state:   rawptr,
	hash:    u64,
	parent:  int,
	command: Explore_Command,
	depth:   u32,
}

// explore runs deterministic breadth-first search. The initial state is
// borrowed; every explored state is cloned and destroyed through the adapter.
// State hashes only narrow equality checks: matching hashes are always
// confirmed with states_equal. A witness contains commands from the initial
// state to the first goal found, with shortest length and stable command-order
// tie-breaking. For safety checks, is_goal can mean "this state violates the
// property"; a reachable result is then a replayable counterexample. Set
// closed_finite only when command enumeration is complete and the reachable
// future-relevant state space is known to be finite.
explore :: proc(request: Explore_Request) -> Explore_Result {
	result := Explore_Result{status = .Failed}
	if request.initial_state == nil || request.clone_state == nil || request.destroy_state == nil ||
		request.state_hash == nil || request.states_equal == nil || request.is_goal == nil ||
		request.enumerate_commands == nil || request.apply_command == nil ||
		request.limits.max_discovered_states == 0 {
		result.error = .Invalid_Request
		return result
	}

	root := request.clone_state(request.user_data, request.initial_state)
	if root == nil {
		result.error = .Clone_Failed
		return result
	}

	nodes: [dynamic]Explore_Search_Node
	append(&nodes, Explore_Search_Node{state = root, hash = request.state_hash(request.user_data, root), parent = -1})
	result.states_discovered = 1

	if request.is_goal(request.user_data, root) {
		result.status = .Reachable
		destroy_explore_nodes(request, nodes[:])
		delete(nodes)
		return result
	}

	next_node := 0
	depth_cutoff := false
	goal_found := false
	stop_for_state_limit := false
	for next_node < len(nodes) {
		if result.states_expanded >= request.limits.max_expanded_states {
			result.limit = .Max_Expanded_States
			break
		}

		node := nodes[next_node]
		commands: [dynamic]Explore_Command
		if !request.enumerate_commands(request.user_data, node.state, &commands) {
			delete(commands)
			result.error = .Command_Enumeration_Failed
			break
		}
		for command in commands { record_explore_command(&result.command_coverage, command) }

		if node.depth >= request.limits.max_depth && len(commands) > 0 {
			depth_cutoff = true
		} else {
			for command in commands {
				result.commands_considered += 1
				candidate := request.clone_state(request.user_data, node.state)
				if candidate == nil {
					result.error = .Clone_Failed
					break
				}
				if !request.apply_command(request.user_data, candidate, command) {
					request.destroy_state(request.user_data, candidate)
					result.error = .Command_Application_Failed
					break
				}

				candidate_hash := request.state_hash(request.user_data, candidate)
				duplicate := false
				for visited in nodes {
					if visited.hash == candidate_hash && request.states_equal(request.user_data, visited.state, candidate) {
						duplicate = true
						break
					}
				}
				if duplicate {
					result.duplicate_states += 1
					request.destroy_state(request.user_data, candidate)
					continue
				}

				if u64(len(nodes)) >= request.limits.max_discovered_states {
					request.destroy_state(request.user_data, candidate)
					result.limit = .Max_Discovered_States
					stop_for_state_limit = true
					break
				}

				candidate_index := len(nodes)
				candidate_depth := node.depth + 1
				append(&nodes, Explore_Search_Node{
					state = candidate,
					hash = candidate_hash,
					parent = next_node,
					command = command,
					depth = candidate_depth,
				})
				result.states_discovered += 1
				result.max_depth_reached = max(result.max_depth_reached, candidate_depth)
				if request.is_goal(request.user_data, candidate) {
					append_explore_witness(&result.witness, nodes[:], candidate_index)
					goal_found = true
					break
				}
			}
		}
		delete(commands)
		result.states_expanded += 1
		next_node += 1
		if result.error != .None || goal_found || stop_for_state_limit { break }
	}

	if result.error != .None {
		result.status = .Failed
	} else if goal_found {
		result.status = .Reachable
	} else {
		fully_expanded := next_node >= len(nodes) && result.limit == .None && !depth_cutoff
		result.frontier_exhausted = fully_expanded
		if fully_expanded && request.limits.closed_finite {
			result.status = .Exhaustively_Unreachable
		} else {
			result.status = .Not_Found_Within_Budget
			if result.limit == .None {
				if depth_cutoff {
					result.limit = .Max_Depth
				} else {
					result.limit = .Open_State_Space
				}
			}
		}
	}

	destroy_explore_nodes(request, nodes[:])
	delete(nodes)
	return result
}

destroy_explore_result :: proc(result: ^Explore_Result) {
	delete(result.command_coverage)
	delete(result.witness)
	result^ = {}
}

record_explore_command :: proc(coverage: ^[dynamic]Explore_Command, candidate: Explore_Command) {
	for command in coverage^ {
		if command == candidate { return }
	}
	append(coverage, candidate)
}

destroy_explore_nodes :: proc(request: Explore_Request, nodes: []Explore_Search_Node) {
	for node in nodes { request.destroy_state(request.user_data, node.state) }
}

append_explore_witness :: proc(witness: ^[dynamic]Explore_Command, nodes: []Explore_Search_Node, goal_index: int) {
	reversed: [dynamic]Explore_Command
	index := goal_index
	for nodes[index].parent >= 0 {
		append(&reversed, nodes[index].command)
		index = nodes[index].parent
	}
	for i := len(reversed)-1; i >= 0; i -= 1 { append(witness, reversed[i]) }
	delete(reversed)
}
