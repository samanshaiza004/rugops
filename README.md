# Rugops

Rugops is an experimental, Odin-first game foundation built around explicit state transitions and logical time. The first example, **The Unobserved**, is a short visual novel with a headless simulation and a raylib host.

The engine is intentionally small: `core/` supplies a deterministic integer clock, stable scheduled-event queue, and generic command-history records. `examples/unobserved/game/` owns the game's world, rules, observations, and versioned save format. `examples/unobserved/main/` translates keyboard and mouse input to game commands and renders observations with raylib. No raylib package is imported by the core or the narrative simulation.

`narrative/` is an optional, renderer-independent library for compiling readable dialogue scripts and executing their directed control flow. It does not depend on `core/`, raylib, or a game model. Games declare typed fields and actions; they keep world state, action consequences, and narrative-map meaning in game code.

## Requirements

- Odin compiler (the toolchain used for this milestone: `dev-2026-09-nightly:a2fb372`)
- Odin's bundled `vendor:raylib` bindings and library (verified as raylib 6.0)
- macOS, Windows, or Linux desktop for the native host

The repository is configured as an Odin collection named `rugops`. Build scripts pass `-collection:rugops=.`.

On Windows, `scripts/build.sh` writes `build/the_unobserved.exe`; `scripts/run.sh` starts that executable. On macOS and Linux, both scripts use `build/the_unobserved`.

## Build, run, and test

From the repository root:

```sh
./scripts/build.sh
./scripts/run.sh
./scripts/test.sh
```

`run.sh` builds and starts the resizable 1280×720 native window. The view keeps its aspect ratio and letterboxes when resized. Use Enter, Space, or click to read; use 1/2, Up/Down plus Enter, or click a choice to act. F5 saves and F9 restores `build/unobserved-save.json`. Escape or the window close button exits.

The headless CLI does not initialize raylib or open a window:

```sh
./scripts/headless.sh scenario invite
./scripts/headless.sh scenario leave
./scripts/headless.sh replay invite
./scripts/headless.sh scenario invite build/progress.json
./scripts/headless.sh inspect build/progress.json
```

Each command prints one JSON observation with the tick, location, active dialogue, available choices, relevant character state, and history length. `scenario invite` shows Hana waiting and Ren delivering the letter; `scenario leave` shows Hana gone and Ren keeping it. `replay` replays the recorded commands and exits unsuccessfully if the resulting observation differs.

## A game in a few calls

The example's public simulation surface is intentionally direct:

```odin
world := unobserved.new_world()
_ = unobserved.submit(&world, {.Advance_Dialogue})
_ = unobserved.submit(&world, {.Advance_Dialogue})
observation := unobserved.observe(&world)
// observation.choices can be turned into UI, CLI, or agent actions.
```

`submit` returns an error for invalid commands and changes no state in that case. Reading dialogue never advances time. The two explicit station choices advance to tick 12; the later trip to Ren advances to tick 20. The tick-10 handler schedules Ren's tick-12 arrival while it runs; `core.advance_to` returns one due event at its own timestamp, allowing the game to handle it and schedule consequences before advancing farther. Calls repeat through the requested target, with stable insertion order for events sharing a timestamp. Scheduling an event earlier than the current logical tick is rejected.

## Optional narrative library

`rugops:narrative` compiles Rugops Script source to an indexed `Program`. `.rgps` is the canonical source extension; `.stalga` remains a valid input alias because the compiler consumes source text and does not infer language semantics from a filename. Authored scene IDs and anchors are stable identities; ordinary dialogue is sequential and has no manually assigned line IDs or next-line pointers. A game registers speaker names, typed action definitions, and typed query fields so the compiler can diagnose misspelled symbols, invalid conditions, and missing outcome routes.

```odin
import narrative "rugops:narrative"

compiled := narrative.compile(script_text, game.narrative_symbols(),
	narrative.Program_Metadata{id = "my_game.chapter_01", version = 1})
defer narrative.destroy_compilation(&compiled)
if narrative.has_errors(&compiled) {
	// Report compiled.diagnostics and stop before starting a session.
}

state := narrative.new_state(&compiled.program)
for {
	runtime_error, query_error := narrative.advance(&compiled.program, &state, game_context,
		game.resolve_query_field, game.on_narrative_event)
	if runtime_error != .None || query_error != .None || state.ended { break }
	// Render or inspect the node at state.cursor. Dialogue can continue
	// without advancing fictional time.
}

// The UI retains a program-scoped offer handle from the observation.
index, visible, query_error := narrative.visible_choice(&compiled.program, &state,
	0, game_context, game.resolve_query_field)
offer, has_offer := narrative.choice_id(&compiled.program, index)
if visible && query_error == .None && has_offer {
submission := narrative.submit_choice(&compiled.program, &state, offer,
	game_context, game.resolve_query_field, game.resolve_action)
}
```

