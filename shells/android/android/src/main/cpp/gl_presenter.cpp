// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/hw-render.md, docs/specs/shaders.md
#include "gl_presenter.h"

#include <android/log.h>

#define LOG_TAG "Dena"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// Full-screen triangle strip; uv_scale maps it onto the used framebuffer area,
// with y flipped when the core draws bottom-left origin (GL convention).
const char *kVertex = R"(#version 300 es
uniform vec2 uv_scale;
out vec2 uv;
void main() {
  vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
  uv = p * uv_scale;
  if (uv_scale.y < 0.0) uv.y += -uv_scale.y;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
  gl_Position.y = -gl_Position.y;
}
)";

const char *kFragment = R"(#version 300 es
precision mediump float;
uniform sampler2D tex;
in vec2 uv;
out vec4 color;
void main() { color = vec4(texture(tex, uv).rgb, 1.0); }
)";

GLuint compile(GLenum type, const char *src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[512];
    glGetShaderInfoLog(s, sizeof log, nullptr, log);
    LOGE("shader: %s", log);
    glDeleteShader(s);
    return 0;
  }
  return s;
}

}  // namespace

bool GlPresenter::init_context() {
  if (ready()) return true;
  display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (display_ == EGL_NO_DISPLAY || !eglInitialize(display_, nullptr, nullptr)) return false;
  const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                          EGL_SURFACE_TYPE,    EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                          EGL_RED_SIZE,        8,
                          EGL_GREEN_SIZE,      8,
                          EGL_BLUE_SIZE,       8,
                          EGL_NONE};
  EGLint n = 0;
  if (!eglChooseConfig(display_, attrs, &config_, 1, &n) || n < 1) {
    shutdown();
    return false;
  }
  const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, ctx_attrs);
  const EGLint pb_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
  pbuffer_ = eglCreatePbufferSurface(display_, config_, pb_attrs);
  if (context_ == EGL_NO_CONTEXT || pbuffer_ == EGL_NO_SURFACE ||
      !eglMakeCurrent(display_, pbuffer_, pbuffer_, context_) || !build_blit_program()) {
    LOGE("EGL context or blit program failed");
    shutdown();
    return false;
  }
  return true;
}

bool GlPresenter::init(unsigned max_w, unsigned max_h, bool depth, bool stencil) {
  if (!init_context()) return false;
  fb_w_ = max_w;
  fb_h_ = max_h;
  glGenTextures(1, &color_);
  glBindTexture(GL_TEXTURE_2D, color_);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(max_w), GLsizei(max_h));
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glGenFramebuffers(1, &fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color_, 0);
  if (depth || stencil) {
    // Always packed depth + stencil: cores such as PPSSPP ask only for depth
    // but use stencil too (hw-render.md).
    glGenRenderbuffers(1, &depth_rb_);
    glBindRenderbuffer(GL_RENDERBUFFER, depth_rb_);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, GLsizei(max_w), GLsizei(max_h));
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                              depth_rb_);
  }
  bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (!complete) {
    LOGE("GL framebuffer incomplete");
    shutdown();
    return false;
  }
  return true;
}

bool GlPresenter::build_blit_program() {
  GLuint vs = compile(GL_VERTEX_SHADER, kVertex), fs = compile(GL_FRAGMENT_SHADER, kFragment);
  if (!vs || !fs) return false;
  program_ = glCreateProgram();
  glAttachShader(program_, vs);
  glAttachShader(program_, fs);
  glLinkProgram(program_);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(program_, GL_LINK_STATUS, &ok);
  if (!ok) return false;
  uv_scale_loc_ = glGetUniformLocation(program_, "uv_scale");
  glGenVertexArrays(1, &vao_);
  return true;
}

void *GlPresenter::proc_address(const char *sym) {
  return reinterpret_cast<void *>(eglGetProcAddress(sym));
}

void GlPresenter::set_window(ANativeWindow *window) {
  if (window == window_ && (window_surface_ != EGL_NO_SURFACE || !window)) return;
  if (window_surface_ != EGL_NO_SURFACE) {
    eglMakeCurrent(display_, pbuffer_, pbuffer_, context_);
    eglDestroySurface(display_, window_surface_);
    window_surface_ = EGL_NO_SURFACE;
  }
  window_ = window;
  if (window_) {
    window_surface_ = eglCreateWindowSurface(display_, config_, window_, nullptr);
    if (window_surface_ == EGL_NO_SURFACE) LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
  }
}

