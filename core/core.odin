// Package core contains the platform-independent pieces shared by Rugops games.
// It deliberately knows nothing about windows, graphics, input, or audio.
package rugops_core

Event_ID :: u32
Tick :: u64

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

// Schedule inserts an event in deterministic (tick, insertion-order) order.
schedule :: proc(t: ^Timeline, tick: Tick, id: Event_ID, value: i64 = 0) {
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
}

// advance moves logical time forward and returns all events due by the target.
// The returned events keep their stable ordering and are removed from pending.
advance :: proc(t: ^Timeline, delta: Tick) -> [dynamic]Scheduled_Event {
	target := t.now + delta
	due: [dynamic]Scheduled_Event
	for event in t.pending {
		if event.tick > target {
			break
		}
		append(&due, event)
	}
	if len(due) > 0 {
		copy(t.pending[:], t.pending[len(due):])
		resize(&t.pending, len(t.pending)-len(due))
	}
	t.now = target
	return due
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
