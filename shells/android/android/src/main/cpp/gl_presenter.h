// GPU path: EGL context, offscreen framebuffer for hardware-rendered cores,
// software frames uploaded to a texture, and the picture drawn to the game's
// window with a plain blit or a shader chain.
// Spec: docs/specs/hw-render.md, docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/native_window.h>

#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

#include "dena/shader_chain.h"

class GlPresenter {
 public:
  ~GlPresenter() { shutdown(); }

  // Creates the context (current on the calling thread) and a framebuffer of
  // max_w x max_h. Must run on the thread that will run the core.
  bool init(unsigned max_w, unsigned max_h, bool depth, bool stencil);
  // Context only, for software cores drawn through GLES (shaders.md).
  bool init_context();
  bool ready() const { return context_ != EGL_NO_CONTEXT; }

  // The framebuffer handed to the core (libretro get_current_framebuffer).
  uintptr_t framebuffer() const { return fbo_; }
  static void *proc_address(const char *sym);

  // Switches the window surface (nullptr releases it). Emulator thread.
  void set_window(ANativeWindow *window);

  // Draws the w x h area of the framebuffer to the window and swaps.
  void present(unsigned w, unsigned h, bool flip_y);
  // Uploads a software frame (0x00RRGGBB, top row first), draws it and swaps.
  void present_pixels(const uint32_t *pixels, unsigned w, unsigned h);

  // Loads a .glslp/.glsl preset; "" turns the chain off. On failure the
  // previous chain stays and err says why.
  bool set_shader(const std::string &path, std::string *err);
  bool has_shader() const { return chain_.loaded(); }
  // Filter upscale (shaders.md, Upscale): software frames are first drawn at
  // factor x their size through the preset at path (xBRZ), then through the
  // shader or the plain blit as an upscaled picture. 0 (or "") turns it off.
  bool set_prescale(const std::string &path, unsigned factor, std::string *err);
  // The game's native size for the shader (shaders.md, Native lines).
  void set_native_size(unsigned w, unsigned h) { chain_.set_native_size(w, h); }
  // -1 while rewinding (FrameDirection).
  void set_direction(int d) { chain_.set_direction(d); }

  // Reads the w x h area back as 0x00RRGGBB, top row first.
  bool read_pixels(unsigned w, unsigned h, bool flip_y, std::vector<uint32_t> &out);

  void shutdown();

 private:
  bool build_blit_program();
  bool make_window_current(EGLint *w, EGLint *h);
  void draw_blit(GLuint tex, float su, float sv, EGLint w, EGLint h);
  void ensure_source(unsigned w, unsigned h, bool swizzle);
  void ensure_prescaled(unsigned w, unsigned h);
  void finish_frame();
  // Undoes state a GPU core leaves behind that our draws and reads depend on.
  void reset_core_state();

  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLConfig config_ = nullptr;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface pbuffer_ = EGL_NO_SURFACE;  // keeps the context current without a window
  EGLSurface window_surface_ = EGL_NO_SURFACE;
  ANativeWindow *window_ = nullptr;

  GLuint fbo_ = 0, color_ = 0, depth_rb_ = 0;
  unsigned fb_w_ = 0, fb_h_ = 0;
  GLuint program_ = 0, vao_ = 0;
  GLint uv_scale_loc_ = -1;

  // The chain's input: the picture with row 0 at the top. Software frames
  // land here directly (swizzled to read 0x00RRGGBB as RGB); GPU frames are
  // copied in from fbo_.
  GLuint src_tex_ = 0, src_fbo_ = 0;
  unsigned src_w_ = 0, src_h_ = 0;
  bool src_swizzle_ = false;
  dena::ShaderChain chain_;
  // Filter upscale: its chain and the factor x frame-size picture it draws.
  dena::ShaderChain pre_;
  unsigned pre_factor_ = 0;
  GLuint pre_tex_ = 0, pre_fbo_ = 0;
  unsigned pre_w_ = 0, pre_h_ = 0;
  std::chrono::steady_clock::time_point chain_start_;
};
