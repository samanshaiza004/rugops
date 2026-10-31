package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import rl "vendor:raylib"
import game "rugops:examples/unobserved/game"

VIRTUAL_WIDTH :: 1280
VIRTUAL_HEIGHT :: 720
SAVE_PATH :: "build/unobserved-save.json"

Host_Assets :: struct {
	station: rl.Texture2D,
	river:   rl.Texture2D,
	hana:    rl.Texture2D,
	ren:     rl.Texture2D,
	music:   rl.Music,
	click:   rl.Sound,
}

main :: proc() {
	run_native()
}

run_native :: proc() {
	set_project_working_directory()
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(VIRTUAL_WIDTH, VIRTUAL_HEIGHT, "The Unobserved — Rugops")
	rl.SetWindowMinSize(640, 360)
	rl.SetExitKey(nil)
	rl.InitAudioDevice()

	assets := load_assets()
	if !rl.IsTextureValid(assets.station) || !rl.IsTextureValid(assets.river) || !rl.IsTextureValid(assets.hana) || !rl.IsTextureValid(assets.ren) || !rl.IsMusicValid(assets.music) || !rl.IsSoundValid(assets.click) {
		fmt.eprintln("missing or invalid asset under examples/unobserved/assets")
		unload_assets(assets)
		rl.CloseAudioDevice()
		rl.CloseWindow()
		os.exit(1)
	}
	if rl.IsMusicValid(assets.music) {
		rl.SetMusicVolume(assets.music, 0.20)
		rl.PlayMusicStream(assets.music)
	}
	if rl.IsSoundValid(assets.click) { rl.SetSoundVolume(assets.click, 0.28) }

	world := game.new_world()
	selected_choice := 0
	host_notice: string
	for !rl.WindowShouldClose() {
		if rl.IsMusicValid(assets.music) {
			rl.UpdateMusicStream(assets.music)
			if !rl.IsMusicStreamPlaying(assets.music) { rl.PlayMusicStream(assets.music) }
		}
		if rl.IsKeyPressed(.F5) {
			_ = os.make_directory("build")
			if game.save(&world, SAVE_PATH) == .None {
				host_notice = "Saved to build/unobserved-save.json"
			} else {
				host_notice = "Could not save progress"
			}
		}
		if rl.IsKeyPressed(.F9) {
			loaded, load_err := game.load(SAVE_PATH)
			if load_err == .None {
				game.destroy_world(&world)
				world = loaded
				selected_choice = 0
				host_notice = "Loaded build/unobserved-save.json"
			} else {
				game.destroy_world(&loaded)
				host_notice = "Could not load progress"
			}
		}
		observation := game.observe(&world)
		mouse := rl.GetMousePosition()
		window_width := f32(rl.GetScreenWidth())
		window_height := f32(rl.GetScreenHeight())
		scale := min(window_width/f32(VIRTUAL_WIDTH), window_height/f32(VIRTUAL_HEIGHT))
		offset := rl.Vector2{(window_width-f32(VIRTUAL_WIDTH)*scale)/2, (window_height-f32(VIRTUAL_HEIGHT)*scale)/2}
		mouse_virtual := rl.Vector2{(mouse.x-offset.x)/scale, (mouse.y-offset.y)/scale}

		if len(observation.choices) > 0 {
			if rl.IsKeyPressed(.ONE) { selected_choice = 0 }
			if rl.IsKeyPressed(.TWO) && len(observation.choices) > 1 { selected_choice = 1 }
			if rl.IsKeyPressed(.UP) { selected_choice = max(0, selected_choice-1) }
			if rl.IsKeyPressed(.DOWN) { selected_choice = min(len(observation.choices)-1, selected_choice+1) }
			if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
				if game.submit(&world, game.Command{kind = observation.choices[selected_choice].command}) == .None {
					if rl.IsSoundValid(assets.click) { rl.PlaySound(assets.click) }
				}
				selected_choice = 0
			} else if rl.IsMouseButtonPressed(.LEFT) {
				for i in 0..<len(observation.choices) {
					rect := choice_rect(i)
					if point_in_rect(mouse_virtual, rect) {
						selected_choice = i
						if game.submit(&world, game.Command{kind = observation.choices[i].command}) == .None && rl.IsSoundValid(assets.click) {
							rl.PlaySound(assets.click)
						}
						selected_choice = 0
						break
					}
				}
			}
		} else if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.LEFT) {
			if game.submit(&world, game.Command{kind = .Advance_Dialogue}) == .None && rl.IsSoundValid(assets.click) {
				rl.PlaySound(assets.click)
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{14, 17, 29, 255})
		rl.BeginMode2D(rl.Camera2D{offset = offset, zoom = scale})
		draw_scene(assets, &world, selected_choice, host_notice)
		rl.EndMode2D()
		rl.EndDrawing()
		delete(observation.choices)
		free_all(context.temp_allocator)
	}

	unload_assets(assets)
	game.destroy_world(&world)
	rl.CloseAudioDevice()
	rl.CloseWindow()
}

