package narrative

Query_Parser :: struct {
	source:      string,
	position:    int,
	line:        int,
	base_column: int,
	compilation: ^Compilation,
	registry:    Registry,
}

Parsed_Query :: struct {
	node:             int,
	type:             Query_Type,
	enum_type:        string,
	enum_values:      []string,
	field_id:         string,
	enum_value:       string,
	unresolved_name:  bool,
	valid:            bool,
}

compile_query :: proc(
	compilation: ^Compilation,
	registry: Registry,
	source: string,
	line: int,
	base_column: int,
) -> (query_index: int, ok: bool) {
	parser := Query_Parser{
		source = source,
		line = line,
		base_column = base_column,
		compilation = compilation,
		registry = registry,
	}
	parsed := parse_query_or(&parser)
	query_skip_space(&parser)
	if !parsed.valid { return -1, false }
	if parser.position < len(source) {
		query_diagnose(&parser, .Invalid_Query, "unexpected token")
		return -1, false
	}
	if parsed.unresolved_name {
		query_diagnose(&parser, .Unknown_Field, parsed.field_id)
		return -1, false
	}
	if parsed.type != .Boolean {
		query_diagnose(&parser, .Query_Type_Mismatch, source)
		return -1, false
	}
	index := len(compilation.program.queries)
	append(&compilation.program.queries, Query_Expression{source = source, root = parsed.node, line = line})
	return index, true
}

parse_query_or :: proc(parser: ^Query_Parser) -> Parsed_Query {
	left := parse_query_and(parser)
	for left.valid {
		if !query_consume_word(parser, "or") { break }
		right := parse_query_and(parser)
		if !right.valid { return right }
		if left.unresolved_name {
			query_diagnose(parser, .Unknown_Field, left.field_id)
			return Parsed_Query{}
		}
		if right.unresolved_name {
			query_diagnose(parser, .Unknown_Field, right.field_id)
			return Parsed_Query{}
		}
		if left.type != .Boolean || right.type != .Boolean {
			query_diagnose(parser, .Query_Type_Mismatch, "or requires Boolean expressions")
			return Parsed_Query{}
		}
		left = append_binary_query_node(parser, .Or, .Boolean, left, right)
	}
	return left
}

parse_query_and :: proc(parser: ^Query_Parser) -> Parsed_Query {
	left := parse_query_comparison(parser)
	for left.valid {
		if !query_consume_word(parser, "and") { break }
		right := parse_query_comparison(parser)
		if !right.valid { return right }
		if left.unresolved_name {
			query_diagnose(parser, .Unknown_Field, left.field_id)
			return Parsed_Query{}
		}
		if right.unresolved_name {
			query_diagnose(parser, .Unknown_Field, right.field_id)
			return Parsed_Query{}
		}
		if left.type != .Boolean || right.type != .Boolean {
			query_diagnose(parser, .Query_Type_Mismatch, "and requires Boolean expressions")
			return Parsed_Query{}
		}
		left = append_binary_query_node(parser, .And, .Boolean, left, right)
	}
	return left
}

parse_query_comparison :: proc(parser: ^Query_Parser) -> Parsed_Query {
	left := parse_query_unary(parser)
	if !left.valid { return left }
	query_skip_space(parser)
	operator, matched := query_consume_comparison(parser)
	if !matched { return left }
	right := parse_query_unary(parser)
	if !right.valid { return right }
	if !resolve_query_comparison_types(parser, &left, &right, operator) { return Parsed_Query{} }
	return append_binary_query_node(parser, operator, .Boolean, left, right)
}

parse_query_unary :: proc(parser: ^Query_Parser) -> Parsed_Query {
	query_skip_space(parser)
	if query_consume_word(parser, "not") {
		operand := parse_query_unary(parser)
		if !operand.valid { return operand }
		if operand.unresolved_name {
			query_diagnose(parser, .Unknown_Field, operand.field_id)
			return Parsed_Query{}
		}
		if operand.type != .Boolean {
			query_diagnose(parser, .Query_Type_Mismatch, "not requires a Boolean expression")
			return Parsed_Query{}
		}
		return append_unary_query_node(parser, .Not, .Boolean, operand)
	}
	return parse_query_primary(parser)
}

