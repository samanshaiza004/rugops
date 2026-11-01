// Package rugops_presentation defines renderer-independent, non-authoritative
// presentation state and host-driven stage transitions.
package rugops_presentation

// IDs are authored or game-owned names. A presenter maps asset IDs to its own
// texture, font, and audio resources; those resources never enter this package.
Asset_ID     :: distinct string
Character_ID :: distinct string
Impulse_ID   :: distinct u64
Transition_ID :: distinct u64

MAX_STAGE_CHARACTERS :: 8

Stage_Slot :: enum {
	Far_Left,
	Left,
	Center,
	Right,
	Far_Right,
}

Character_State :: struct {
	id:         Character_ID,
	portrait:   Asset_ID,
	expression: Asset_ID,
	slot:       Stage_Slot,
	opacity:    u8,
	visible:    bool,
}

// Stage_State is the persistent desired composition. Soundtrack is a looping
// state declaration that hosts reconcile; one-shot audio belongs in impulses.
Stage_State :: struct {
	background:      Asset_ID,
	soundtrack:      Asset_ID,
	characters:      [MAX_STAGE_CHARACTERS]Character_State,
	character_count: int,
}

Stage_Error :: enum {
	None,
	Empty_Character_ID,
	Character_Capacity_Reached,
	Character_Not_Found,
}

set_background :: proc(stage: ^Stage_State, asset: Asset_ID) {
	stage.background = asset
}

set_soundtrack :: proc(stage: ^Stage_State, asset: Asset_ID) {
	stage.soundtrack = asset
}

// set_character inserts a character in stable insertion order, or replaces
// the existing state for the same character ID without moving its layer.
set_character :: proc(stage: ^Stage_State, character: Character_State) -> Stage_Error {
	if string(character.id) == "" {
		return .Empty_Character_ID
	}
	for i in 0..<stage.character_count {
		if stage.characters[i].id == character.id {
			stage.characters[i] = character
			return .None
		}
	}
	if stage.character_count >= MAX_STAGE_CHARACTERS {
		return .Character_Capacity_Reached
	}
	stage.characters[stage.character_count] = character
	stage.character_count += 1
	return .None
}

remove_character :: proc(stage: ^Stage_State, id: Character_ID) -> Stage_Error {
	for i in 0..<stage.character_count {
		if stage.characters[i].id == id {
			for j in i..<(stage.character_count-1) {
				stage.characters[j] = stage.characters[j+1]
			}
			stage.character_count -= 1
			stage.characters[stage.character_count] = {}
			return .None
		}
	}
	return .Character_Not_Found
}

// A one-shot sound cue is an external side effect. Its stable ID lets a host
// suppress duplicate delivery if it chooses; it is never stored in Stage_State.
Play_Sound_Impulse :: struct {
	asset:       Asset_ID,
	gain_percent: u8,
}

Impulse_Payload :: union {
	Play_Sound_Impulse,
}

Presentation_Impulse :: struct {
	id:      Impulse_ID,
	payload: Impulse_Payload,
}

Impulse_Queue :: struct {
	items: [dynamic]Presentation_Impulse,
}

Impulse_Error :: enum {
	None,
	Invalid_ID,
	Empty_Sound_Asset,
	Duplicate_ID,
}

queue_impulse :: proc(queue: ^Impulse_Queue, impulse: Presentation_Impulse) -> Impulse_Error {
	if impulse.id == Impulse_ID(0) {
		return .Invalid_ID
	}
	if sound, ok := impulse.payload.(Play_Sound_Impulse); ok {
		if string(sound.asset) == "" {
			return .Empty_Sound_Asset
		}
	}
	for queued in queue.items {
		if queued.id == impulse.id {
			return .Duplicate_ID
		}
	}
	append(&queue.items, impulse)
	return .None
}

// take_impulses transfers the queued batch to its caller and empties the
// queue. The caller must delete the returned dynamic array after delivery.
take_impulses :: proc(queue: ^Impulse_Queue) -> [dynamic]Presentation_Impulse {
	items := queue.items
	queue.items = nil
	return items
}

destroy_impulse_queue :: proc(queue: ^Impulse_Queue) {
	delete(queue.items)
	queue.items = nil
}

