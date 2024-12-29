#version 460

#extension GL_EXT_nonuniform_qualifier : enable

const vec3[6] vertices = vec3[6](
	/*
	vec3(1, 0, 0),
	vec3(0, 0, 0),
	vec3(0, 1, 0),
	vec3(1, 0, 0),
	vec3(0, 1, 0),
	vec3(1, 1, 0)
	*/
	vec3(0, 1, 0),
	vec3(1, 1, 0),
	vec3(1, 0, 0),
	vec3(0, 1, 0),
	vec3(1, 0, 0),
	vec3(0, 0, 0)
);

const vec2[6] uvs = vec2[6](
	vec2(1, 0),
	vec2(0, 0),
	vec2(0, 1),
	vec2(1, 0),
	vec2(0, 1),
	vec2(1, 1)
);

layout(set = 0, binding = 0) uniform Fist {
	float aspect_ratio;
	int offset;
} fist;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out flat int offset;

void main(void) {
	gl_Position = vec4(vertices[gl_VertexIndex], 1);
	gl_Position.x /= fist.aspect_ratio;
	gl_Position.xyz = vec3(1, 1, 0) - gl_Position.xyz;
	out_uv = uvs[gl_VertexIndex];
	offset = fist.offset;
}

