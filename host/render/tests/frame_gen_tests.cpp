// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/frame-generation.md (acceptance tests, host, GL)
// Runs FrameGen as the chain's source filter offscreen through EGL
// (surfaceless Mesa works). Exits 77 (skipped) when no GL 4.2 is available.
// Usage: frame_gen_tests <host/slang-shaders>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include "dena/frame_gen.h"
#include "dena/slang_chain.h"

using namespace dena::slang;

namespace {

int failures = 0;
std::string bundled;

#define CHECK(cond)                                                          \
  do {                                                                       \
    if (!(cond)) {                                                           \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
      failures++;                                                            \
    }                                                                        \
  } while (0)

void *proc(const char *name) {
  void *p = reinterpret_cast<void *>(eglGetProcAddress(name));
  if (!p) {
    static void *gl = [] {
      void *h = dlopen("libOpenGL.so.0", RTLD_NOW | RTLD_LOCAL);
      return h ? h : dlopen("libGL.so.1", RTLD_NOW | RTLD_LOCAL);
    }();
    if (gl) p = dlsym(gl, name);
  }
  return p;
}

bool make_context() {
  EGLDisplay dpy = EGL_NO_DISPLAY;
  auto get_platform = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (get_platform) dpy = get_platform(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
  if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
    dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) return false;
  }
  if (!eglBindAPI(EGL_OPENGL_API)) return false;
  const EGLint attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint n = 0;
  if (!eglChooseConfig(dpy, attribs, &config, 1, &n) || n == 0) config = EGL_NO_CONFIG_KHR;
  const EGLint ctx_attribs[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 2,
                                EGL_CONTEXT_OPENGL_PROFILE_MASK,
                                EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attribs);
  if (ctx == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == EGL_TRUE;
}

uint32_t hash(unsigned x, unsigned y, unsigned seed) {
  uint32_t h = x * 374761393u + y * 668265263u + seed * 2246822519u;
  h = (h ^ (h >> 13)) * 1274126177u;
  return h ^ (h >> 16);
}

// A picture of `unit`-sized cells: noise background, a 16x16 cell square
// (its own pattern) with its top left at cell (sx, sy).
struct Scene {
  unsigned w, h, unit;
  std::vector<uint32_t> px;
};

Scene scene(unsigned cw, unsigned ch, unsigned unit, int sx, int sy, unsigned seed = 1,
            unsigned size = 16) {
  Scene s{cw * unit, ch * unit, unit, {}};
  s.px.resize(size_t(s.w) * s.h);
  for (unsigned y = 0; y < s.h; y++)
    for (unsigned x = 0; x < s.w; x++) {
      const int cx = int(x / unit), cy = int(y / unit);
      uint32_t c = hash(cx, cy, seed) & 0x7f7f7fu;  // background: darker noise
      if (cx >= sx && cx < sx + int(size) && cy >= sy && cy < sy + int(size))
        c = 0x808080u | (hash(cx - sx, cy - sy, 99) & 0x7f7f7fu);  // square: bright pattern
      s.px[size_t(y) * s.w + x] = 0xff000000u | c;
    }
  return s;
}

unsigned channel(uint32_t px, int shift) { return (px >> shift) & 255; }

bool close(uint32_t a, uint32_t b, unsigned tol) {
  for (int s : {0, 8, 16})
    if (std::abs(int(channel(a, s)) - int(channel(b, s))) > int(tol)) return false;
  return true;
}

// Fraction of pixels of `out` within tol of `want`.
double match(const std::vector<uint32_t> &out, const std::vector<uint32_t> &want, unsigned tol) {
  if (out.size() != want.size() || out.empty()) return 0;
  size_t ok = 0;
  for (size_t i = 0; i < out.size(); i++) ok += close(out[i], want[i], tol);
  return double(ok) / double(out.size());
}

// Shows a then b through the chain with frame generation; returns the
// generated frame.
std::vector<uint32_t> generated(SlangChain &chain, FrameGen &fg, const Scene &a, const Scene &b) {
  fg.invalidate();
  fg.next(FrameGen::kPush);
  CHECK(chain.upload(a.px.data(), a.w, a.h) && chain.render(a.w, a.h));
  CHECK(fg.has_previous(a.w, a.h));
  fg.next(FrameGen::kGenerate);
  CHECK(chain.upload(b.px.data(), b.w, b.h) && chain.render(b.w, b.h));
  std::vector<uint32_t> out;
  CHECK(chain.read_output(&out));
  CHECK(chain.gl().GetError() == GL_NO_ERROR);
  return out;
}

void test_flow_size() {
  unsigned fw, fh, f;
  FrameGen::flow_size(1024, 896, 256, 224, &fw, &fh, &f);
  CHECK(fw == 256 && fh == 224 && f == 4);
  FrameGen::flow_size(256, 224, 256, 224, &fw, &fh, &f);
  CHECK(fw == 256 && fh == 224 && f == 1);
  FrameGen::flow_size(1920, 1080, 0, 0, &fw, &fh, &f);
  CHECK(f == 3 && fw == 640 && fh == 360);
  FrameGen::flow_size(1000, 896, 256, 224, &fw, &fh, &f);  // not a whole multiple
  CHECK(f == 2 && fw == 500 && fh == 448);
}

void test_still(SlangChain &chain, FrameGen &fg) {
  for (int mode : {FrameGen::kInterpolate, FrameGen::kPixelArt}) {
    fg.set_mode(mode);
    const Scene a = scene(128, 96, 1, 40, 30);
    const auto out = generated(chain, fg, a, a);
    CHECK(match(out, a.px, 0) == 1.0);
  }
}

void test_moving_square(SlangChain &chain, FrameGen &fg) {
  for (int mode : {FrameGen::kInterpolate, FrameGen::kPixelArt}) {
    fg.set_mode(mode);
    const Scene a = scene(128, 96, 1, 40, 30), b = scene(128, 96, 1, 48, 30);
    const Scene mid = scene(128, 96, 1, 44, 30);
    const auto out = generated(chain, fg, a, b);
    const double m = match(out, mid.px, 6);
    std::printf("mode %d: square moving 8 px, %.1f%% of pixels at the +4 picture\n", mode, m * 100);
    CHECK(m > 0.97);
    // The square's inside is exactly where it should be.
    size_t inside = 0, total = 0;
    for (unsigned y = 32; y < 44; y++)
      for (unsigned x = 46; x < 58; x++, total++) inside += close(out[y * 128 + x], mid.px[y * 128 + x], 6);
    CHECK(inside == total);
  }
  std::printf("generated frames: %llu\n", static_cast<unsigned long long>(fg.generated()));
}

void test_pixel_art_3x(SlangChain &chain, FrameGen &fg) {
  fg.set_mode(FrameGen::kPixelArt);
  fg.set_native_size(64, 48);
  chain.set_native_size(64, 48);
  // An 8x8-cell square; moves of 6 and 5 game pixels both land at +3.
  for (int move : {6, 5}) {
    const Scene a = scene(64, 48, 3, 20, 20, 1, 8), b = scene(64, 48, 3, 20 + move, 20, 1, 8);
    const Scene mid = scene(64, 48, 3, 23, 20, 1, 8);
    const auto out = generated(chain, fg, a, b);
    const double m = match(out, mid.px, 0);
    std::printf("pixel-art 3x: move %d, %.1f%% exact at +3\n", move, m * 100);
    CHECK(m > 0.97);
    // Only colours of the current frame, never a blend.
    std::set<uint32_t> colours;
    for (uint32_t p : b.px) colours.insert(p & 0xffffff);
    size_t foreign = 0;
    for (uint32_t p : out) foreign += !colours.count(p & 0xffffff);
    CHECK(foreign == 0);
    // Whole game pixels: every 3x3 cell is one colour.
    size_t split = 0;
    for (unsigned y = 0; y < 144; y++)
      for (unsigned x = 0; x < 192; x++)
        split += (out[y * 192 + x] & 0xffffff) != (out[(y / 3 * 3) * 192 + x / 3 * 3] & 0xffffff);
    CHECK(split == 0);
  }
  fg.set_native_size(0, 0);
  chain.set_native_size(0, 0);
}

void test_scene_cut(SlangChain &chain, FrameGen &fg) {
  for (int mode : {FrameGen::kInterpolate, FrameGen::kPixelArt}) {
    fg.set_mode(mode);
    const Scene a = scene(128, 96, 1, 10, 10, 1), b = scene(128, 96, 1, 90, 60, 7);
    const auto out = generated(chain, fg, a, b);
    const double m = match(out, b.px, 12);
    std::printf("mode %d: scene cut, %.1f%% of pixels from the new frame\n", mode, m * 100);
    CHECK(m > 0.9);
  }
}

void test_pass_and_push(SlangChain &chain, FrameGen &fg) {
  fg.set_mode(FrameGen::kInterpolate);
  const Scene a = scene(128, 96, 1, 40, 30), b = scene(128, 96, 1, 48, 30);
  fg.invalidate();
  // Generate without a previous frame shows the real one.
  fg.next(FrameGen::kGenerate);
  std::vector<uint32_t> out;
  CHECK(chain.upload(a.px.data(), a.w, a.h) && chain.render(a.w, a.h));
  CHECK(chain.read_output(&out) && match(out, a.px, 0) == 1.0);
  // Push shows the real frame as it is.
  fg.next(FrameGen::kPush);
  CHECK(chain.upload(b.px.data(), b.w, b.h) && chain.render(b.w, b.h));
  CHECK(chain.read_output(&out) && match(out, b.px, 0) == 1.0);
  // No next(): pass through (one-shot).
  CHECK(chain.upload(a.px.data(), a.w, a.h) && chain.render(a.w, a.h));
  CHECK(chain.read_output(&out) && match(out, a.px, 0) == 1.0);
  // A size change forgets the kept frame.
  const Scene small = scene(64, 48, 1, 4, 4);
  fg.next(FrameGen::kGenerate);
  CHECK(chain.upload(small.px.data(), small.w, small.h) && chain.render(small.w, small.h));
  CHECK(chain.read_output(&out) && match(out, small.px, 0) == 1.0);
  CHECK(fg.has_previous(64, 48) && !fg.has_previous(128, 96));
}

void test_shader_shades_generated(SlangChain &chain, FrameGen &fg) {
  std::string err;
  // A shader stack with history: the generated frame goes through it.
  CHECK(chain.load(bundled + "/crt-royale.slangp", &err));
  fg.set_mode(FrameGen::kInterpolate);
  const Scene a = scene(128, 96, 1, 40, 30), b = scene(128, 96, 1, 48, 30);
  fg.invalidate();
  fg.next(FrameGen::kPush);
  CHECK(chain.upload(a.px.data(), a.w, a.h) && chain.render(512, 384));
  fg.next(FrameGen::kGenerate);
  const auto t0 = std::chrono::steady_clock::now();
  CHECK(chain.upload(b.px.data(), b.w, b.h) && chain.render(512, 384));
  chain.gl().Finish();
  std::printf("crt-royale + frame generation: %.0f ms (software GL here)\n",
              std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
  std::vector<uint32_t> out;
  CHECK(chain.read_output(&out) && out.size() == size_t(512) * 384);
  CHECK(chain.gl().GetError() == GL_NO_ERROR);
  CHECK(chain.load(bundled + "/dena/stock.slangp", &err));
}

void test_state_restored(SlangChain &chain, FrameGen &fg) {
  const Gl &gl = chain.gl();
  GLuint fbo = 0, tex = 0;
  gl.GenTextures(1, &tex);
  gl.BindTexture(GL_TEXTURE_2D, tex);
  gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 8, 8);
  gl.GenFramebuffers(1, &fbo);
  gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
  gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  gl.Viewport(1, 2, 3, 4);
  gl.Enable(GL_BLEND);
  gl.ActiveTexture(GL_TEXTURE2);
  gl.BindTexture(GL_TEXTURE_2D, tex);
  gl.ActiveTexture(GL_TEXTURE3);
  const Scene a = scene(128, 96, 1, 40, 30), b = scene(128, 96, 1, 48, 30);
  fg.invalidate();
  fg.next(FrameGen::kPush);
  CHECK(chain.upload(a.px.data(), a.w, a.h) && chain.render(a.w, a.h));
  fg.next(FrameGen::kGenerate);
  CHECK(chain.upload(b.px.data(), b.w, b.h) && chain.render(a.w, a.h));
  GLint v[4] = {}, draw = 0, read = 0, active = 0, bound = 0, prog = -1, vao = -1;
  gl.GetIntegerv(GL_VIEWPORT, v);
  gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
  gl.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
  gl.GetIntegerv(GL_ACTIVE_TEXTURE, &active);
  gl.GetIntegerv(GL_CURRENT_PROGRAM, &prog);
  gl.GetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
  gl.ActiveTexture(GL_TEXTURE2);
  gl.GetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
  CHECK(v[0] == 1 && v[1] == 2 && v[2] == 3 && v[3] == 4);
  CHECK(GLuint(draw) == fbo && GLuint(read) == fbo);
  CHECK(active == GL_TEXTURE3);
  CHECK(GLuint(bound) == tex);  // unit 2 is one the filter uses
  CHECK(prog == 0 && vao == 0);
  CHECK(gl.IsEnabled(GL_BLEND));
  gl.Disable(GL_BLEND);
  gl.ActiveTexture(GL_TEXTURE0);
  gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
  gl.DeleteFramebuffers(1, &fbo);
  gl.DeleteTextures(1, &tex);
}

void test_gpu_time(SlangChain &chain, FrameGen &fg) {
  chain.gl().Finish();
  double ms = fg.take_gpu_ms(chain.gl());
  std::printf("GPU time of the last generated frame: %.2f ms (software GL here)\n", ms);
  CHECK(ms >= 0);
  CHECK(fg.take_gpu_ms(chain.gl()) < 0);  // taken
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <slang-shaders dir>\n", argv[0]);
    return 2;
  }
  bundled = std::filesystem::absolute(argv[1]).string();
  test_flow_size();
  if (!make_context()) {
    std::printf("frame_gen_tests: no desktop GL through EGL, skipped\n");
    return failures ? 1 : 77;
  }
  SlangChain chain;
  std::string err;
  if (!chain.init(proc, &err)) {
    std::printf("frame_gen_tests: %s, skipped\n", err.c_str());
    return failures ? 1 : 77;
  }
  FrameGen fg;
  if (!fg.init(chain.gl(), &err)) {
    std::fprintf(stderr, "frame_gen_tests: %s\n", err.c_str());
    chain.release();
    return 1;
  }
  CHECK(chain.load(bundled + "/dena/stock.slangp", &err));
  chain.set_source_filter(&fg);
  test_still(chain, fg);
  test_moving_square(chain, fg);
  test_pixel_art_3x(chain, fg);
  test_scene_cut(chain, fg);
  test_pass_and_push(chain, fg);
  test_state_restored(chain, fg);
  test_gpu_time(chain, fg);
  test_shader_shades_generated(chain, fg);
  chain.set_source_filter(nullptr);
  fg.release(chain.gl());
  chain.release();
  if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
  else std::printf("frame_gen_tests: OK\n");
  return failures ? 1 : 0;
}
