// SPDX-License-Identifier: GPL-3.0-or-later
// GL on the emulator thread in the launcher: an EGL context shared with the
// engine's. GPU cores render into its framebuffer; with a shader, software
// frames are drawn through it too. Every frame lands in one of three
// textures the engine shows as the game texture.
// Spec: docs/specs/handheld-session.md, hw-render.md, shaders.md
#ifndef DENA_GL_TARGET_H
#define DENA_GL_TARGET_H

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include "dena/shader_chain.h"
#include "slot_mailbox.h"

namespace dena {

struct GlShare {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;  // the engine's resource context
};

class GlTarget {
 public:
  // Emulator thread: creates the context (left current) and the textures.
  bool init_context(const GlShare &share);
  // init_context plus a max_w x max_h framebuffer for a GPU core.
  bool init(const GlShare &share, unsigned max_w, unsigned max_h, bool depth, bool stencil);
  bool ready() const { return ctx_ != EGL_NO_CONTEXT; }
  uintptr_t framebuffer() const { return fbo_; }
  static void *proc_address(const char *sym);

  // Shaders (shaders.md). "" unloads; a broken preset keeps the current one.
  bool set_shader(const std::string &path, std::string *err);
  bool has_shader() const { return chain_.loaded(); }
  void set_direction(int d) { chain_.set_direction(d); }
  // The largest picture a shader draws (the screen), in pixels.
  void set_output_limit(unsigned w, unsigned h) { limit_w_ = w, limit_h_ = h; }

  // Emulator thread: the GPU core's w x h frame into the next texture.
  bool present(unsigned w, unsigned h, bool bottom_left);
  // Emulator thread: a 0x00RRGGBB software frame through the shader.
  bool present_pixels(const uint32_t *xrgb, unsigned w, unsigned h);
  // Emulator thread: the GPU frame as 0x00RRGGBB, top row first.
  bool read_pixels(unsigned w, unsigned h, bool bottom_left, std::vector<uint32_t> &out);
  void shutdown();

  // Raster thread: the newest texture, 0 when none (also after shutdown).
  GLuint take(uint32_t *w, uint32_t *h);

 private:
  void ensure_source(unsigned w, unsigned h, bool swizzle);
  void ensure_slot(int b, unsigned w, unsigned h);
  void render_to_slot(unsigned w, unsigned h);
  void publish();

  EGLDisplay dpy_ = EGL_NO_DISPLAY;
  EGLContext ctx_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  GLuint fbo_ = 0, color_ = 0, depth_rb_ = 0;  // the GPU core's framebuffer
  GLuint src_tex_ = 0, src_fbo_ = 0;            // shader input, row 0 = top
  unsigned src_w_ = 0, src_h_ = 0;
  bool src_swizzle_ = false;
  GLuint slot_tex_[3] = {}, slot_fbo_[3] = {};
  uint32_t slot_w_[3] = {}, slot_h_[3] = {};
  SlotMailbox slots_;
  std::atomic<bool> live_{false};
  ShaderChain chain_;
  std::chrono::steady_clock::time_point chain_start_;
  unsigned limit_w_ = 0, limit_h_ = 0;
};

// Integer scale of a w x h picture that fits limit_w x limit_h (at least 1).
unsigned shader_scale(unsigned w, unsigned h, unsigned limit_w, unsigned limit_h);

}  // namespace dena

#endif