Presentation_Milliseconds :: distinct u64

Transition_Style :: enum {
	Cut,
	Crossfade,
}

Transition_Status :: enum {
	Idle,
	Running,
	Completed,
	Cancelled,
}

Transition_Settlement :: enum {
	Keep_Source,
	Settle_Target,
}

Transition_Request :: struct {
	id:       Transition_ID,
	style:    Transition_Style,
	duration: Presentation_Milliseconds,
}

Transition_State :: struct {
	status:      Transition_Status,
	request:     Transition_Request,
	source:      Stage_State,
	target:      Stage_State,
	elapsed:     Presentation_Milliseconds,
	settlement:  Transition_Settlement,
}

Presentation_State :: struct {
	stage:      Stage_State,
	transition: Transition_State,
}

Transition_Error :: enum {
	None,
	Invalid_ID,
	Already_Running,
	Not_Running,
	Timed_Cut,
}

// request_transition snapshots a target composition. The current stage stays
// authoritative for presentation until completion or explicit cancellation.
// A cut is required to have zero duration; a zero-duration crossfade also
// completes immediately.
request_transition :: proc(state: ^Presentation_State, request: Transition_Request, target: Stage_State) -> Transition_Error {
	if request.id == Transition_ID(0) {
		return .Invalid_ID
	}
	if state.transition.status == .Running {
		return .Already_Running
	}
	if request.style == .Cut && request.duration != Presentation_Milliseconds(0) {
		return .Timed_Cut
	}
	state.transition = Transition_State{
		status     = .Running,
		request    = request,
		source     = state.stage,
		target     = target,
		elapsed    = Presentation_Milliseconds(0),
		settlement = .Keep_Source,
	}
	if request.style == .Cut || request.duration == Presentation_Milliseconds(0) {
		state.stage = target
		state.transition.status = .Completed
		state.transition.elapsed = request.duration
		state.transition.settlement = .Settle_Target
	}
	return .None
}

// advance_transition consumes only host-supplied presentation milliseconds.
// It never reads a clock or touches gameplay time. Overshooting the end clamps
// to the requested duration, making the transition result deterministic.
advance_transition :: proc(state: ^Presentation_State, delta: Presentation_Milliseconds) -> Transition_Error {
	if state.transition.status != .Running {
		return .Not_Running
	}
	remaining := u64(state.transition.request.duration) - u64(state.transition.elapsed)
	if u64(delta) >= remaining {
		state.transition.elapsed = state.transition.request.duration
		state.transition.status = .Completed
		state.transition.settlement = .Settle_Target
		state.stage = state.transition.target
		return .None
	}
	state.transition.elapsed = Presentation_Milliseconds(u64(state.transition.elapsed) + u64(delta))
	return .None
}

// cancel_transition always records cancellation. The explicit settlement
// policy chooses which persistent stage is left for the next presentation.
cancel_transition :: proc(state: ^Presentation_State, settlement: Transition_Settlement) -> Transition_Error {
	if state.transition.status != .Running {
		return .Not_Running
	}
	if settlement == .Settle_Target {
		state.stage = state.transition.target
	} else {
		state.stage = state.transition.source
	}
	state.transition.status = .Cancelled
	state.transition.settlement = settlement
	return .None
}

transition_progress :: proc(transition: Transition_State) -> f32 {
	if transition.status == .Idle {
		return 0
	}
	if transition.status == .Completed || transition.status == .Cancelled {
		if transition.settlement == .Settle_Target || transition.status == .Completed {
			return 1
		}
		return 0
	}
	if transition.request.duration == Presentation_Milliseconds(0) {
		return 1
	}
	return f32(u64(transition.elapsed)) / f32(u64(transition.request.duration))
}

Noop_Presenter :: struct {}

noop_present_stage :: proc(_: ^Noop_Presenter, _: ^Stage_State) {
	// A headless host observes the same value but creates no window or resource.
}

// noop_deliver_impulses consumes one-shot work exactly once while producing no
// side effects. It returns the number consumed for headless diagnostics/tests.
noop_deliver_impulses :: proc(_: ^Noop_Presenter, queue: ^Impulse_Queue) -> int {
	items := take_impulses(queue)
	count := len(items)
	delete(items)
	return count
}