bool GlPresenter::make_window_current(EGLint *w, EGLint *h) {
  if (window_surface_ == EGL_NO_SURFACE) return false;
  eglMakeCurrent(display_, window_surface_, window_surface_, context_);
  eglQuerySurface(display_, window_surface_, EGL_WIDTH, w);
  eglQuerySurface(display_, window_surface_, EGL_HEIGHT, h);
  return *w > 0 && *h > 0;
}

void GlPresenter::draw_blit(GLuint tex, float su, float sv, EGLint w, EGLint h) {
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, w, h);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glUseProgram(program_);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, tex);
  // Positive v: the top row is v=0 (core drew top-left origin). Negative:
  // the shader flips, sampling from v=sv down to 0.
  glUniform2f(uv_scale_loc_, su, sv);
  glBindVertexArray(vao_);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);
}

void GlPresenter::finish_frame() {
  eglSwapBuffers(display_, window_surface_);
  // Back to the offscreen surface so the core never draws to the window.
  eglMakeCurrent(display_, pbuffer_, pbuffer_, context_);
}

void GlPresenter::ensure_source(unsigned w, unsigned h, bool swizzle) {
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
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &src_fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, src_fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src_tex_, 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  src_w_ = w;
  src_h_ = h;
  src_swizzle_ = swizzle;
}

void GlPresenter::reset_core_state() {
  // melonDS (ds.md) draws with per-buffer write masks and pack buffers;
  // blits honour the scissor box and reads go to a bound pack buffer.
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glDisable(GL_SCISSOR_TEST);
}

void GlPresenter::present(unsigned w, unsigned h, bool flip_y) {
  EGLint sw = 0, sh = 0;
  if (!w || !h || !make_window_current(&sw, &sh)) return;
  reset_core_state();
  if (chain_.loaded()) {
    // Copy the used area into the chain's source, top row first.
    ensure_source(w, h, false);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, src_fbo_);
    glBlitFramebuffer(0, 0, GLint(w), GLint(h), 0, flip_y ? GLint(h) : 0, GLint(w),
                      flip_y ? 0 : GLint(h), GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    chain_.set_time(std::chrono::duration<double>(std::chrono::steady_clock::now() - chain_start_).count());
    chain_.render(src_tex_, w, h, 0, 0, 0, unsigned(sw), unsigned(sh), true);
  } else {
    float su = float(w) / float(fb_w_), sv = float(h) / float(fb_h_);
    draw_blit(color_, su, flip_y ? -sv : sv, sw, sh);
  }
  finish_frame();
}

void GlPresenter::present_pixels(const uint32_t *pixels, unsigned w, unsigned h) {
  EGLint sw = 0, sh = 0;
  if (!pixels || !w || !h || !make_window_current(&sw, &sh)) return;
  ensure_source(w, h, true);
  glBindTexture(GL_TEXTURE_2D, src_tex_);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE,
                  pixels);
  glBindTexture(GL_TEXTURE_2D, 0);
  GLuint tex = src_tex_;
  if (pre_.loaded()) {
    // The upscaled picture stands in for the frame; the shader's native size
    // makes it draw the game's own lines (shaders.md, Native lines).
    ensure_prescaled(w * pre_factor_, h * pre_factor_);
    pre_.render(src_tex_, w, h, pre_fbo_, 0, 0, pre_w_, pre_h_, false);
    tex = pre_tex_;
    w = pre_w_;
    h = pre_h_;
  }
  if (chain_.loaded()) {
    chain_.set_time(std::chrono::duration<double>(std::chrono::steady_clock::now() - chain_start_).count());
    chain_.render(tex, w, h, 0, 0, 0, unsigned(sw), unsigned(sh), true);
  } else {
    draw_blit(tex, 1.0f, 1.0f, sw, sh);
  }
  finish_frame();
}

