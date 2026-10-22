// Multi-pass shader chain (libretro GLSL presets) for GLES 3.
// Spec: docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <GLES3/gl3.h>

#include <string>
#include <vector>

#include "dena/shader_preset.h"

namespace dena {

class ShaderChain {
 public:
  ShaderChain() = default;
  ShaderChain(const ShaderChain &) = delete;
  ShaderChain &operator=(const ShaderChain &) = delete;
  ~ShaderChain() { unload(); }

  // Compiles preset in the current context. On failure nothing stays loaded.
  bool load(const ShaderPreset &preset, std::string *err);
  void unload();
  bool loaded() const { return !passes_.empty(); }
  // Exchanges GL objects and state (load the next chain, then swap it in);
  // the native size stays with each object.
  void swap(ShaderChain &other) noexcept;

  // Draws source (w x h, row 0 = top of the picture) through every pass into
  // target_fbo's (x, y, vp_w, vp_h) viewport. flip_y puts the picture's top
  // at the viewport's top in GL coordinates (window surfaces); without it the
  // top lands on row 0 of the target (framebuffers read back top-down).
  void render(GLuint source, unsigned w, unsigned h, GLuint target_fbo, int x, int y,
              unsigned vp_w, unsigned vp_h, bool flip_y);

  // The game's native picture size (0 x 0: unknown). A source k times that
  // size (an upscaled or doubled core) is drawn as native: size uniforms and
  // source-scaled passes use source / k, so scanlines and masks follow the
  // game's own lines (shaders.md, Native lines).
  void set_native_size(unsigned w, unsigned h) {
    native_w_ = w;
    native_h_ = h;
  }

  // Frame counter direction for FrameDirection (-1 while rewinding).
  void set_direction(int d) { direction_ = d; }
  // Seconds since start, for SweepPhase; the caller's clock keeps tests stable.
  void set_time(double seconds) { time_ = seconds; }

  const std::vector<ShaderParameter> &parameters() const { return params_; }
  bool set_parameter(const std::string &id, float value);

 private:
  // A uniform's location and declared type (shaders differ, e.g. int or
  // float FrameCount).
  struct Uni {
    GLint loc = -1;
    GLenum type = 0;
  };
  struct Uniforms {
    Uni texture, source, texture_size, input_size, output_size;
    Uni orig, original, orig_texture_size, orig_input_size;
    Uni frame_count, frame_direction, mvp, sweep;
    std::vector<Uni> params;                 // per params_ entry
    std::vector<Uni> prev_tex, prev_size;    // PassPrevK, K = 1..index+1
    std::vector<Uni> alias_tex, alias_size;  // per earlier pass, by its alias
  };
  struct Pass {
    ShaderPass cfg;
    GLuint program = 0;
    GLuint fbo = 0, tex = 0;  // output (not for the last pass)
    unsigned out_w = 0, out_h = 0;
    GLenum format = GL_RGBA8;
    Uniforms u;
  };

  GLuint compile_program(const std::string &vs, const std::string &fs, std::string *err);
  void lookup_uniforms(Pass &p, size_t index);
  bool ensure_targets(unsigned w, unsigned h, unsigned vp_w, unsigned vp_h);
  GLuint sampler(bool linear, WrapMode wrap);

  std::vector<Pass> passes_;
  std::vector<ShaderParameter> params_;
  GLuint vbo_ = 0, vao_ = 0;
  GLuint samplers_[2][3] = {};
  unsigned src_w_ = 0, src_h_ = 0, vp_w_ = 0, vp_h_ = 0;
  unsigned native_w_ = 0, native_h_ = 0;
  unsigned frame_count_ = 0;
  int direction_ = 1;
  double time_ = 0;
};

}  // namespace dena
