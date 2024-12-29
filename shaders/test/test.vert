#version 460

const vec3[6] vertices = vec3[6](
	vec3(1, -1, 1),
	vec3(-1, -1, 1),
	vec3(-1, 1, 1),
	vec3(1, -1, 1),
	vec3(-1, 1, 1),
	vec3(1, 1, 1)
);

void main(void) {
	gl_Position = vec4(vertices[gl_VertexIndex].xy * 0.5, 0, 1);
}