bool GlPresenter::set_prescale(const std::string &path, unsigned factor, std::string *err) {
  if (!ready()) {
    *err = "no GL context";
    return false;
  }
  if (path.empty() || factor < 2) {
    pre_.unload();
    pre_factor_ = 0;
    return true;
  }
  dena::ShaderPreset preset;
  if (!dena::parse_preset(path, &preset, err)) return false;
  dena::ShaderChain next;
  if (!next.load(preset, err)) {
    LOGE("upscale %s: %s", path.c_str(), err->c_str());
    return false;
  }
  pre_.swap(next);
  pre_factor_ = factor;
  return true;
}

void GlPresenter::ensure_prescaled(unsigned w, unsigned h) {
  if (pre_tex_ && w == pre_w_ && h == pre_h_) return;
  if (pre_fbo_) glDeleteFramebuffers(1, &pre_fbo_);
  if (pre_tex_) glDeleteTextures(1, &pre_tex_);
  glGenTextures(1, &pre_tex_);
  glBindTexture(GL_TEXTURE_2D, pre_tex_);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(w), GLsizei(h));
  // Linear: the plain blit scales the smoothed picture to the window.
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &pre_fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, pre_fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pre_tex_, 0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  pre_w_ = w;
  pre_h_ = h;
}

bool GlPresenter::set_shader(const std::string &path, std::string *err) {
  if (!ready()) {
    *err = "no GL context";
    return false;
  }
  if (path.empty()) {
    chain_.unload();
    return true;
  }
  dena::ShaderPreset preset;
  if (!dena::parse_preset(path, &preset, err)) return false;
  dena::ShaderChain next;
  // Compile into a fresh chain so a broken shader leaves the current one.
  if (!next.load(preset, err)) {
    LOGE("shader %s: %s", path.c_str(), err->c_str());
    return false;
  }
  chain_.swap(next);  // the old chain is freed with next
  chain_start_ = std::chrono::steady_clock::now();
  return true;
}

bool GlPresenter::read_pixels(unsigned w, unsigned h, bool flip_y, std::vector<uint32_t> &out) {
  if (!ready() || !w || !h || w > fb_w_ || h > fb_h_) return false;
  std::vector<uint8_t> rgba(size_t(w) * h * 4);
  reset_core_state();
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  out.resize(size_t(w) * h);
  for (unsigned y = 0; y < h; y++) {
    // glReadPixels returns the bottom row first; with a top-left origin the
    // core's first row is at y=0 of the buffer already.
    unsigned src_y = flip_y ? h - 1 - y : y;
    const uint8_t *s = &rgba[size_t(src_y) * w * 4];
    uint32_t *d = &out[size_t(y) * w];
    for (unsigned x = 0; x < w; x++, s += 4)
      d[x] = (uint32_t(s[0]) << 16) | (uint32_t(s[1]) << 8) | s[2];
  }
  return true;
}

void GlPresenter::shutdown() {
  if (display_ == EGL_NO_DISPLAY) return;
  if (context_ != EGL_NO_CONTEXT) {
    eglMakeCurrent(display_, pbuffer_, pbuffer_, context_);
    if (program_) glDeleteProgram(program_);
    if (vao_) glDeleteVertexArrays(1, &vao_);
    if (fbo_) glDeleteFramebuffers(1, &fbo_);
    if (color_) glDeleteTextures(1, &color_);
    if (depth_rb_) glDeleteRenderbuffers(1, &depth_rb_);
    if (src_fbo_) glDeleteFramebuffers(1, &src_fbo_);
    if (src_tex_) glDeleteTextures(1, &src_tex_);
    if (pre_fbo_) glDeleteFramebuffers(1, &pre_fbo_);
    if (pre_tex_) glDeleteTextures(1, &pre_tex_);
    chain_.unload();
    pre_.unload();
  }
  program_ = vao_ = fbo_ = color_ = depth_rb_ = src_fbo_ = src_tex_ = pre_fbo_ = pre_tex_ = 0;
  src_w_ = src_h_ = pre_w_ = pre_h_ = pre_factor_ = 0;
  eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (window_surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, window_surface_);
  if (pbuffer_ != EGL_NO_SURFACE) eglDestroySurface(display_, pbuffer_);
  if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
  eglTerminate(display_);
  window_surface_ = pbuffer_ = EGL_NO_SURFACE;
  context_ = EGL_NO_CONTEXT;
  display_ = EGL_NO_DISPLAY;
  window_ = nullptr;
}
