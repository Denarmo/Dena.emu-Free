// melonDS on OpenGL ES 3.2 (docs/specs/ds.md, Internal resolution): our DS
// test ROM's 3D triangle rendered by the GLES renderer at 1x, 2x and 4x
// against the software renderer at 1x. Each render runs in its own child
// process (the core keeps global state) with an offscreen EGL context
// (Mesa's surfaceless platform when available). Exits 77 (skipped) without a
// GLES 3.2 context.
// Usage: ds_gles_tests <melonds core> <test.nds> <scratch dir>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "dena/host.h"

static int failures;

#define CHECK(cond)                                                                    \
  do {                                                                                 \
    if (!(cond)) {                                                                     \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                                      \
    }                                                                                  \
  } while (0)

constexpr int kMaxScale = 4;
constexpr unsigned kW = 256, kH = 384;  // both screens, stacked
constexpr unsigned kTopH = 192;
constexpr int kFrames = 30;

// What a child hands back: the picture (XRGB8888, top row first).
struct Shot {
  int ok;  // 0: failed, 1: rendered, 77: no GLES 3.2 context
  int gpu;  // drawn through the hardware framebuffer
  int pack_buffer;  // GL_PIXEL_PACK_BUFFER bound after the frames
  unsigned w, h;
  uint32_t px[kW * kMaxScale * kH * kMaxScale];
};

static bool make_context() {
  EGLDisplay d = EGL_NO_DISPLAY;
  auto get_platform = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (get_platform) d = get_platform(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
  if (d == EGL_NO_DISPLAY) d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, nullptr, nullptr)) return false;
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return false;
  const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(d, attrs, &cfg, 1, &n)) return false;
  const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3,  // the highest 3.x, as on Android
                              EGL_CONTEXT_OPENGL_DEBUG, getenv("DENA_GL_DEBUG") ? EGL_TRUE : EGL_FALSE,
                              EGL_NONE};
  EGLContext c = eglCreateContext(d, n ? cfg : nullptr, EGL_NO_CONTEXT, ctx_attrs);
  if (c == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c);
}

static GLuint g_fbo;
static uintptr_t get_fb(void *) { return g_fbo; }
static void *get_proc(void *, const char *sym) {
  return reinterpret_cast<void *>(eglGetProcAddress(sym));
}

static const char *kResolution[] = {"1x native (256x192)", "2x native (512x384)",
                                    "3x native (768x576)", "4x native (1024x768)"};

// scale 0: software renderer; 1-4: the GLES renderer at that internal resolution.
static void render(const char *core_path, const char *rom, int scale, Shot *out) {
  out->ok = 0;
  if (!make_context()) {
    out->ok = 77;
    return;
  }
  if (getenv("DENA_GL_DEBUG")) {
    auto cb = reinterpret_cast<void (*)(GLDEBUGPROC, const void *)>(eglGetProcAddress("glDebugMessageCallback"));
    if (cb)
      cb([](GLenum, GLenum type, GLuint, GLenum, GLsizei, const GLchar *msg, const void *) {
        if (type == GL_DEBUG_TYPE_ERROR) std::fprintf(stderr, "GL: %s\n", msg);
      }, nullptr);
  }
  const unsigned fw = kW * kMaxScale, fh = kH * kMaxScale;
  GLuint tex, depth;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fw, fh);
  glGenRenderbuffers(1, &depth);
  glBindRenderbuffer(GL_RENDERBUFFER, depth);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, fw, fh);
  glGenFramebuffers(1, &g_fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depth);

  char err[512];
  dena_core *core = dena_core_load(core_path, err, sizeof err);
  if (!core) {
    std::fprintf(stderr, "%s\n", err);
    return;
  }
  dena_hw_hooks hooks = {get_fb, get_proc, nullptr};
  dena_core_set_hw_hooks(core, &hooks);
  dena_core_set_option(core, "melonds_opengl_renderer", scale ? "enabled" : "disabled");
  if (scale) dena_core_set_option(core, "melonds_opengl_resolution", kResolution[scale - 1]);
  if (dena_core_load_game(core, rom, err, sizeof err) != 0) {
    std::fprintf(stderr, "%s\n", err);
    dena_core_unload(core);
    return;
  }
  dena_hw_info info;
  if (dena_core_hw_info(core, &info)) dena_core_hw_context_reset(core);
  for (int i = 0; i < kFrames; i++) dena_core_run_frame(core);

  // The frontend's readback must not land in a buffer the core left bound.
  GLint pack = -1;
  glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
  out->pack_buffer = pack;

  unsigned w = 0, h = 0;
  out->gpu = dena_core_hw_frame(core, &w, &h);
  if (out->gpu) {
    if (w > fw || h > fh) {
      std::fprintf(stderr, "frame %ux%u larger than the framebuffer\n", w, h);
    } else {
      static uint8_t rgba[kW * kMaxScale * kH * kMaxScale * 4];
      glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
      glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
      for (unsigned y = 0; y < h; y++) {
        unsigned sy = info.bottom_left_origin ? h - 1 - y : y;
        for (unsigned x = 0; x < w; x++) {
          const uint8_t *p = &rgba[(sy * w + x) * 4];
          out->px[y * w + x] = uint32_t(p[0]) << 16 | uint32_t(p[1]) << 8 | p[2];
        }
      }
      out->w = w;
      out->h = h;
      out->ok = 1;
    }
  } else if (const dena_frame *f = dena_core_frame(core)) {
    out->w = f->width;
    out->h = f->height;
    std::memcpy(out->px, f->pixels, size_t(f->width) * f->height * 4);
    out->ok = 1;
  }
  dena_core_hw_context_destroy(core);
  dena_core_unload(core);
}

