package main

import "core:fmt"
import "core:time"
import "core:mem"
import "core:log"

import "vendor:glfw"
import vk "vendor:vulkan"

import vkjs "vkjumpstart"

main :: proc() {
	when ODIN_DEBUG {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, context.allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)
		defer {
			if len(tracking_allocator.allocation_map) > 0 {
				fmt.eprint("\n--== Memory Leaks ==--\n")
				fmt.eprintf("Total Leaks: %v\n", len(tracking_allocator.allocation_map))
				for _, leak in tracking_allocator.allocation_map {
					fmt.eprintf("Leak: %v bytes @%v\n", leak.size, leak.location)
				}
			}
			if len(tracking_allocator.bad_free_array) > 0 {
				fmt.eprint("\n--== Bad Frees ==--\n")
				for bad_free in tracking_allocator.bad_free_array {
					fmt.eprintf("Bad Free: %p @%v\n", bad_free.memory, bad_free.location)
				}
			}
		}
	}

	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)
	defer log.destroy_console_logger(context.logger)

	if !glfw.Init() {
		log.panic("Unable to initialize GLFW!")
	}
	defer glfw.Terminate()
	gfx_init()

	game, game_lib_success := load_game_lib()
	if !game_lib_success {
		log.panic("Failed to load game lib!")
	}
	game.init(&gfx)

	target_fps := f64(1) / 144
	time.stopwatch_start(&gfx.timer)

	gfx.last_updates_peak = 100_000
	updates: int
	frames: int

	current_time := time.duration_seconds(time.stopwatch_duration(gfx.timer))
	prev_time := current_time
	prev_second := current_time

	// Main loop
	free_all(context.temp_allocator)
	for !glfw.WindowShouldClose(gfx.window) {
		when ODIN_DEBUG {
			game_data := game.get_game_data()
			reloaded_game_lib, game_lib_reload_success := reload_game_lib(&game)
			if reloaded_game_lib {
				if !game_lib_reload_success {
					log.panic("Failed to reload game lib!")
				}
				game.init(&gfx, game_data)
				log.infof("\"%s\" reloaded!", game.lib_name)
			}
		}
		// Update
		last_time := current_time
		for current_time - prev_time < target_fps {
			game.update()
			updates += 1

			current_time = time.duration_seconds(time.stopwatch_duration(gfx.timer))
			gfx.delta_time = f32(current_time - last_time)
			last_time = current_time
			// Not a great way to make sure it doens't update too much, but this is game jam shit!
			time.sleep(time.Millisecond * 2)
		}
		prev_time = current_time
		// Render
		if game.draw() {
			frames += 1
		}
		else {
			gfx_recreate_swapchain()
		}
		// End of frame
		if current_time - prev_second > 1 {
			log.debugf("FPS: %v; Updates: %v", frames, updates)
			frames = 0
			gfx.last_updates_peak = updates
			updates = 0
			prev_second = current_time
		}
		glfw.PollEvents()
		free_all(context.temp_allocator)
	}

	game.clean()
	game.destroy()
	unload_game_lib(&game)

	gfx_clean()
}

