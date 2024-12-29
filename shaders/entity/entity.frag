#version 460

#extension GL_EXT_nonuniform_qualifier : enable

layout(location = 0) in vec2 in_uv;

layout(set = 0, binding = 1) uniform sampler general_sampler;
layout(set = 1, binding = 0) uniform texture2D[] textures_2D;

layout(location = 0) out vec4 frag_color;

void main(void) {
	frag_color = texture(sampler2D(textures_2D[0], general_sampler), in_uv);
	if(frag_color.a != 1){
		discard;
	}
}