Conditions are a small Boolean expression language with `and`, `or`, `not`, parentheses, integer comparisons, and registered enum comparisons. For example, `@if masha.has_page and player.bond >= 3`. Fields resolve through a read-only callback; unknown fields and resolver failures are reported as errors, never converted to false. Registered opaque Boolean predicates can be referenced with `opaque:predicate_name`; their declared field dependencies remain inspectable, but their internals are not symbolically analyzable. `explain_query` reports the evaluated subexpressions and any failing field. Call `destroy_query_explanation` when finished with its owned step list.

`advance` resolves branches, jumps, anchors, and end instructions until it reaches dialogue, narration, or a choice group. `visible_choice` maps a player-visible option ordinal to its current compiled choice. `submit_choice` accepts the program-scoped handle captured from that observation, rechecks eligibility, validates all declared continuations, invokes the game-owned action resolver, and advances the narrative cursor according to its typed outcome. Actions can declare accepted, refused, interrupted, or deferred results; every declared non-accepted outcome needs an explicit `@on` continuation. The game resolver validates before mutating and returns an explicit action error for an invalid command. The narrative runtime does not advance logical time by itself.

The compiled program owns its source buffer and query schema, and its source-authored strings refer into that buffer. Keep the `Compilation` alive for as long as its `Program` or runtime state is in use. `Program_Metadata` gives the compiled program an author-defined ID and version; the program also exposes a source hash and identity hash for save compatibility checks and diagnostics. These hashes do not migrate runtime positions. Runtime instruction positions are compile-local; store stable scene/anchor IDs in saves and resolve them with `cursor_at_anchor` after recompilation. Structural program changes may still require a deliberate game-authored migration; never guess when a saved position cannot be mapped safely.

## Save compatibility

Saves are JSON snapshots with a top-level `version` and the complete authoritative `world`, including the logical clock, pending events, stable-order counter, game flags, dialogue position, and command history. Version 2 is the current format after the causal scheduler change; version 1 saves are rejected. Loading validates the snapshot by replaying its command history and comparing all authoritative fields, including pending events. No compatibility promise is made between versions; a game should reject unsupported versions and migrate deliberately when its state schema changes.

Audio is an external host side effect. Loading a save does not issue gameplay audio commands or replay past sounds; the native host starts its music once and plays a short sound only in response to successful player input.

## Layout

```text
core/                         Deterministic logical time and history records
narrative/                    Optional text compiler, indexed IR, and interpreter
examples/unobserved/game/     Headless world, commands, observations, save/load
examples/unobserved/main/     Raylib window, input, assets, rendering, audio
examples/unobserved/assets/   Original generated placeholder art and sounds
tools/                        Headless scenarios and JSON inspection
tests/                        Odin tests; no window or raylib initialization
scripts/                      Native and headless build/run/test entry points
```

The background and portrait illustrations were generated for this example and then resized/cropped for runtime use. The quiet music loop and click sound are locally synthesized test assets.

## Validation and limitations

The first milestone was built and exercised on macOS arm64 with Odin's bundled raylib 6.0. Headless tests cover stable event ordering, nested scheduling and large-step equivalence, event-past rejection, complete-state replay, offscreen events, dialogue/time separation, save/load validation, and invalid commands. Native asset loading fails with a nonzero exit when a required asset is missing or invalid.

Windows and Linux builds, WebAssembly, hot reload, and graphical testing on those platforms remain future validation targets. The narrative is deliberately fixed and small; there is no editor, general scene system, ECS, physics, or scripting language.

## License and origin

Rugops is an experimental open-source project. The initial repository was based on Karl Zylinski's Odin + raylib template; the original license notice is retained in `LICENSE`. Odin and raylib retain their respective licenses in the toolchain distribution.
