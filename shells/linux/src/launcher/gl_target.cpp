// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-session.md, hw-render.md, shaders.md
#include "gl_target.h"

#include <EGL/eglext.h>

#include <algorithm>
#include <cstdio>

#include "dena/shader_preset.h"

namespace dena {

namespace {

void log_error(const char *what) { std::fprintf(stderr, "dena: GPU: %s\n", what); }

}  // namespace

unsigned shader_scale(unsigned w, unsigned h, unsigned limit_w, unsigned limit_h) {
  if (!w || !h || !limit_w || !limit_h) return 1;
  return std::max(1u, std::min(limit_w / w, limit_h / h));
}

bool GlTarget::init_context(const GlShare &share) {
  if (ready()) return true;
  dpy_ = share.display;
  static const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                                 EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                                 EGL_NONE};
  EGLConfig config;
  EGLint n = 0;
  if (!eglChooseConfig(dpy_, attrs, &config, 1, &n) || n < 1) {
    log_error("no GLES 3 config");
    return false;
  }
  static const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  ctx_ = eglCreateContext(dpy_, config, share.context, ctx_attrs);
  if (ctx_ == EGL_NO_CONTEXT) {
    log_error("no GLES 3 context shared with the UI");
    return false;
  }
  // Surfaceless where the driver allows it, else a 1x1 pbuffer.
  if (!eglMakeCurrent(dpy_, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx_)) {
    static const EGLint pb[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    surface_ = eglCreatePbufferSurface(dpy_, config, pb);
    if (surface_ == EGL_NO_SURFACE || !eglMakeCurrent(dpy_, surface_, surface_, ctx_)) {
      log_error("cannot make the context current");
      shutdown();
      return false;
    }
  }
  glGenTextures(3, slot_tex_);
  glGenFramebuffers(3, slot_fbo_);
  slots_.clear();
  live_ = true;
  return true;
}

bool GlTarget::init(const GlShare &share, unsigned max_w, unsigned max_h, bool depth,
                    bool stencil) {
  if (!init_context(share)) return false;
  glGenTextures(1, &color_);
  glBindTexture(GL_TEXTURE_2D, color_);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(max_w), GLsizei(max_h));
  glGenFramebuffers(1, &fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color_, 0);
  if (depth || stencil) {
    glGenRenderbuffers(1, &depth_rb_);
    glBindRenderbuffer(GL_RENDERBUFFER, depth_rb_);
    glRenderbufferStorage(GL_RENDERBUFFER, stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24,
                          GLsizei(max_w), GLsizei(max_h));
    glFramebufferRenderbuffer(GL_FRAMEBUFFER,
                              stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                              GL_RENDERBUFFER, depth_rb_);
  }
  bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (!complete) {
    log_error("framebuffer incomplete");
    shutdown();
    return false;
  }
  return true;
}

void *GlTarget::proc_address(const char *sym) {
  return reinterpret_cast<void *>(eglGetProcAddress(sym));
}

bool GlTarget::set_shader(const std::string &path, std::string *err) {
  if (!ready()) {
    *err = "no GL context";
    return false;
  }
  if (path.empty()) {
    chain_.unload();
    return true;
  }
  ShaderPreset preset;
  if (!parse_preset(path, &preset, err)) return false;
  ShaderChain next;  // a broken shader leaves the current one
  if (!next.load(preset, err)) return false;
  chain_.swap(next);
  chain_start_ = std::chrono::steady_clock::now();
  return true;
}

void GlTarget::ensure_source(unsigned w, unsigned h, bool swizzle) {
  if (src_tex_ && w == src_w_ && h == src_h_ && swizzle == src_swizzle_) return;
  if (src_fbo_) glDeleteFramebuffers(1, &src_fbo_);
  if (src_tex_) glDeleteTextures(1, &src_tex_);
  glGenTextures(1, &src_tex_);
  glBindTexture(GL_TEXTURE_2D, src_tex_);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(w), GLsizei(h));
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  if (swizzle) {
    // 0x00RRGGBB in memory is B, G, R, 0: read it as R, G, B, 1.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ONE);
  }
  glGenFramebuffers(1, &src_fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, src_fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src_tex_, 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  src_w_ = w;
  src_h_ = h;
  src_swizzle_ = swizzle;
}

// Called for the back slot only: the reader never holds it.
void GlTarget::ensure_slot(int b, unsigned w, unsigned h) {
  if (slot_w_[b] == w && slot_h_[b] == h) return;
  glBindTexture(GL_TEXTURE_2D, slot_tex_[b]);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, GLsizei(w), GLsizei(h), 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindFramebuffer(GL_FRAMEBUFFER, slot_fbo_[b]);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, slot_tex_[b], 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  slot_w_[b] = w;
  slot_h_[b] = h;
}