// gles31: cap Mesa at OpenGL ES 3.1, below what the GL renderer needs.
static Shot *render_in_child(const char *core, const char *rom, int scale, bool gles31 = false) {
  void *mem = mmap(nullptr, sizeof(Shot), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (mem == MAP_FAILED) return nullptr;
  Shot *shot = static_cast<Shot *>(mem);
  shot->ok = 0;
  std::fflush(nullptr);  // or the child flushes the parent's output again
  pid_t pid = fork();
  if (pid == 0) {
    if (gles31) setenv("MESA_GLES_VERSION_OVERRIDE", "3.1", 1);
    render(core, rom, scale, shot);
    std::fflush(nullptr);
    _exit(0);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return shot;
}

// The clear colour is dark grey (4/31 per channel); the triangle is brighter.
static bool covered(uint32_t px) {
  int r = (px >> 16) & 0xFF, g = (px >> 8) & 0xFF, b = px & 0xFF;
  return r > 60 || g > 60 || b > 60;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: ds_gles_tests <melonds core> <test.nds> <scratch dir>\n");
    return 2;
  }
  setenv("DENA_SYSTEM_DIR", argv[3], 1);
  Shot *ref = render_in_child(argv[1], argv[2], 0);
  if (!ref || ref->ok != 1) {
    std::fprintf(stderr, "software render failed\n");
    return ref && ref->ok == 77 ? 77 : 1;
  }
  CHECK(!ref->gpu && ref->w == kW && ref->h == kH);
  unsigned ref_cover = 0;
  for (unsigned i = 0; i < kW * kTopH; i++) ref_cover += covered(ref->px[i]);
  CHECK(ref_cover > kW * kTopH / 5);  // the triangle is on screen

  for (int scale : {1, 2, 4}) {
    Shot *s = render_in_child(argv[1], argv[2], scale);
    if (s && s->ok == 77) return 77;
    if (!s || s->ok != 1) {
      std::fprintf(stderr, "%dx: render failed\n", scale);
      failures++;
      continue;
    }
    // The core always outputs 4x (melonDS's libretro layout); the internal
    // resolution is what the 3D renderer drew at before that scaling.
    CHECK(s->gpu);
    CHECK(s->pack_buffer == 0);
    CHECK(s->w == kW * kMaxScale && s->h == kH * kMaxScale);
    if (!s->gpu || s->w != kW * kMaxScale || s->h != kH * kMaxScale) continue;
    const unsigned out = kMaxScale, step = out / unsigned(scale);

    // Same picture: coverage sampled at each 1x pixel's centre matches 1x.
    unsigned diff = 0;
    for (unsigned y = 0; y < kTopH; y++)
      for (unsigned x = 0; x < kW; x++) {
        unsigned sx = x * out + out / 2, sy = y * out + out / 2;
        diff += covered(s->px[sy * s->w + sx]) != covered(ref->px[y * kW + x]);
      }
    std::printf("%dx: %u of %u top-screen pixels differ from software 1x\n", scale, diff,
                kW * kTopH);
    CHECK(diff < kW * kTopH / 100);

    // True resolution: along the slanted left edge, every row starts on the
    // internal pixel grid (steps of out/scale), and at 2x+ many rows start
    // between 1x columns, which scaling a 1x picture up can never do.
    unsigned rows = 0, off_grid = 0, between = 0;
    for (unsigned y = 0; y < kTopH * out; y++) {
      const uint32_t *row = &s->px[y * s->w];
      for (unsigned x = 0; x < s->w; x++)
        if (covered(row[x])) {
          rows++;
          off_grid += x % step != 0;
          between += x % out != 0;
          break;
        }
    }
    std::printf("%dx: left edge off the %ux grid on %u, between 1x columns on %u, of %u rows\n",
                scale, scale, off_grid, between, rows);
    CHECK(rows > 0 && off_grid == 0);
    if (scale > 1) CHECK(between > rows / 3);
    if (scale == 4) {
      dena_frame f = {s->w, s->h, s->px};
      dena_frame_write_ppm(&f, (std::string(argv[3]) + "/ds_gles_4x.ppm").c_str());
    }
  }
  // Below GLES 3.2 the core keeps software 3D (1x) and still shows it.
  Shot *old = render_in_child(argv[1], argv[2], 4, true);
  CHECK(old && old->ok == 1);
  if (old && old->ok == 1) {
    unsigned diff = 0, between = 0;
    const unsigned out = old->w / kW;
    for (unsigned y = 0; y < kTopH; y++)
      for (unsigned x = 0; x < kW; x++)
        diff += covered(old->px[(y * out + out / 2) * old->w + x * out + out / 2]) !=
                covered(ref->px[y * kW + x]);
    for (unsigned y = 0; y < kTopH * out; y++)
      for (unsigned x = 0; x < old->w; x++)
        if (covered(old->px[y * old->w + x])) {
          between += x % out != 0;
          break;
        }
    std::printf("GLES 3.1: %ux%u, %u pixels differ from software 1x, %u rows between 1x columns\n",
                old->w, old->h, diff, between);
    CHECK(diff == 0 && between == 0);
  }

  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("ok\n");
  return 0;
}
