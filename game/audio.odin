package game

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import ma "vendor:miniaudio"

ma_engine: ma.engine

sounds: map[string]ma.sound

audio_init :: proc() {
	if ma.engine_init(nil, &ma_engine) != .SUCCESS {
		log.panic("Unable to intialize miniaudio engine!")
	}

	/*
	dir_fd, dir_fd_error := os.open("sounds/")
	if dir_fd_error != nil {
		log.panicf("Error opening sounds directory: \"%v\"", dir_fd_error)
	}
	defer os.close(dir_fd)

	file_infos, file_infos_error := os.read_dir(dir_fd, -1, context.temp_allocator)
	if file_infos_error != nil {
		log.panicf("Error reading sounds directory: \"%v\"", file_infos_error)
	}

	for file_info in file_infos {
		file_path := strings.clone_to_cstring(file_info.fullpath)
		fmt.printfln("Full Path for Audio: \"%s\"", file_path)
		// We're going to "leak" the sounds
		sound: ma.sound = ---
		if load_sound_error := ma.sound_init_from_file(&ma_engine, file_path, 0, nil, nil, &sound); load_sound_error != .SUCCESS {
			log.panicf("Unable to load audio: \"%v\"; Error: %v", file_path, load_sound_error)
		}
		sounds[string(file_path)] = sound
	}
	*/
}

audio_destroy :: proc() {
	ma.engine_uninit(&ma_engine)
}

audio_play :: proc(audio_file: string) {
	ma.engine_play_sound(&ma_engine, strings.unsafe_string_to_cstring(audio_file), nil)
}