void GlTarget::publish() {
  glFinish();  // the raster thread's context must see a finished texture
  slots_.publish();
}

// The shader source (w x h, row 0 = top) through the chain into the next
// slot, scaled to the screen; row 0 of the slot stays the top.
void GlTarget::render_to_slot(unsigned w, unsigned h) {
  unsigned k = shader_scale(w, h, limit_w_, limit_h_);
  int b = slots_.back();
  ensure_slot(b, w * k, h * k);
  chain_.set_time(
      std::chrono::duration<double>(std::chrono::steady_clock::now() - chain_start_).count());
  chain_.render(src_tex_, w, h, slot_fbo_[b], 0, 0, w * k, h * k, false);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  publish();
}

bool GlTarget::present(unsigned w, unsigned h, bool bottom_left) {
  if (!ready() || !fbo_ || w == 0 || h == 0) return false;
  // Texture row 0 is the picture's top (as for uploaded software frames), so
  // a bottom-left-origin frame is flipped on the way.
  GLint y0 = bottom_left ? GLint(h) : 0, y1 = bottom_left ? 0 : GLint(h);
  if (chain_.loaded()) {
    ensure_source(w, h, false);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, src_fbo_);
    glBlitFramebuffer(0, 0, GLint(w), GLint(h), 0, y0, GLint(w), y1, GL_COLOR_BUFFER_BIT,
                      GL_NEAREST);
    render_to_slot(w, h);
    return true;
  }
  int b = slots_.back();
  ensure_slot(b, w, h);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, slot_fbo_[b]);
  glBlitFramebuffer(0, 0, GLint(w), GLint(h), 0, y0, GLint(w), y1, GL_COLOR_BUFFER_BIT,
                    GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  publish();
  return true;
}

bool GlTarget::present_pixels(const uint32_t *xrgb, unsigned w, unsigned h) {
  // Software frames come here only with a shader (else they go through the
  // frame mailbox): a blit would ignore the source's swizzle.
  if (!ready() || !chain_.loaded() || !xrgb || w == 0 || h == 0) return false;
  ensure_source(w, h, true);
  glBindTexture(GL_TEXTURE_2D, src_tex_);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE,
                  xrgb);
  glBindTexture(GL_TEXTURE_2D, 0);
  render_to_slot(w, h);
  return true;
}

bool GlTarget::read_pixels(unsigned w, unsigned h, bool bottom_left, std::vector<uint32_t> &out) {
  if (!ready() || !fbo_ || w == 0 || h == 0) return false;
  std::vector<uint8_t> rgba(size_t(w) * h * 4);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glPixelStorei(GL_PACK_ALIGNMENT, 4);
  glReadPixels(0, 0, GLint(w), GLint(h), GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  out.resize(size_t(w) * h);
  for (unsigned y = 0; y < h; y++) {
    // Row y of the picture: framebuffer row h-1-y for a bottom-left origin.
    unsigned src_row = bottom_left ? h - 1 - y : y;
    const uint8_t *s = rgba.data() + size_t(src_row) * w * 4;
    uint32_t *d = out.data() + size_t(y) * w;
    for (unsigned x = 0; x < w; x++)
      d[x] = uint32_t(s[4 * x]) << 16 | uint32_t(s[4 * x + 1]) << 8 | s[4 * x + 2];
  }
  return true;
}

void GlTarget::shutdown() {
  live_ = false;
  if (ctx_ != EGL_NO_CONTEXT) {
    chain_.unload();
    if (fbo_) glDeleteFramebuffers(1, &fbo_);
    if (color_) glDeleteTextures(1, &color_);
    if (depth_rb_) glDeleteRenderbuffers(1, &depth_rb_);
    if (src_fbo_) glDeleteFramebuffers(1, &src_fbo_);
    if (src_tex_) glDeleteTextures(1, &src_tex_);
    glDeleteFramebuffers(3, slot_fbo_);
    // A texture still bound in the engine's context lives until it lets go.
    glDeleteTextures(3, slot_tex_);
    eglMakeCurrent(dpy_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy_, ctx_);
  }
  if (surface_ != EGL_NO_SURFACE) eglDestroySurface(dpy_, surface_);
  ctx_ = EGL_NO_CONTEXT;
  surface_ = EGL_NO_SURFACE;
  fbo_ = color_ = depth_rb_ = src_fbo_ = src_tex_ = 0;
  src_w_ = src_h_ = 0;
  for (int i = 0; i < 3; i++) slot_tex_[i] = slot_fbo_[i] = slot_w_[i] = slot_h_[i] = 0;
}

GLuint GlTarget::take(uint32_t *w, uint32_t *h) {
  if (!live_) return 0;
  int s = slots_.take();
  if (s < 0) return 0;
  *w = slot_w_[s];
  *h = slot_h_[s];
  return slot_tex_[s];
}

}  // namespace dena
