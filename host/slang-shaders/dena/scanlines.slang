#version 450
// Scanlines: darkens the gaps between the source's rows, with a soft beam
// profile so it stays even at non-integer scales. Slang port of
// host/shaders/scanlines (the phone version).
// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shader-stacks.md

layout(push_constant) uniform Push
{
	vec4 SourceSize;
	vec4 OutputSize;
	float SCANLINE_STRENGTH;
	float SCANLINE_BRIGHTNESS;
} params;

#pragma parameter SCANLINE_STRENGTH "Scanline strength" 0.45 0.0 1.0 0.05
#pragma parameter SCANLINE_BRIGHTNESS "Brightness boost" 1.15 1.0 1.5 0.05

layout(std140, set = 0, binding = 0) uniform UBO
{
	mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
	gl_Position = global.MVP * Position;
	vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

void main()
{
	vec3 color = texture(Source, vTexCoord).rgb;
	// Distance from the centre of the source row: 0 at the beam, 0.5 between rows.
	float row = vTexCoord.y * params.SourceSize.y;
	float d = abs(fract(row) - 0.5);
	float beam = 1.0 - params.SCANLINE_STRENGTH * smoothstep(0.15, 0.5, d);
	FragColor = vec4(min(color * beam * params.SCANLINE_BRIGHTNESS, vec3(1.0)), 1.0);
}
