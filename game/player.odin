package game

import "core:fmt"
import "core:math/linalg"
import sa "core:container/small_array"
import "core:time"
import "core:math/rand"

Player :: struct {
	pos: [3]f32,
	rot: f32,
	attack_timestamp: time.Time,
}

PLAYER_SPEED :: 8
PLAYER_ROT_SPEED :: 180
PLAYER_ATTACK_COOLDOWN :: 500

player_update :: proc(player: ^Player) {
	player.rot += input.turn.y * PLAYER_ROT_SPEED * gfx.delta_time

	move_x := input.move.x * PLAYER_SPEED * gfx.delta_time
	move_z := input.move.z * PLAYER_SPEED * gfx.delta_time

	player_rot_rads := linalg.to_radians(player.rot)
	player.pos.x += linalg.cos(player_rot_rads) * move_x + linalg.sin(player_rot_rads) * move_z
	player.pos.z -= linalg.cos(player_rot_rads) * move_z - linalg.sin(player_rot_rads) * move_x

	attack: if input.interact {
		if time.duration_milliseconds(time.diff(player.attack_timestamp, time.now())) > PLAYER_ATTACK_COOLDOWN {
			hit_an_entity: bool = false

			PLAYER_ATTACK_RADIUS :: 2.5
			PLAYER_ATTACK_OFFSET :: 1

			player_rot_rads += linalg.PI
			attack_pos := player.pos
			attack_pos.x += linalg.cos(player_rot_rads) * PLAYER_ATTACK_OFFSET - linalg.sin(player_rot_rads) * PLAYER_ATTACK_OFFSET
			attack_pos.z += linalg.cos(player_rot_rads) * PLAYER_ATTACK_OFFSET + linalg.sin(player_rot_rads) * PLAYER_ATTACK_OFFSET
			for &entity in sa.slice(&p.entities) {
				if linalg.abs(linalg.distance(entity.pos, attack_pos)) < PLAYER_ATTACK_RADIUS {
					entity_punch(&entity, player.rot + 180)
					if !hit_an_entity {
						sounds := []string {
							"sounds/hit1.wav",
							"sounds/hit2.wav",
							"sounds/hit3.wav",
							"sounds/hit4.wav",
						}
						audio_play(rand.choice(sounds))
						hit_an_entity = true
					}
				}
			}
			player.attack_timestamp = time.now()

			if !hit_an_entity {
				audio_play("sounds/whoosh.wav")
			}
		}
	}
}

player_generate_camera :: proc "contextless" (player: Player) -> Camera {
	return Camera {
		pos = { 0, 1, 0 },
		rot = { 0, player.rot, 0},
	}
}
