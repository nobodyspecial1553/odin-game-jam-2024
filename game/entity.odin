package game

import "core:fmt"
import "core:log"
import sa "core:container/small_array"
import "core:math/rand"
import "core:math/linalg"

ENTITY_SPEED :: 2

Entity_State :: enum {
	Still = 0,
	Moving,
	Punched,
}

Entity_State_Still :: struct {}

ENTITY_MOVING_DESTINATION_RADIUS :: 1
ENTITY_MOVING_DESTINATION_DISTANCE_MAX :: 5
Entity_State_Moving :: struct {
	destination: [3]f32,
}

ENTITY_PUNCHED_FORCE_INITIAL :: 3.5
ENTITY_PUNCHED_SPEED :: 50
Entity_State_Punched :: struct {
	force: f32,
	direction: f32,
}

Entity :: struct {
	pos: [3]f32,
	state_tag: Entity_State,
	state: struct #raw_union {
		still: Entity_State_Still,
		moving: Entity_State_Moving,
		punched: Entity_State_Punched,
	}
}

entity_update :: proc(entity: ^Entity) {
	switch entity.state_tag {
	case .Still:
		still := &entity.state.still
		if rand.int_max(gfx.last_updates_peak * 20) == 0 {
			moving := &entity.state.moving
			moving.destination.x = entity.pos.x + rand.float32_range(-ENTITY_MOVING_DESTINATION_DISTANCE_MAX, ENTITY_MOVING_DESTINATION_DISTANCE_MAX)
			moving.destination.z = entity.pos.z + rand.float32_range(-ENTITY_MOVING_DESTINATION_DISTANCE_MAX, ENTITY_MOVING_DESTINATION_DISTANCE_MAX)
			entity.state_tag = .Moving
			break
		}
	case .Moving:
		moving := &entity.state.moving
		move: [3]f32
		if linalg.distance(moving.destination, entity.pos) > ENTITY_MOVING_DESTINATION_RADIUS {
			direction := moving.destination - entity.pos
			move.x = clamp(direction.x, -ENTITY_SPEED, ENTITY_SPEED)
			move.z = clamp(direction.z, -ENTITY_SPEED, ENTITY_SPEED)
			entity.pos += move * gfx.delta_time
		}
		else {
			entity.state_tag = .Still
			break
		}
	case .Punched:
		punched := &entity.state.punched

		direction: [3]f32
		direction.x = -linalg.sin(linalg.to_radians(punched.direction)) * ENTITY_PUNCHED_SPEED
		direction.z = linalg.cos(linalg.to_radians(punched.direction)) * ENTITY_PUNCHED_SPEED

		move: [3]f32
		move.x = direction.x
		move.z = direction.z
		move *= gfx.delta_time
		entity.pos += move

		punched.force -= linalg.abs(linalg.distance(move, [3]f32{}))
		if punched.force <= 0.1 {
			entity.state_tag = .Still
		}
	}
}

entity_punch :: proc(entity: ^Entity, direction: f32) {
	entity.state_tag = .Punched
	punched := &entity.state.punched
	punched.direction = direction
	punched.force = ENTITY_PUNCHED_FORCE_INITIAL
}
