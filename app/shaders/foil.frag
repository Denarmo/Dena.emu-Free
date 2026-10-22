// SPDX-License-Identifier: GPL-3.0-or-later
// Metallic foil reflection over a game cover. Spec: docs/specs/foil-covers.md
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec2 uTilt; // -1..1 from the sensor; the idle sweep goes past ±1

out vec4 fragColor;

float hash(float n) { return fract(sin(n) * 43758.5453); }

void main() {
  vec2 px = FlutterFragCoord().xy;
  vec2 uv = px / uSize;
  // Distance across the cover along the light's diagonal (-0.7..0.7), minus
  // where the reflection sits. Tilt slides it from corner to corner.
  float d = dot(uv - 0.5, vec2(0.6, 0.8));
  float x = d - (uTilt.x * 0.75 + uTilt.y * 0.35);

  // Sharp specular core plus a soft sheen around it.
  float core = exp(-x * x * 220.0);
  float sheen = exp(-x * x * 14.0);
  // Faint brushed-metal grain: hairline rows, only visible in the light.
  float grain = 0.88 + 0.24 * hash(floor(px.y));
  float s = (core * 0.26 + sheen * 0.06) * grain;

  // Light is near white with a touch of Dena Gold; a whisper of thin-film
  // colour on the sheen's edges keeps it from reading as flat white.
  vec3 film = 0.5 + 0.5 * cos(6.2832 * (x * 2.5 + vec3(0.0, 0.33, 0.67)));
  vec3 light = mix(vec3(1.0, 0.97, 0.88), film, 0.12 * (1.0 - core));

  // Away from the light the metal dims slightly, which sells the contrast.
  float shade = 0.07 * (1.0 - sheen);
  fragColor = vec4(light * s, shade + s * 0.4); // premultiplied
}