parse_query_primary :: proc(parser: ^Query_Parser) -> Parsed_Query {
	query_skip_space(parser)
	if parser.position >= len(parser.source) {
		query_diagnose(parser, .Invalid_Query, "expected an expression")
		return Parsed_Query{}
	}
	if parser.source[parser.position] == '(' {
		parser.position += 1
		inside := parse_query_or(parser)
		query_skip_space(parser)
		if parser.position >= len(parser.source) || parser.source[parser.position] != ')' {
			query_diagnose(parser, .Invalid_Query, "expected ')' after expression")
			return Parsed_Query{}
		}
		parser.position += 1
		return inside
	}
	start := parser.position
	if parser.source[parser.position] == '-' && parser.position+1 < len(parser.source) && is_ascii_digit(parser.source[parser.position+1]) {
		parser.position += 1
		for parser.position < len(parser.source) && is_ascii_digit(parser.source[parser.position]) { parser.position += 1 }
		return parse_integer_query_literal(parser, start)
	}
	if is_ascii_digit(parser.source[parser.position]) {
		for parser.position < len(parser.source) && is_ascii_digit(parser.source[parser.position]) { parser.position += 1 }
		return parse_integer_query_literal(parser, start)
	}
	for parser.position < len(parser.source) && is_query_identifier_byte(parser.source[parser.position]) {
		parser.position += 1
	}
	if parser.position == start {
		query_diagnose(parser, .Invalid_Query, "expected a field, literal, or parenthesized expression")
		return Parsed_Query{}
	}
	name := parser.source[start:parser.position]
	if name == "true" || name == "false" {
		value := name == "true"
		index := append_query_node(parser, Query_Node{
			operator = .Boolean_Literal,
			type = .Boolean,
			boolean = value,
			line = parser.line,
			column = parser.base_column+start,
		})
		return Parsed_Query{node = index, type = .Boolean, valid = true}
	}
	if name == "and" || name == "or" || name == "not" {
		query_diagnose(parser, .Invalid_Query, "expected a field or literal")
		return Parsed_Query{}
	}
	opaque_prefix := strings_has_prefix(name, "opaque:")
	field_name := name
	if opaque_prefix { field_name = name[len("opaque:"):] }
	field, found := query_field(parser.registry, field_name)
	if found {
		if opaque_prefix {
			if !field.opaque || field.type != .Boolean {
				query_diagnose(parser, .Invalid_Query, "opaque predicates must be registered Boolean fields")
				return Parsed_Query{}
			}
		} else if field.opaque {
			query_diagnose(parser, .Invalid_Query, "opaque predicates must use the opaque: prefix")
			return Parsed_Query{}
		}
		operator := Query_Operator.Field
		if field.opaque { operator = .Opaque_Field }
		index := append_query_node(parser, Query_Node{
			operator = operator,
			type = field.type,
			field_id = field.id,
			enum_type = field.enum_type,
			line = parser.line,
			column = parser.base_column+start,
		})
		return Parsed_Query{
			node = index,
			type = field.type,
			enum_type = field.enum_type,
			enum_values = field.enum_values,
			field_id = field.id,
			valid = true,
		}
	}
	if opaque_prefix {
		query_diagnose(parser, .Unknown_Field, name)
		return Parsed_Query{}
	}
	index := append_query_node(parser, Query_Node{
		operator = .Enumeration_Literal,
		type = .Enumeration,
		enum_value = name,
		line = parser.line,
		column = parser.base_column+start,
	})
	return Parsed_Query{node = index, type = .Enumeration, enum_value = name, unresolved_name = true, valid = true}
}

parse_integer_query_literal :: proc(parser: ^Query_Parser, start: int) -> Parsed_Query {
	value, ok := parse_i64(parser.source[start:parser.position])
	if !ok {
		query_diagnose(parser, .Invalid_Query, "integer literal is outside the supported range")
		return Parsed_Query{}
	}
	index := append_query_node(parser, Query_Node{
		operator = .Integer_Literal,
		type = .Integer,
		integer = value,
		line = parser.line,
		column = parser.base_column+start,
	})
	return Parsed_Query{node = index, type = .Integer, valid = true}
}

resolve_query_comparison_types :: proc(
	parser: ^Query_Parser,
	left, right: ^Parsed_Query,
	operator: Query_Operator,
) -> bool {
	if left.unresolved_name {
		if right.type != .Enumeration || right.enum_type == "" {
			query_diagnose(parser, .Unknown_Field, left.field_id)
			return false
		}
		if !enum_value_exists(right.enum_values, left.enum_value) {
			query_diagnose(parser, .Invalid_Query, left.enum_value)
			return false
		}
		left.enum_type = right.enum_type
		left.enum_values = right.enum_values
		left.unresolved_name = false
		parser.compilation.program.query_nodes[left.node].enum_type = own_query_string(parser.compilation, right.enum_type)
	}
	if right.unresolved_name {
		if left.type != .Enumeration || left.enum_type == "" {
			query_diagnose(parser, .Unknown_Field, right.field_id)
			return false
		}
		if !enum_value_exists(left.enum_values, right.enum_value) {
			query_diagnose(parser, .Invalid_Query, right.enum_value)
			return false
		}
		right.enum_type = left.enum_type
		right.enum_values = left.enum_values
		right.unresolved_name = false
		parser.compilation.program.query_nodes[right.node].enum_type = own_query_string(parser.compilation, left.enum_type)
	}
	if left.type != right.type {
		query_diagnose(parser, .Query_Type_Mismatch, "comparison operands have different types")
		return false
	}
	if left.type == .Enumeration && left.enum_type != right.enum_type {
		query_diagnose(parser, .Query_Type_Mismatch, "enum operands use different enum types")
		return false
	}
	if operator != .Equal && operator != .Not_Equal && left.type != .Integer {
		query_diagnose(parser, .Query_Type_Mismatch, "ordered comparisons require integer operands")
		return false
	}
	return true
}

