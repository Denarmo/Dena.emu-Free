// Scanlines: darkens the gaps between the source's rows, with a soft beam
// profile so it stays even at non-integer scales.
// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shaders.md

#pragma parameter SCANLINE_STRENGTH "Scanline strength" 0.45 0.0 1.0 0.05
#pragma parameter SCANLINE_BRIGHTNESS "Brightness boost" 1.15 1.0 1.5 0.05

#if defined(VERTEX)

attribute vec4 VertexCoord;
attribute vec4 TexCoord;
varying vec2 uv;
uniform mat4 MVPMatrix;

void main() {
  gl_Position = MVPMatrix * VertexCoord;
  uv = TexCoord.xy;
}

#elif defined(FRAGMENT)

#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

uniform sampler2D Texture;
uniform vec2 TextureSize;
uniform vec2 InputSize;
varying vec2 uv;

#ifdef PARAMETER_UNIFORM
uniform float SCANLINE_STRENGTH;
uniform float SCANLINE_BRIGHTNESS;
#else
#define SCANLINE_STRENGTH 0.45
#define SCANLINE_BRIGHTNESS 1.15
#endif

void main() {
  vec3 color = texture2D(Texture, uv).rgb;
  // Distance from the centre of the source row: 0 at the beam, 0.5 between rows.
  float row = uv.y * TextureSize.y;
  float d = abs(fract(row) - 0.5);
  float beam = 1.0 - SCANLINE_STRENGTH * smoothstep(0.15, 0.5, d);
  gl_FragColor = vec4(min(color * beam * SCANLINE_BRIGHTNESS, 1.0), 1.0);
}

#endif
