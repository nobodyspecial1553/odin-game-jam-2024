#version 460

#extension GL_EXT_nonuniform_qualifier : enable

layout(location = 0) in vec2 in_uv;
layout(location = 1) in flat int offset;

layout(set = 0, binding = 1) uniform sampler general_sampler;
layout(set = 1, binding = 0) uniform texture2D[] textures;

layout(location = 0) out vec4 frag_color;

void main(void) {
	frag_color = texture(sampler2D(textures[0], general_sampler), vec2(in_uv.x * 0.5 + 0.5 * float(offset), in_uv.y));
}