append_binary_query_node :: proc(parser: ^Query_Parser, operator: Query_Operator, value_type: Query_Type, left, right: Parsed_Query) -> Parsed_Query {
	index := append_query_node(parser, Query_Node{
		operator = operator,
		type = value_type,
		left = left.node,
		right = right.node,
		line = parser.line,
		column = parser.base_column+parser.position,
	})
	return Parsed_Query{node = index, type = value_type, valid = true}
}

append_unary_query_node :: proc(parser: ^Query_Parser, operator: Query_Operator, value_type: Query_Type, operand: Parsed_Query) -> Parsed_Query {
	index := append_query_node(parser, Query_Node{
		operator = operator,
		type = value_type,
		left = operand.node,
		line = parser.line,
		column = parser.base_column+parser.position,
	})
	return Parsed_Query{node = index, type = value_type, valid = true}
}

append_query_node :: proc(parser: ^Query_Parser, node: Query_Node) -> int {
	owned_node := node
	owned_node.field_id = own_query_string(parser.compilation, node.field_id)
	owned_node.enum_type = own_query_string(parser.compilation, node.enum_type)
	owned_node.enum_value = own_query_string(parser.compilation, node.enum_value)
	append(&parser.compilation.program.query_nodes, owned_node)
	return len(parser.compilation.program.query_nodes)-1
}

query_field :: proc(registry: Registry, id: string) -> (field: Field_Definition, found: bool) {
	for candidate in registry.fields {
		if candidate.id == id { return candidate, true }
	}
	return {}, false
}

query_consume_word :: proc(parser: ^Query_Parser, word: string) -> bool {
	query_skip_space(parser)
	end := parser.position+len(word)
	if end > len(parser.source) || parser.source[parser.position:end] != word { return false }
	if end < len(parser.source) && is_query_identifier_byte(parser.source[end]) { return false }
	parser.position = end
	return true
}

query_consume_comparison :: proc(parser: ^Query_Parser) -> (operator: Query_Operator, matched: bool) {
	if query_consume_token(parser, "==") { return .Equal, true }
	if query_consume_token(parser, "!=") { return .Not_Equal, true }
	if query_consume_token(parser, "<=") { return .Less_Equal, true }
	if query_consume_token(parser, ">=") { return .Greater_Equal, true }
	if query_consume_token(parser, "<") { return .Less, true }
	if query_consume_token(parser, ">") { return .Greater, true }
	return .Equal, false
}

query_consume_token :: proc(parser: ^Query_Parser, token: string) -> bool {
	if parser.position+len(token) > len(parser.source) { return false }
	if parser.source[parser.position:parser.position+len(token)] != token { return false }
	parser.position += len(token)
	return true
}

query_skip_space :: proc(parser: ^Query_Parser) {
	for parser.position < len(parser.source) && (parser.source[parser.position] == ' ' || parser.source[parser.position] == '\t') {
		parser.position += 1
	}
}

query_diagnose :: proc(parser: ^Query_Parser, code: Diagnostic_Code, token: string) {
	column := parser.base_column+parser.position
	diagnose(parser.compilation, code, parser.line, column, token)
}

is_query_identifier_byte :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		(ch >= '0' && ch <= '9') || ch == '_' || ch == '.' || ch == ':'
}

is_ascii_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

parse_i64 :: proc(text: string) -> (value: i64, ok: bool) {
	if text == "" { return 0, false }
	negative := text[0] == '-'
	start := 0
	if negative { start = 1 }
	if start >= len(text) { return 0, false }
	limit := u64(max(i64))
	if negative { limit += 1 }
	unsigned_value: u64 = 0
	for i in start..<len(text) {
		ch := text[i]
		if !is_ascii_digit(ch) { return 0, false }
		digit := u64(ch-'0')
		if unsigned_value > (limit-digit)/10 { return 0, false }
		unsigned_value = unsigned_value*10+digit
	}
	if negative {
		if unsigned_value == u64(max(i64))+1 { return min(i64), true }
		return -i64(unsigned_value), true
	}
	return i64(unsigned_value), true
}

enum_value_exists :: proc(values: []string, value: string) -> bool {
	for candidate in values { if candidate == value { return true } }
	return false
}

strings_has_prefix :: proc(value, prefix: string) -> bool {
	return len(value) >= len(prefix) && value[:len(prefix)] == prefix
}
