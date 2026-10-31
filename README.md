# Rugops

Rugops is an experimental, Odin-first game foundation built around explicit state transitions and logical time. The first example, **The Unobserved**, is a short visual novel with a headless simulation and a raylib host.

The engine is intentionally small: `core/` supplies a deterministic integer clock, stable scheduled-event queue, and generic command-history records. `examples/unobserved/game/` owns the game's world, rules, observations, and versioned save format. `examples/unobserved/main/` translates keyboard and mouse input to game commands and renders observations with raylib. No raylib package is imported by the core or the narrative simulation.

`narrative/` is an optional, renderer-independent library for compiling readable dialogue scripts and executing their directed control flow. It does not depend on `core/`, raylib, or a game model. Games provide pure condition queries and receive scene/anchor events; they keep action outcomes, world state, and narrative-map meaning in game code.

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

`rugops:narrative` compiles `.stalga`-style source to an indexed `Program`. Authored scene IDs and anchors are stable identities; ordinary dialogue is sequential and has no manually assigned line IDs or next-line pointers. The game supplies a `Registry` of known speakers, actions, and conditions so the compiler can diagnose misspelled symbols and invalid targets.

```odin
import narrative "rugops:narrative"

compiled := narrative.compile(script_text, game.narrative_symbols())
defer narrative.destroy_compilation(&compiled)
if narrative.has_errors(&compiled) {
	// Report compiled.diagnostics and stop before starting a session.
}

state := narrative.new_state(&compiled.program)
for {
	err := narrative.advance(&compiled.program, &state, game_context,
		game.query_condition, game.on_narrative_event)
	if err != .None || state.ended { break }
	// Render or inspect the node at state.cursor. Continue with
	// narrative.continue_dialogue, or resolve a visible choice in game code.
}
```

`advance` resolves branches, jumps, anchors, and end instructions until it reaches dialogue, narration, or a choice group. Its condition callback is read-only; its event callback reports scene entries and reached anchors. `visible_choice` maps a player-visible option index to the compiled choice. After the game validates and commits the named action, `commit_choice` moves the narrative cursor. The runtime does not advance logical time by itself.

The compiled program owns its source buffer, and its strings refer into that buffer. Keep the `Compilation` alive for as long as its `Program` or runtime state is in use. Runtime instruction positions are compile-local; store stable scene/anchor IDs in saves and resolve them with `cursor_at_anchor` after recompilation. Structural program changes may still require a game-authored save migration.

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
