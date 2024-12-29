package game

import "base:runtime"

import "core:c"
import "core:fmt"

import "vendor:glfw"

input: struct {
	move: [3]f32,
	turn: [3]f32,
	interact: bool,
}

glfw_key_callback : glfw.KeyProc : proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	context = runtime.default_context()
	switch action {
	case glfw.PRESS:
		switch key {
		case glfw.KEY_W: input.move.z += 1
		case glfw.KEY_S: input.move.z -= 1
		case glfw.KEY_A: input.move.x -= 1
		case glfw.KEY_D: input.move.x += 1
		case glfw.KEY_LEFT: input.turn.y -= 1
		case glfw.KEY_RIGHT: input.turn.y += 1
		case glfw.KEY_SPACE, glfw.KEY_ENTER: input.interact = true
		}
	case glfw.RELEASE:
		switch key {
		case glfw.KEY_W: input.move.z -= 1
		case glfw.KEY_S: input.move.z += 1
		case glfw.KEY_A: input.move.x += 1
		case glfw.KEY_D: input.move.x -= 1
		case glfw.KEY_LEFT: input.turn.y += 1
		case glfw.KEY_RIGHT: input.turn.y -= 1
		case glfw.KEY_SPACE, glfw.KEY_ENTER: input.interact = false
		}
	}
}
