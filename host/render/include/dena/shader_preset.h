// libretro GLSL presets (.glslp) and single-file .glsl shaders: parsing and
// stage preparation. No GL here, so it is testable on every host.
// Spec: docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>
#include <vector>

namespace dena {

enum class ScaleType { kSource, kViewport, kAbsolute };
enum class WrapMode { kClampToEdge, kRepeat, kMirroredRepeat };

struct ShaderPass {
  std::string path;  // the pass's .glsl file
  std::string source;
  bool filter_linear = false;
  ScaleType scale_type_x = ScaleType::kSource, scale_type_y = ScaleType::kSource;
  float scale_x = 1.0f, scale_y = 1.0f;
  bool scale_set = false;  // the preset gave a scale type for this pass
  std::string alias;
  bool float_framebuffer = false;
  bool srgb_framebuffer = false;
  WrapMode wrap = WrapMode::kClampToEdge;
  unsigned frame_count_mod = 0;
};

struct ShaderParameter {
  std::string id, label;
  float value = 0, min = 0, max = 0, step = 0;
};

struct ShaderPreset {
  std::vector<ShaderPass> passes;
  std::vector<ShaderParameter> parameters;  // in first-seen order
};

// Reads path (.glslp, or .glsl as a one-pass preset) and every pass source.
// Returns false with a message in err.
bool parse_preset(const std::string &path, ShaderPreset *out, std::string *err);

// Adds the `#pragma parameter` lines of source to params (first one wins).
void parse_parameters(const std::string &source, std::vector<ShaderParameter> *params);

// Source for one stage ("VERTEX" or "FRAGMENT"): pragma lines stripped, the
// stage and PARAMETER_UNIFORM defined (after any #version line), and a
// default precision for fragment stages that have none. Empty when the source
// has no half for that stage (the caller uses a stock vertex shader).
std::string prepare_stage(const std::string &source, const char *stage);

// How many frame pixels make one native pixel (shaders.md, Native lines):
// the largest whole k with w >= k * native_w and h >= k * native_h, 1 to 8.
// 1 when the native size is unknown (0).
unsigned native_scale(unsigned w, unsigned h, unsigned native_w, unsigned native_h);

}  // namespace dena
