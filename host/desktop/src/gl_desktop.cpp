// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md
#include "gl_desktop.h"

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstring>

#ifdef _WIN32
#include <mutex>
#else
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#endif

namespace dena {

namespace {

// Newest first: cores that ask for less still run in a newer context.
constexpr int kVersions[][2] = {{4, 6}, {4, 5}, {4, 3}, {4, 1}, {3, 3}};

#ifdef _WIN32
// WGL_ARB_create_context / WGL_ARB_create_context_profile.
constexpr int WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
constexpr int WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
constexpr int WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
constexpr int WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB = 0x0002;
typedef HGLRC(WINAPI *CreateContextAttribs)(HDC, HGLRC, const int *);
typedef const char *(WINAPI *GetExtensionsString)(HDC);

const wchar_t kClass[] = L"DenaHostGl";

void register_class() {
  static std::once_flag once;
  std::call_once(once, [] {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);
  });
}
#endif

}  // namespace

void *DesktopGl::proc_address(const char *sym) {
#ifdef _WIN32
  void *p = reinterpret_cast<void *>(wglGetProcAddress(sym));
  const intptr_t v = reinterpret_cast<intptr_t>(p);
  if (v == 0 || v == 1 || v == 2 || v == 3 || v == -1) {
    // GL 1.1 entry points come from opengl32.dll itself.
    static HMODULE gl = LoadLibraryA("opengl32.dll");
    p = gl ? reinterpret_cast<void *>(GetProcAddress(gl, sym)) : nullptr;
  }
  return p;
#else
  void *p = reinterpret_cast<void *>(eglGetProcAddress(sym));
  if (!p) {
    // Without EGL_KHR_get_all_proc_addresses, GL 1.x is only in the library.
    static void *gl = [] {
      void *h = dlopen("libOpenGL.so.0", RTLD_NOW | RTLD_LOCAL);
      return h ? h : dlopen("libGL.so.1", RTLD_NOW | RTLD_LOCAL);
    }();
    if (gl) p = dlsym(gl, sym);
  }
  return p;
#endif
}

#ifdef _WIN32

bool DesktopGl::create_context() {
  register_class();
  wnd_ = CreateWindowExW(0, kClass, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
                         GetModuleHandleW(nullptr), nullptr);
  if (!wnd_) return false;
  dc_ = GetDC(wnd_);
  PIXELFORMATDESCRIPTOR pfd = {};
  pfd.nSize = sizeof pfd;
  pfd.nVersion = 1;
  pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  pfd.iPixelType = PFD_TYPE_RGBA;
  pfd.cColorBits = 32;
  pfd.cDepthBits = 24;
  pfd.cStencilBits = 8;
  const int format = ChoosePixelFormat(dc_, &pfd);
  if (!format || !SetPixelFormat(dc_, format, &pfd)) return false;
  // A legacy context first: wglCreateContextAttribsARB needs one current.
  HGLRC legacy = wglCreateContext(dc_);
  if (!legacy || !wglMakeCurrent(dc_, legacy)) {
    if (legacy) wglDeleteContext(legacy);
    return false;
  }
  auto create = reinterpret_cast<CreateContextAttribs>(
      reinterpret_cast<void *>(wglGetProcAddress("wglCreateContextAttribsARB")));
  if (create) {
    for (const auto &v : kVersions) {
      const int attribs[] = {WGL_CONTEXT_MAJOR_VERSION_ARB, v[0], WGL_CONTEXT_MINOR_VERSION_ARB,
                             v[1], WGL_CONTEXT_PROFILE_MASK_ARB,
                             WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB, 0};
      rc_ = create(dc_, nullptr, attribs);
      if (rc_) break;
    }
  }
  wglMakeCurrent(nullptr, nullptr);
  wglDeleteContext(legacy);
  if (!rc_ || !wglMakeCurrent(dc_, rc_)) {
    std::fprintf(stderr, "dena: no OpenGL 3.3 context\n");
    return false;
  }
  return true;
}

void DesktopGl::destroy_context() {
  if (rc_) {
    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(rc_);
    rc_ = nullptr;
  }
  if (dc_) ReleaseDC(wnd_, dc_), dc_ = nullptr;
  if (wnd_) DestroyWindow(wnd_), wnd_ = nullptr;
}

