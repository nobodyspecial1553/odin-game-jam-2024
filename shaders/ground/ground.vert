#version 460

const vec3[6] vertices = vec3[6](
	vec3(0.5, 0, -0.5),
	vec3(-0.5, 0, -0.5),
	vec3(-0.5, 0, 0.5),
	vec3(0.5, 0, -0.5),
	vec3(-0.5, 0, 0.5),
	vec3(0.5, 0, 0.5)
);

const vec2[6] uvs = vec2[6](
	/*
	vec2(1, 0),
	vec2(0, 0),
	vec2(0, 1),
	vec2(1, 0),
	vec2(0, 1),
	vec2(1, 1)
	*/
	vec2(0.5, -0.5),
	vec2(-0.5, -0.5),
	vec2(-0.5, 0.5),
	vec2(0.5, -0.5),
	vec2(-0.5, 0.5),
	vec2(0.5, 0.5)
);

layout(set = 0, binding = 0) uniform Screen_Space {
	mat4 mvp;
	vec2 ground_scale;
	vec2 cam_pos; // y is z
	float rotation;
} screen_space;

layout(location = 0) out vec2 out_uv;

void main(void) {
	const vec3 vertex = vertices[gl_VertexIndex];
	vec4 verts = vec4(vertex.x * screen_space.ground_scale.x, vertex.y, vertex.z * screen_space.ground_scale.y, 1);
	gl_Position = screen_space.mvp * verts;

	mat2 rot = mat2(
		cos(screen_space.rotation), sin(screen_space.rotation),
		-sin(screen_space.rotation), cos(screen_space.rotation)
	);
	out_uv = (rot * uvs[gl_VertexIndex]) * screen_space.ground_scale + vec2(screen_space.cam_pos.x, -screen_space.cam_pos.y) / 2;
}

