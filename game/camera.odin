package game

import "core:math/linalg"

Camera :: struct {
	pos: [3]f32,
	rot: [3]f32,
}

camera_get_view_matrix :: proc(camera: Camera) -> matrix[4, 4]f32 {
	cam_pos := camera.pos
	cam_pos.z = -cam_pos.z
	cam_pos.x = -cam_pos.x
	cam_pos.y = -cam_pos.y

	eye := cam_pos

	cam_rot_rads := linalg.to_radians(camera.rot)
	orientation := [3]f32 {
		linalg.sin(cam_rot_rads.y),
		-linalg.sin(cam_rot_rads.x),
		-linalg.cos(cam_rot_rads.y),
	}
	center := cam_pos + orientation

	up := [3]f32 { 0, 1, 0 }

	return linalg.matrix4_look_at_f32(eye, center, up)
}