bool DesktopGl::has_wgl_extension(const char *name) const {
  auto get = reinterpret_cast<GetExtensionsString>(
      reinterpret_cast<void *>(wglGetProcAddress("wglGetExtensionsStringARB")));
  const char *all = get ? get(dc_) : nullptr;
  if (!all) return false;
  const size_t n = std::strlen(name);
  for (const char *p = std::strstr(all, name); p; p = std::strstr(p + 1, name))
    if ((p == all || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0')) return true;
  return false;
}

#else  // EGL

bool DesktopGl::create_context() {
  // The default display (X11 or Wayland through Mesa, or NVIDIA's EGL
  // device), else Mesa's surfaceless platform on a render node.
  EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (dpy != EGL_NO_DISPLAY && !eglInitialize(dpy, nullptr, nullptr)) dpy = EGL_NO_DISPLAY;
  if (dpy == EGL_NO_DISPLAY) {
    auto get_platform = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
        eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (get_platform) dpy = get_platform(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
    if (dpy != EGL_NO_DISPLAY && !eglInitialize(dpy, nullptr, nullptr)) dpy = EGL_NO_DISPLAY;
  }
  if (dpy == EGL_NO_DISPLAY || !eglBindAPI(EGL_OPENGL_API)) {
    std::fprintf(stderr, "dena: no EGL display for desktop GL\n");
    return false;
  }
  dpy_ = dpy;
  const EGLint pbuffer_attribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                                    EGL_OPENGL_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                    EGL_BLUE_SIZE, 8, EGL_NONE};
  const EGLint any_attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint n = 0;
  bool pbuffer = eglChooseConfig(dpy, pbuffer_attribs, &config, 1, &n) && n > 0;
  if (!pbuffer && (!eglChooseConfig(dpy, any_attribs, &config, 1, &n) || n == 0)) {
    std::fprintf(stderr, "dena: no EGL config for desktop GL\n");
    return false;
  }
  EGLContext ctx = EGL_NO_CONTEXT;
  for (const auto &v : kVersions) {
    const EGLint attribs[] = {EGL_CONTEXT_MAJOR_VERSION, v[0], EGL_CONTEXT_MINOR_VERSION, v[1],
                              EGL_CONTEXT_OPENGL_PROFILE_MASK,
                              EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE};
    ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, attribs);
    if (ctx != EGL_NO_CONTEXT) break;
  }
  if (ctx == EGL_NO_CONTEXT) {
    std::fprintf(stderr, "dena: no OpenGL 3.3 context\n");
    return false;
  }
  ctx_ = ctx;
  EGLSurface surf = EGL_NO_SURFACE;
  if (pbuffer) {
    const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    surf = eglCreatePbufferSurface(dpy, config, size);
  }
  surf_ = surf;
  return eglMakeCurrent(dpy, surf, surf, ctx) == EGL_TRUE;
}

void DesktopGl::destroy_context() {
  auto dpy = static_cast<EGLDisplay>(dpy_);
  if (dpy == EGL_NO_DISPLAY) return;
  eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (surf_) eglDestroySurface(dpy, static_cast<EGLSurface>(surf_));
  if (ctx_) eglDestroyContext(dpy, static_cast<EGLContext>(ctx_));
  surf_ = ctx_ = nullptr;
  dpy_ = nullptr;  // the display stays initialized for the next game
}

#endif

bool DesktopGl::init(unsigned max_w, unsigned max_h, bool depth, bool stencil) {
  shutdown();
  if (!create_context()) {
    destroy_context();
    return false;
  }
  bool ok = true;
#define DENA_GL_LOAD(ret, name, args)                                                \
  gl_.name = reinterpret_cast<ret(APIENTRY *) args>(proc_address("gl" #name)); \
  ok = ok && gl_.name != nullptr;
  DENA_GL_FUNCS(DENA_GL_LOAD)
#undef DENA_GL_LOAD
  if (!ok) {
    std::fprintf(stderr, "dena: GL 3 entry points missing\n");
    destroy_context();
    return false;
  }
  gl_.GenTextures(1, &color_);
  gl_.BindTexture(GL_TEXTURE_2D, color_);
  gl_.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, GLsizei(max_w), GLsizei(max_h), 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
  gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  gl_.GenFramebuffers(1, &fbo_);
  gl_.BindFramebuffer(GL_FRAMEBUFFER, fbo_);
  gl_.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color_, 0);
  if (depth || stencil) {
    gl_.GenRenderbuffers(1, &depth_rb_);
    gl_.BindRenderbuffer(GL_RENDERBUFFER, depth_rb_);
    gl_.RenderbufferStorage(GL_RENDERBUFFER, stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24,
                            GLsizei(max_w), GLsizei(max_h));
    gl_.FramebufferRenderbuffer(GL_FRAMEBUFFER,
                                stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, depth_rb_);
  }
  if (gl_.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    std::fprintf(stderr, "dena: core framebuffer incomplete\n");
    shutdown();
    return false;
  }
  return true;
}

bool DesktopGl::read_pixels(unsigned w, unsigned h, bool bottom_left, std::vector<uint32_t> &out) {
  if (!fbo_ || w == 0 || h == 0) return false;
  out.resize(size_t(w) * h);
  gl_.BindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  gl_.PixelStorei(GL_PACK_ALIGNMENT, 4);
  // BGRA bytes are 0xAARRGGBB words on little-endian hosts.
  gl_.ReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_BGRA, GL_UNSIGNED_BYTE, out.data());
  if (gl_.GetError() != GL_NO_ERROR) return false;
  // GL rows run bottom-up; a bottom-left core's top row is the last one.
  if (bottom_left) {
    for (unsigned y = 0; y < h / 2; y++)
      std::swap_ranges(out.begin() + std::ptrdiff_t(y) * w, out.begin() + std::ptrdiff_t(y + 1) * w,
                       out.begin() + std::ptrdiff_t(h - 1 - y) * w);
  }
  for (uint32_t &p : out) p &= 0x00ffffffu;
  return true;
}

void DesktopGl::shutdown() {
  if (fbo_ || color_ || depth_rb_) {
    if (gl_.DeleteFramebuffers && fbo_) gl_.DeleteFramebuffers(1, &fbo_);
    if (gl_.DeleteTextures && color_) gl_.DeleteTextures(1, &color_);
    if (gl_.DeleteRenderbuffers && depth_rb_) gl_.DeleteRenderbuffers(1, &depth_rb_);
    fbo_ = color_ = depth_rb_ = 0;
  }
  destroy_context();
  gl_ = GlFuncs();
}

}  // namespace dena