// A built binary may be launched from Finder or an IDE with an unrelated
// working directory. Find the project root relative to the executable when
// possible; scripts and `odin run` still work from the repository root.
set_project_working_directory :: proc() {
	exe_path, err := os.get_executable_path(context.allocator)
	if err != os.ERROR_NONE { return }
	defer delete(exe_path)
	candidate := filepath.dir(exe_path)
	for _ in 0..<8 {
		asset_path, join_err := filepath.join([]string{candidate, "examples", "unobserved", "assets", "station.png"})
		if join_err == nil {
			defer delete(asset_path)
			if os.exists(asset_path) {
				_ = os.set_working_directory(candidate)
				return
			}
		}
		candidate = filepath.dir(candidate)
	}
}

load_assets :: proc() -> Host_Assets {
	return {
		station = rl.LoadTexture("examples/unobserved/assets/station.png"),
		river = rl.LoadTexture("examples/unobserved/assets/riverside.png"),
		hana = rl.LoadTexture("examples/unobserved/assets/hana.png"),
		ren = rl.LoadTexture("examples/unobserved/assets/ren.png"),
		music = rl.LoadMusicStream("examples/unobserved/assets/evening.wav"),
		click = rl.LoadSound("examples/unobserved/assets/click.wav"),
	}
}

unload_assets :: proc(assets: Host_Assets) {
	if rl.IsTextureValid(assets.station) { rl.UnloadTexture(assets.station) }
	if rl.IsTextureValid(assets.river) { rl.UnloadTexture(assets.river) }
	if rl.IsTextureValid(assets.hana) { rl.UnloadTexture(assets.hana) }
	if rl.IsTextureValid(assets.ren) { rl.UnloadTexture(assets.ren) }
	if rl.IsMusicValid(assets.music) { rl.StopMusicStream(assets.music); rl.UnloadMusicStream(assets.music) }
	if rl.IsSoundValid(assets.click) { rl.UnloadSound(assets.click) }
}

draw_scene :: proc(assets: Host_Assets, world: ^game.World, selected_choice: int, host_notice: string) {
	observation := game.observe(world)
	background := assets.station
	if world.location == .River { background = assets.river }
	rl.DrawTexturePro(background,
		rl.Rectangle{0, 0, f32(background.width), f32(background.height)},
		rl.Rectangle{0, 0, VIRTUAL_WIDTH, VIRTUAL_HEIGHT},
		rl.Vector2{0, 0}, 0, rl.WHITE)

	if observation.speaker == "Hana" {
		draw_portrait(assets.hana, 55, 48, 500, 520)
	} else if observation.speaker == "Ren" {
		draw_portrait(assets.ren, 720, 48, 500, 520)
	}

	rl.DrawRectangleRounded(rl.Rectangle{38, 468, 1204, 226}, 0.04, 12, rl.Color{17, 19, 32, 242})
	rl.DrawRectangleRoundedLinesEx(rl.Rectangle{38, 468, 1204, 226}, 0.04, 12, 2, rl.Color{212, 178, 133, 230})
	rl.DrawText(fmt.ctprintf("%s", observation.speaker), 84, 490, 27, rl.Color{242, 204, 153, 255})
	rl.DrawText(fmt.ctprintf("%s", observation.dialogue), 84, 527, 25, rl.Color{239, 239, 235, 255})
	if len(observation.choices) == 0 && !observation.ended {
		rl.DrawText("Enter / Space / click to continue", 84, 657, 18, rl.Color{171, 177, 193, 255})
	}
	for choice, i in observation.choices {
		rect := choice_rect(i)
		fill := rl.Color{42, 48, 67, 255}
		if i == selected_choice { fill = rl.Color{76, 75, 97, 255} }
		rl.DrawRectangleRounded(rect, 0.2, 8, fill)
		rl.DrawText(fmt.ctprintf("%d. %s", i+1, choice.label), i32(rect.x)+16, i32(rect.y)+10, 20, rl.WHITE)
	}
	if observation.ended {
		rl.DrawText("The evening is yours to keep.", 84, 657, 18, rl.Color{171, 177, 193, 255})
	}
	rl.DrawText("F5 save  ·  F9 load", 1000, 680, 15, rl.Color{171, 177, 193, 255})
	if host_notice != "" {
		rl.DrawText(fmt.ctprintf("%s", host_notice), 84, 680, 15, rl.Color{242, 204, 153, 255})
	}
	delete(observation.choices)
}

draw_portrait :: proc(texture: rl.Texture2D, x, y, width, height: f32) {
	texture_width := f32(texture.width)
	texture_height := f32(texture.height)
	scale := min(width/texture_width, height/texture_height)
	dest_width := texture_width*scale
	dest_height := texture_height*scale
	dest := rl.Rectangle{x, y, dest_width, dest_height}
	rl.DrawTexturePro(texture, rl.Rectangle{0, 0, texture_width, texture_height}, dest, rl.Vector2{0, 0}, 0, rl.WHITE)
}

choice_rect :: proc(index: int) -> rl.Rectangle {
	return rl.Rectangle{78, 586+f32(index)*48, 1120, 40}
}

point_in_rect :: proc(p: rl.Vector2, r: rl.Rectangle) -> bool {
	return p.x >= r.x && p.x <= r.x+r.width && p.y >= r.y && p.y <= r.y+r.height
}
