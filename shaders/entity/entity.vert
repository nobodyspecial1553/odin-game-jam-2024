#version 460

#extension GL_EXT_nonuniform_qualifier : enable

const vec3[6] vertices = vec3[6](
	vec3(1, -1, 0),
	vec3(-1, -1, 0),
	vec3(-1, 1, 0),
	vec3(1, -1, 0),
	vec3(-1, 1, 0),
	vec3(1, 1, 0)
);

const vec2[6] uvs = vec2[6](
	vec2(1, 0),
	vec2(0, 0),
	vec2(0, 1),
	vec2(1, 0),
	vec2(0, 1),
	vec2(1, 1)
);

layout(set = 0, binding = 0) readonly buffer Screen_Space {
	mat4 mvp[];
} screen_space;

layout(location = 0) out vec2 out_uv;

void main(void) {
	gl_Position = screen_space.mvp[gl_InstanceIndex] * vec4(vertices[gl_VertexIndex], 1);
	out_uv = uvs[gl_VertexIndex];
}

