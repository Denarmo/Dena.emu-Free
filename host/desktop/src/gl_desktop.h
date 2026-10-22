// SPDX-License-Identifier: GPL-3.0-or-later
// Desktop GL on the emulator thread: a hidden context of its own (WGL on
// Windows, EGL on Linux), compatibility profile 4.6 down to 3.3, with the
// framebuffer GPU cores render into. Frames leave it through D3D11 interop
// (Windows, d3d_frames.h) or a read back (Linux, and the Windows fallback).
// Spec: docs/specs/desktop-shell.md, hw-render.md
#ifndef DENA_GL_DESKTOP_H
#define DENA_GL_DESKTOP_H

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif
#include <GL/gl.h>

#include <cstdint>
#include <vector>

#ifndef APIENTRY
#define APIENTRY
#endif
#ifndef GL_FRAMEBUFFER
#define GL_FRAMEBUFFER 0x8D40
#endif
#ifndef GL_READ_FRAMEBUFFER
#define GL_READ_FRAMEBUFFER 0x8CA8
#endif
#ifndef GL_DRAW_FRAMEBUFFER
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#endif
#ifndef GL_RENDERBUFFER
#define GL_RENDERBUFFER 0x8D41
#endif
#ifndef GL_COLOR_ATTACHMENT0
#define GL_COLOR_ATTACHMENT0 0x8CE0
#endif
#ifndef GL_DEPTH_ATTACHMENT
#define GL_DEPTH_ATTACHMENT 0x8D00
#endif
#ifndef GL_DEPTH_STENCIL_ATTACHMENT
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#endif
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
#ifndef GL_DEPTH_COMPONENT24
#define GL_DEPTH_COMPONENT24 0x81A6
#endif
#ifndef GL_FRAMEBUFFER_COMPLETE
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#endif
#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif
#ifndef GL_RGBA8
#define GL_RGBA8 0x8058
#endif

namespace dena {

// The GL entry points the host itself calls, loaded through proc_address.
struct GlFuncs {
#define DENA_GL_FUNCS(X)                                                                   \
  X(void, GenFramebuffers, (GLsizei, GLuint *))                                            \
  X(void, DeleteFramebuffers, (GLsizei, const GLuint *))                                   \
  X(void, BindFramebuffer, (GLenum, GLuint))                                               \
  X(void, FramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint))                   \
  X(void, FramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint))                       \
  X(GLenum, CheckFramebufferStatus, (GLenum))                                              \
  X(void, GenRenderbuffers, (GLsizei, GLuint *))                                           \
  X(void, DeleteRenderbuffers, (GLsizei, const GLuint *))                                  \
  X(void, BindRenderbuffer, (GLenum, GLuint))                                              \
  X(void, RenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei))                         \
  X(void, BlitFramebuffer,                                                                 \
    (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum))          \
  X(void, GenTextures, (GLsizei, GLuint *))                                                \
  X(void, DeleteTextures, (GLsizei, const GLuint *))                                       \
  X(void, BindTexture, (GLenum, GLuint))                                                   \
  X(void, TexImage2D,                                                                      \
    (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *))         \
  X(void, TexParameteri, (GLenum, GLenum, GLint))                                          \
  X(void, PixelStorei, (GLenum, GLint))                                                    \
  X(void, ReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *))            \
  X(void, Flush, (void))                                                                   \
  X(void, Finish, (void))                                                                  \
  X(GLenum, GetError, (void))
#define DENA_GL_MEMBER(ret, name, args) ret(APIENTRY *name) args = nullptr;
  DENA_GL_FUNCS(DENA_GL_MEMBER)
#undef DENA_GL_MEMBER
};

class DesktopGl {
 public:
  DesktopGl() = default;
  ~DesktopGl() { shutdown(); }
  DesktopGl(const DesktopGl &) = delete;
  DesktopGl &operator=(const DesktopGl &) = delete;

  // Creates the context (left current on this thread) and a max_w x max_h
  // framebuffer for the core. False when no desktop GL 3.3 is available.
  bool init(unsigned max_w, unsigned max_h, bool depth, bool stencil);
  bool ready() const { return fbo_ != 0; }
  uintptr_t framebuffer() const { return fbo_; }
  const GlFuncs &gl() const { return gl_; }
  static void *proc_address(const char *sym);

  // The core's w x h frame as 0x00RRGGBB, top row first.
  bool read_pixels(unsigned w, unsigned h, bool bottom_left, std::vector<uint32_t> &out);
  void shutdown();

#ifdef _WIN32
  // Whether the WGL extension string lists name (e.g. WGL_NV_DX_interop2).
  bool has_wgl_extension(const char *name) const;
#endif

 private:
  bool create_context();
  void destroy_context();

  GlFuncs gl_;
  GLuint fbo_ = 0, color_ = 0, depth_rb_ = 0;
#ifdef _WIN32
  HWND wnd_ = nullptr;
  HDC dc_ = nullptr;
  HGLRC rc_ = nullptr;
#else
  void *dpy_ = nullptr;   // EGLDisplay
  void *ctx_ = nullptr;   // EGLContext
  void *surf_ = nullptr;  // EGLSurface, or none (surfaceless)
#endif
};

}  // namespace dena

#endif
