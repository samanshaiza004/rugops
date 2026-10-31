// Package core contains the platform-independent pieces shared by Rugops games.
// It deliberately knows nothing about windows, graphics, input, or audio.
package rugops_core

Event_ID :: u32
Tick :: u64

Timeline_Error :: enum {
	None,
	Tick_In_Past,
	Target_In_Past,
	Order_Overflow,
}

Scheduled_Event :: struct {
	tick:  Tick,
	order: u64,
	id:    Event_ID,
	value: i64,
}

Timeline :: struct {
	now:        Tick,
	next_order: u64,
	pending:    [dynamic]Scheduled_Event,
}

// schedule inserts an event in deterministic (tick, insertion-order) order.
// Events earlier than the current logical time are rejected.
schedule :: proc(t: ^Timeline, tick: Tick, id: Event_ID, value: i64 = 0) -> Timeline_Error {
	if tick < t.now {
		return .Tick_In_Past
	}
	if t.next_order == max(u64) {
		return .Order_Overflow
	}
	event := Scheduled_Event{tick = tick, order = t.next_order, id = id, value = value}
	t.next_order += 1
	append(&t.pending, event)

	i := len(t.pending) - 1
	for i > 0 {
		prev := t.pending[i-1]
		if prev.tick < event.tick || (prev.tick == event.tick && prev.order < event.order) {
			break
		}
		t.pending[i] = prev
		i -= 1
	}
	t.pending[i] = event
	return .None
}

// advance_to processes at most one event due by target. It moves now to that
// event's tick before returning it, so the caller can handle the event and
// schedule consequences relative to the correct time. Call again with the
// same target until has_event is false; the final call moves now to target.
advance_to :: proc(t: ^Timeline, target: Tick) -> (event: Scheduled_Event, has_event: bool, err: Timeline_Error) {
	if target < t.now {
		return {}, false, .Target_In_Past
	}
	if len(t.pending) > 0 && t.pending[0].tick <= target {
		event = t.pending[0]
		copy(t.pending[:], t.pending[1:])
		resize(&t.pending, len(t.pending)-1)
		t.now = event.tick
		return event, true, .None
	}
	t.now = target
	return {}, false, .None
}

// Command_Record is the compact deterministic history entry used by games.
Command_Record :: struct {
	kind:     u32,
	argument: i64,
}

Command_History :: struct {
	items: [dynamic]Command_Record,
}

record :: proc(h: ^Command_History, command: Command_Record) {
	append(&h.items, command)
}
