package main

import "core:dynlib"
import "core:fmt"
import os "core:os/os2"
import "core:time"
import "core:log"

when ODIN_OS == .Linux {
	DYN_LIB_EXT :: "so"
}
else when ODIN_OS == .Windows {
	DYN_LIB_EXT :: "dll"
}
else {
	#panic("Unsupported OS!")
}

GAME_LIB_NAME :: "game"
GAME_LIB_NAME_SRC :: GAME_LIB_NAME + "." + DYN_LIB_EXT
Game_Lib :: struct {
	__handle: dynlib.Library,
	// Procs
	init: #type proc(gfx_ptr: rawptr, game_data: rawptr = nil),
	destroy: #type proc(),
	clean: #type proc(),
	get_game_data: #type proc() -> rawptr,
	draw: #type proc() -> bool,
	update: #type proc(),
	// Metadata
	iter: int,
	lib_name: string, // Needs deallocation
	modification_time: time.Time,
}

@(require_results)
reload_game_lib :: proc(game_lib: ^Game_Lib) -> (reloaded: bool, ok: bool) #optional_ok {
	game_lib_src_file_info, game_lib_src_file_info_get_error := os.stat(GAME_LIB_NAME_SRC, context.temp_allocator)
	if game_lib.modification_time._nsec >= game_lib_src_file_info.modification_time._nsec {
		reloaded = false
		ok = true
		return // Didn't need reload: success
	}
	time.sleep(time.Millisecond * 500) // Arbritray
	game_lib^ = load_game_lib(game_lib) or_return

	reloaded = true
	ok = true
	return
}

@(require_results)
load_game_lib :: proc(prev_game_lib: ^Game_Lib = nil) -> (game_lib: Game_Lib, ok: bool) #optional_ok {
	if prev_game_lib != nil {
		unload_game_lib(prev_game_lib) or_return
		game_lib = prev_game_lib^
	}

	game_lib.iter += 1
	game_lib.lib_name = fmt.aprintf(GAME_LIB_NAME + ".%v." + DYN_LIB_EXT, game_lib.iter)

	// Copy src to new lib_name dst
	copy_lib_error := os.copy_file(game_lib.lib_name, GAME_LIB_NAME_SRC)
	file_info, file_info_get_error := os.stat(game_lib.lib_name, context.temp_allocator)
	if file_info_get_error != nil {
		log.panic("Unable to get game lib file info!")
	}
	game_lib.modification_time = file_info.modification_time

	symbols_count, init_lib_ok := dynlib.initialize_symbols(&game_lib, game_lib.lib_name)
	if !init_lib_ok {
		return {}, false
	}

	return game_lib, true
}

unload_game_lib :: proc(game_lib: ^Game_Lib) -> (ok: bool) {
	if game_lib == nil {
		return true
	}
	if game_lib.__handle != nil {
		dynlib.unload_library(game_lib.__handle) or_return
		game_lib.__handle = nil
	}

	os.remove(game_lib.lib_name)
	delete(game_lib.lib_name)
	game_lib.lib_name = ""

	return true
}
