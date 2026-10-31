package narrative

Query_Evaluation :: struct {
	value:       Query_Value,
	error:       Query_Error,
	failed_field: string,
}

evaluate_condition :: proc(
	program: ^Program,
	expression_index: int,
	user_data: rawptr,
	resolve_field: Field_Resolver,
) -> Query_Evaluation {
	if program == nil || expression_index < 0 || expression_index >= len(program.queries) {
		return Query_Evaluation{error = .Invalid_Expression}
	}
	query := program.queries[expression_index]
	result := evaluate_query_node(program, query.root, user_data, resolve_field, nil)
	if result.error != .None { return result }
	if result.value.type != .Boolean { return Query_Evaluation{error = .Type_Mismatch} }
	return result
}

explain_query :: proc(
	program: ^Program,
	expression_index: int,
	user_data: rawptr,
	resolve_field: Field_Resolver,
) -> (explanation: Query_Explanation) {
	if program == nil || expression_index < 0 || expression_index >= len(program.queries) {
		return Query_Explanation{error = .Invalid_Expression}
	}
	query := program.queries[expression_index]
	explanation.expression = query.source
	result := evaluate_query_node(program, query.root, user_data, resolve_field, &explanation)
	if result.error != .None {
		explanation.error = result.error
		explanation.failed_field = result.failed_field
		return
	}
	if result.value.type != .Boolean {
		explanation.error = .Type_Mismatch
		return
	}
	explanation.value = result.value.boolean
	return
}

destroy_query_explanation :: proc(explanation: ^Query_Explanation) {
	delete(explanation.steps)
	explanation^ = {}
}

evaluate_query_node :: proc(
	program: ^Program,
	index: int,
	user_data: rawptr,
	resolve_field: Field_Resolver,
	explanation: ^Query_Explanation,
) -> Query_Evaluation {
	if index < 0 || index >= len(program.query_nodes) { return Query_Evaluation{error = .Invalid_Expression} }
	node := program.query_nodes[index]
	result := Query_Evaluation{}
	switch node.operator {
	case .Field, .Opaque_Field:
		if resolve_field == nil {
			result.error = .Resolver_Failed
			result.failed_field = node.field_id
		} else {
			result.value, result.error = resolve_field(user_data, node.field_id)
			if result.error == .None && result.value.type != node.type { result.error = .Type_Mismatch }
			if result.error == .None && node.type == .Enumeration {
				if result.value.enum_type != node.enum_type || !query_enum_value_registered(program, node.field_id, result.value.enum_value) {
					result.error = .Type_Mismatch
				}
			}
			if result.error != .None { result.failed_field = node.field_id }
		}
	case .Boolean_Literal:
		result.value = Query_Value{type = .Boolean, boolean = node.boolean}
	case .Integer_Literal:
		result.value = Query_Value{type = .Integer, integer = node.integer}
	case .Enumeration_Literal:
		result.value = Query_Value{type = .Enumeration, enum_type = node.enum_type, enum_value = node.enum_value}
	case .Not:
		left := evaluate_query_node(program, node.left, user_data, resolve_field, explanation)
		if left.error != .None { result = left } else if left.value.type != .Boolean {
			result.error = .Type_Mismatch
		} else {
			result.value = Query_Value{type = .Boolean, boolean = !left.value.boolean}
		}
	case .And, .Or:
		left := evaluate_query_node(program, node.left, user_data, resolve_field, explanation)
		if left.error != .None {
			result = left
			append_skipped_query_subtree(program, node.right, explanation)
		} else if left.value.type != .Boolean {
			result.error = .Type_Mismatch
			append_skipped_query_subtree(program, node.right, explanation)
		} else if node.operator == .And && !left.value.boolean {
			result.value = Query_Value{type = .Boolean, boolean = false}
			append_skipped_query_subtree(program, node.right, explanation)
		} else if node.operator == .Or && left.value.boolean {
			result.value = Query_Value{type = .Boolean, boolean = true}
			append_skipped_query_subtree(program, node.right, explanation)
		} else {
			right := evaluate_query_node(program, node.right, user_data, resolve_field, explanation)
			if right.error != .None { result = right } else if right.value.type != .Boolean {
				result.error = .Type_Mismatch
			} else {
				result.value = right.value
			}
		}
	case .Equal, .Not_Equal, .Less, .Less_Equal, .Greater, .Greater_Equal:
		left := evaluate_query_node(program, node.left, user_data, resolve_field, explanation)
		right := evaluate_query_node(program, node.right, user_data, resolve_field, explanation)
		if left.error != .None { result = left } else if right.error != .None { result = right } else {
			compared, valid := compare_query_values(left.value, right.value, node.operator)
			if !valid { result.error = .Type_Mismatch } else { result.value = Query_Value{type = .Boolean, boolean = compared} }
		}
	case:
		result.error = .Invalid_Expression
	}
	if explanation != nil {
		append(&explanation.steps, Query_Evaluation_Step{
			node_index = index,
			operator = node.operator,
			field_id = node.field_id,
			failed_field = result.failed_field,
			value = result.value,
			error = result.error,
		})
	}
	return result
}

append_skipped_query_subtree :: proc(program: ^Program, index: int, explanation: ^Query_Explanation) {
	if explanation == nil || index < 0 || index >= len(program.query_nodes) { return }
	node := program.query_nodes[index]
	append(&explanation.steps, Query_Evaluation_Step{
		node_index = index,
		operator = node.operator,
		field_id = node.field_id,
		skipped = true,
	})
	switch node.operator {
	case .Not:
		append_skipped_query_subtree(program, node.left, explanation)
	case .And, .Or, .Equal, .Not_Equal, .Less, .Less_Equal, .Greater, .Greater_Equal:
		append_skipped_query_subtree(program, node.left, explanation)
		append_skipped_query_subtree(program, node.right, explanation)
	case .Field, .Opaque_Field, .Boolean_Literal, .Integer_Literal, .Enumeration_Literal:
	}
}

query_enum_value_registered :: proc(program: ^Program, field_id, enum_value: string) -> bool {
	for field in program.query_fields {
		if field.id != field_id { continue }
		for value in field.enum_values {
			if value == enum_value { return true }
		}
		return false
	}
	return false
}

compare_query_values :: proc(left, right: Query_Value, operator: Query_Operator) -> (result: bool, ok: bool) {
	if left.type != right.type { return false, false }
	comparison := 0
	switch left.type {
	case .Boolean:
		if left.boolean == right.boolean { comparison = 0 } else if !left.boolean { comparison = -1 } else { comparison = 1 }
	case .Integer:
		if left.integer < right.integer { comparison = -1 } else if left.integer > right.integer { comparison = 1 }
	case .Enumeration:
		if left.enum_type != right.enum_type { return false, false }
		if left.enum_value == right.enum_value { comparison = 0 } else if left.enum_value < right.enum_value { comparison = -1 } else { comparison = 1 }
	case .Invalid:
		return false, false
	case:
		return false, false
	}
	switch operator {
	case .Equal: return comparison == 0, true
	case .Not_Equal: return comparison != 0, true
	case .Less: return comparison < 0, true
	case .Less_Equal: return comparison <= 0, true
	case .Greater: return comparison > 0, true
	case .Greater_Equal: return comparison >= 0, true
	case .Field, .Opaque_Field, .Boolean_Literal, .Integer_Literal, .Enumeration_Literal, .Not, .And, .Or:
		return false, false
	case:
		return false, false
	}
	return false, false
}
