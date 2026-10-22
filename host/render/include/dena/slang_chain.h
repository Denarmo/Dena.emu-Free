// Multi-pass slang shader chain on desktop GL 4.2+ (Windows and Linux PCs):
// framebuffer per pass, lookup textures, frame history and feedback, uniforms
// filled by name. Every call needs the GL context current on this thread.
// Spec: docs/specs/shader-stacks.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "dena/gl_api.h"
#include "dena/slang_preset.h"

namespace dena {
namespace slang {

// The frame-generation hook (shader-stacks.md): runs between the core's frame
// and pass 0 on every drawn frame. It gets the source texture (row 0 = the
// picture's top) and may hand back another texture it owns, with its size;
// the chain then shades that as Original. Returning `tex` keeps the frame.
class SourceFilter {
 public:
  virtual ~SourceFilter() = default;
  virtual GLuint filter(const Gl &gl, GLuint tex, unsigned *w, unsigned *h) = 0;
};

class SlangChain {
 public:
  SlangChain();
  ~SlangChain();  // GL objects must already be gone (release())
  SlangChain(const SlangChain &) = delete;
  SlangChain &operator=(const SlangChain &) = delete;

  // Loads GL through proc and checks for GL 4.2. False with a message.
  bool init(ProcAddress proc, std::string *err);
  bool ready() const { return ready_; }
  int glsl_version() const { return glsl_version_; }
  const Gl &gl() const { return gl_; }

  // Compiles a .slangp. On failure the previous preset stays loaded.
  bool load(const std::string &path, std::string *err);
  void unload();
  bool loaded() const { return pipe_ != nullptr; }
  // Deletes every GL object (before the context goes).
  void release();

  // The game's native picture size (shaders.md, Native lines); 0 = unknown.
  void set_native_size(unsigned w, unsigned h) { native_w_ = w, native_h_ = h; }
  void set_direction(int d) { direction_ = d < 0 ? -1 : 1; }
  void set_fps(float fps) { fps_ = fps; }
  void set_source_filter(SourceFilter *f) { filter_ = f; }

  // The frame to shade: XRGB8888 pixels (top row first), or a region of a
  // GL framebuffer (flipped when its rows start at the bottom).
  bool upload(const uint32_t *xrgb, unsigned w, unsigned h);
  bool copy_from(GLuint fbo, unsigned w, unsigned h, bool bottom_left);
  // Shades the last uploaded frame into a vp_w x vp_h output. GL state the
  // chain touches is restored afterwards.
  bool render(unsigned vp_w, unsigned vp_h);
  // As render(), from a texture of the caller's (tests).
  bool render_texture(GLuint tex, unsigned w, unsigned h, unsigned vp_w, unsigned vp_h);

  GLuint output_framebuffer() const;
  unsigned output_width() const;
  unsigned output_height() const;
  // The output as 0xAARRGGBB, top row first.
  bool read_output(std::vector<uint32_t> *out);

  size_t pass_count() const;
  unsigned pass_width(size_t i) const;
  unsigned pass_height(size_t i) const;
  const Preset *preset() const;
  uint64_t frame_count() const { return frame_count_; }

  struct Pipeline;  // compiled passes and their targets (slang_chain.cpp)

 private:
  bool ensure_source(unsigned w, unsigned h);
  GLuint sampler(bool linear, bool mipmap, Wrap wrap);
  bool draw(GLuint tex, unsigned w, unsigned h, unsigned vp_w, unsigned vp_h);

  Gl gl_;
  bool ready_ = false;
  int glsl_version_ = 0;
  std::unique_ptr<Pipeline> pipe_;
  GLuint vao_ = 0, vbo_ = 0, black_ = 0;
  GLuint src_tex_ = 0, src_fbo_ = 0;
  unsigned src_w_ = 0, src_h_ = 0, src_alloc_w_ = 0, src_alloc_h_ = 0;
  unsigned src_levels_ = 0;
  GLuint samplers_[2][2][4] = {};
  unsigned native_w_ = 0, native_h_ = 0;
  int direction_ = 1;
  float fps_ = 60.0f;
  uint64_t frame_count_ = 0;
  std::chrono::steady_clock::time_point last_time_{};
  SourceFilter *filter_ = nullptr;
};

}  // namespace slang
}  // namespace dena
