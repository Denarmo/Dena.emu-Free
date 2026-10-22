// GL tests for the shader chain: an offscreen GLES 3 context (EGL, Mesa's
// surfaceless platform when available). Exits 77 (skipped) without one.
// Spec: docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "dena/shader_chain.h"

static int failures;

#define CHECK(cond)                                                                    \
  do {                                                                                 \
    if (!(cond)) {                                                                     \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                                      \
    }                                                                                  \
  } while (0)

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
  const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  EGLContext c = eglCreateContext(d, n ? cfg : nullptr, EGL_NO_CONTEXT, ctx_attrs);
  if (c == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c);
}

struct Target {
  GLuint fbo = 0, tex = 0;
  unsigned w, h;
  Target(unsigned w_, unsigned h_) : w(w_), h(h_) {
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(w), GLsizei(h));
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
  }
  ~Target() {
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &tex);
  }
  // RGBA bytes, row 0 = framebuffer row 0.
  std::vector<uint8_t> read() const {
    std::vector<uint8_t> px(size_t(w) * h * 4);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE, px.data());
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return px;
  }
};

constexpr unsigned kW = 256, kH = 224;

// Test card: colour depends on x and y so a misplaced or flipped pixel shows.
static uint32_t card(unsigned x, unsigned y) {
  return (uint32_t(x) & 0xff) | (uint32_t(y) & 0xff) << 8 | uint32_t((x / 16 + y / 16) % 2 ? 200 : 40) << 16 |
         0xff000000u;
}

static GLuint make_source(uint32_t (*fn)(unsigned, unsigned)) {
  std::vector<uint32_t> px(size_t(kW) * kH);
  for (unsigned y = 0; y < kH; y++)
    for (unsigned x = 0; x < kW; x++) px[size_t(y) * kW + x] = fn(x, y);
  GLuint t;
  glGenTextures(1, &t);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, kW, kH);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, kW, kH, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
  glBindTexture(GL_TEXTURE_2D, 0);
  return t;
}

static std::string tmp;

// DENA_SHADER_DUMP=<dir> writes each bundled shader's output as a PPM, to
// look at by eye.
static void dump(const Target &t, const std::string &name) {
  const char *dir = std::getenv("DENA_SHADER_DUMP");
  if (!dir) return;
  auto px = t.read();
  std::ofstream f(std::string(dir) + "/" + name + ".ppm", std::ios::binary);
  f << "P6\n" << t.w << " " << t.h << "\n255\n";
  for (unsigned y = 0; y < t.h; y++)
    for (unsigned x = 0; x < t.w; x++) f.write(reinterpret_cast<const char *>(&px[(size_t(y) * t.w + x) * 4]), 3);
}

static bool load_file(dena::ShaderChain &chain, const std::string &name, const std::string &text) {
  std::string path = tmp + "/" + name;
  std::ofstream(path, std::ios::binary) << text;
  dena::ShaderPreset preset;
  std::string err;
  if (!dena::parse_preset(path, &preset, &err) || !chain.load(preset, &err)) {
    std::fprintf(stderr, "%s: %s\n", name.c_str(), err.c_str());
    return false;
  }
  return true;
}

static const char *kPassthrough = R"glsl(
#if defined(VERTEX)
attribute vec4 VertexCoord;
attribute vec4 TexCoord;
uniform mat4 MVPMatrix;
varying vec2 uv;
void main() { gl_Position = MVPMatrix * VertexCoord; uv = TexCoord.xy; }
#elif defined(FRAGMENT)
precision highp float;
uniform sampler2D Texture;
varying vec2 uv;
void main() { gl_FragColor = texture2D(Texture, uv); }
#endif
)glsl";

static uint32_t at(const std::vector<uint8_t> &px, unsigned w, unsigned x, unsigned y) {
  uint32_t v;
  std::memcpy(&v, &px[(size_t(y) * w + x) * 4], 4);
  return v | 0xff000000u;
}

static void test_passthrough_and_flip(GLuint src) {
  dena::ShaderChain chain;
  CHECK(load_file(chain, "pass.glsl", kPassthrough));
  Target t(kW * 4, kH * 4);
  chain.render(src, kW, kH, t.fbo, 0, 0, t.w, t.h, false);
  CHECK(glGetError() == GL_NO_ERROR);
  auto px = t.read();
  int bad = 0;
  for (unsigned y = 0; y < t.h; y += 3)
    for (unsigned x = 0; x < t.w; x += 3) bad += at(px, t.w, x, y) != card(x / 4, y / 4);
  CHECK(bad == 0);

  chain.render(src, kW, kH, t.fbo, 0, 0, t.w, t.h, true);
  px = t.read();
  bad = 0;
  for (unsigned y = 0; y < t.h; y += 3)
    for (unsigned x = 0; x < t.w; x += 3) bad += at(px, t.w, x, y) != card(x / 4, kH - 1 - y / 4);
  CHECK(bad == 0);
}

// Two passes: the first doubles the picture into an aliased target; the
// second reads it through the alias and PassPrev2 (the original).
static void test_multipass(GLuint src) {
  std::ofstream(tmp + "/second.glsl") << R"glsl(
#if defined(VERTEX)
attribute vec4 VertexCoord;
attribute vec4 TexCoord;
uniform mat4 MVPMatrix;
varying vec2 uv;
void main() { gl_Position = MVPMatrix * VertexCoord; uv = TexCoord.xy; }
#elif defined(FRAGMENT)
precision highp float;
uniform sampler2D Texture;
uniform sampler2D Doubled;
uniform sampler2D PassPrev2Texture;
uniform vec2 DoubledSize;
uniform vec2 TextureSize;
uniform vec2 OrigTextureSize;
varying vec2 uv;
void main() {
  // Red: the alias matches the pass input; green: sizes are as expected.
  float same = distance(texture2D(Doubled, uv).rgb, texture2D(Texture, uv).rgb) < 0.01 ? 1.0 : 0.0;
  float sizes = (DoubledSize == TextureSize && OrigTextureSize * 2.0 == TextureSize) ? 1.0 : 0.0;
  float orig = distance(texture2D(PassPrev2Texture, uv).rgb, texture2D(Texture, uv).rgb) < 0.01 ? 1.0 : 0.0;
  gl_FragColor = vec4(same, sizes, orig, 1.0);
}
#endif
)glsl";
  std::ofstream(tmp + "/first.glsl") << kPassthrough;
  std::ofstream(tmp + "/two.glslp") << "shaders = 2\nshader0 = first.glsl\nscale_type0 = source\n"
                                       "scale0 = 2\nalias0 = Doubled\nshader1 = second.glsl\n";
  dena::ShaderPreset preset;
  std::string err;
  dena::ShaderChain chain;
  CHECK(dena::parse_preset(tmp + "/two.glslp", &preset, &err) && chain.load(preset, &err));
  Target t(512, 448);
  chain.render(src, kW, kH, t.fbo, 0, 0, t.w, t.h, false);
  CHECK(glGetError() == GL_NO_ERROR);
  auto px = t.read();
  uint32_t mid = at(px, t.w, 100, 100);
  CHECK((mid & 0xff) == 0xff);          // alias bound
  CHECK(((mid >> 8) & 0xff) == 0xff);   // sizes
  CHECK(((mid >> 16) & 0xff) == 0xff);  // PassPrev2 is the original
}

static uint32_t gray(unsigned, unsigned) { return 0xff808080u; }

static void test_scanlines(const std::string &shaders) {
  GLuint src = make_source(gray);
  dena::ShaderPreset preset;
  std::string err;
  dena::ShaderChain chain;
  CHECK(dena::parse_preset(shaders + "/scanlines/scanlines.glslp", &preset, &err) &&
        chain.load(preset, &err));
  Target t(kW * 4, kH * 4);
  chain.render(src, kW, kH, t.fbo, 0, 0, t.w, t.h, false);
  auto px = t.read();
  // Rows 4k+1 and 4k+2 are the beam's centre; row 4k is between source rows.
  int brighter = 0;
  for (unsigned y = 0; y + 4 < t.h; y += 4)
    brighter += (at(px, t.w, 50, y + 2) & 0xff) > (at(px, t.w, 50, y) & 0xff) + 20;
  CHECK(brighter == int(kH) - 1);
  CHECK(chain.set_parameter("SCANLINE_STRENGTH", 5.0f));  // clamped to 1
  CHECK(chain.parameters()[0].value == 1.0f);
  CHECK(!chain.set_parameter("NOPE", 1.0f));
  glDeleteTextures(1, &src);
}

static GLuint make_gray(unsigned w, unsigned h) {
  std::vector<uint32_t> px(size_t(w) * h, 0xff808080u);
  GLuint t;
  glGenTextures(1, &t);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, GLsizei(w), GLsizei(h));
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(w), GLsizei(h), GL_RGBA, GL_UNSIGNED_BYTE,
                  px.data());
  glBindTexture(GL_TEXTURE_2D, 0);
  return t;
}

// Dark bands down column x: one per drawn scanline gap.
static int dark_bands(const Target &t, unsigned x) {
  auto px = t.read();
  int lo = 255, hi = 0;
  for (unsigned y = 0; y < t.h; y++) {
    int v = int(at(px, t.w, x, y) & 0xff);
    lo = std::min(lo, v);
    hi = std::max(hi, v);
  }
  int mid = (lo + hi) / 2, bands = 0;
  bool dark = false;
  for (unsigned y = 0; y < t.h; y++) {
    bool d = int(at(px, t.w, x, y) & 0xff) < mid;
    bands += d && !dark;
    dark = d;
  }
  return bands;
}

// shaders.md, Native lines: one scanline per game line at any viewport scale
// and for each system's size, and an upscaled frame (k x native) draws the
// same lines as the native one.
static void test_native_lines(const std::string &shaders) {
  dena::ShaderPreset preset;
  std::string err;
  CHECK(dena::parse_preset(shaders + "/scanlines/scanlines.glslp", &preset, &err));
  struct Case {
    const char *system;
    unsigned w, h, k, vp_w, vp_h;
  };
  const Case cases[] = {
      {"nes", 256, 240, 1, 1080, 1012},  // 4.2x, not a whole scale
      {"snes", 256, 224, 1, 1000, 875},  // 3.9x
      {"gb", 160, 144, 1, 720, 648},     // 4.5x
      {"gba", 240, 160, 1, 1080, 720},   // 4.5x
      {"n64", 320, 240, 2, 1440, 1080},  // the core's default 640x480
      {"n64", 320, 240, 4, 1440, 1080},  // 4x upscale
      {"psp", 480, 272, 3, 1920, 1088},  // 3x upscale
      {"psx", 320, 240, 2, 1280, 960},   // enhanced resolution
  };
  for (const Case &c : cases) {
    dena::ShaderChain chain;
    CHECK(chain.load(preset, &err));
    chain.set_native_size(c.w, c.h);
    GLuint src = make_gray(c.w * c.k, c.h * c.k);
    Target t(c.vp_w, c.vp_h);
    chain.render(src, c.w * c.k, c.h * c.k, t.fbo, 0, 0, t.w, t.h, false);
    dump(t, std::string("native-") + c.system + "-x" + std::to_string(c.k));
    int bands = dark_bands(t, t.w / 2);
    // The bottom edge may or may not end in a gap.
    bool ok = bands >= int(c.h) - 1 && bands <= int(c.h) + 1;
    if (!ok)
      std::fprintf(stderr, "%s %ux%u x%u: %d dark bands, want %u\n", c.system, c.w, c.h, c.k,
                   bands, c.h);
    CHECK(ok);
    CHECK(glGetError() == GL_NO_ERROR);
    glDeleteTextures(1, &src);
  }
  // Native size unknown: the frame is its own native size.
  CHECK(dena::native_scale(640, 480, 0, 0) == 1);
  CHECK(dena::native_scale(512, 224, 256, 224) == 1);  // SNES hi-res stays
  CHECK(dena::native_scale(1280, 960, 320, 240) == 4);
  CHECK(dena::native_scale(100, 100, 320, 240) == 1);
}

static void test_bundled(const std::string &shaders, GLuint src) {
  const char *ids[] = {"sharp-bilinear", "scanlines", "crt-fast", "crt-lottes",
                       "crt-easymode",   "crt-aperture", "crt-geom", "crt-bloom",
                       "lcd-grid",       "lcd3x",     "dot-matrix"};
  for (const char *id : ids) {
    dena::ShaderPreset preset;
    std::string err;
    dena::ShaderChain chain;
    bool ok = dena::parse_preset(shaders + "/" + id + "/" + id + ".glslp", &preset, &err) &&
              chain.load(preset, &err);
    if (!ok) std::fprintf(stderr, "%s: %s\n", id, err.c_str());
    CHECK(ok);
    if (!ok) continue;
    Target big(1024, 896), small(640, 480);
    for (int frame = 0; frame < 3; frame++) {
      chain.set_time(frame / 60.0);
      chain.render(src, kW, kH, big.fbo, 0, 0, big.w, big.h, frame == 2);
    }
    chain.render(src, kW, kH, small.fbo, 0, 0, small.w, small.h, false);  // resize
    dump(small, id);
    GLenum e = glGetError();
    if (e != GL_NO_ERROR) std::fprintf(stderr, "%s: GL error 0x%x\n", id, e);
    CHECK(e == GL_NO_ERROR);
    for (const Target *t : {&big, &small}) {
      auto px = t->read();
      size_t lit = 0;
      for (size_t i = 0; i < px.size(); i += 4) lit += (px[i] | px[i + 1] | px[i + 2]) > 8;
      if (lit < px.size() / 4 / 4) std::fprintf(stderr, "%s: mostly blank (%zu lit)\n", id, lit);
      CHECK(lit >= px.size() / 4 / 4);
    }
  }
}

// shaders.md, Upscale: the filter draws a frame at 2x-4x its size with no GL
// error and keeps the picture (a flat test card stays lit).
static void test_upscale_filter(const std::string &shaders, GLuint src) {
  dena::ShaderPreset preset;
  std::string err;
  dena::ShaderChain chain;
  bool ok = dena::parse_preset(shaders + "/_upscale/xbrz-freescale.glslp", &preset, &err) &&
            chain.load(preset, &err);
  if (!ok) std::fprintf(stderr, "_upscale: %s\n", err.c_str());
  CHECK(ok);
  if (!ok) return;
  for (unsigned f = 2; f <= 4; f++) {
    Target t(kW * f, kH * f);
    chain.render(src, kW, kH, t.fbo, 0, 0, t.w, t.h, false);
    CHECK(glGetError() == GL_NO_ERROR);
    auto px = t.read();
    size_t lit = 0;
    for (size_t i = 0; i < px.size(); i += 4) lit += (px[i] | px[i + 1] | px[i + 2]) > 8;
    CHECK(lit >= px.size() / 4 / 4);
  }
}

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: shader_chain_tests <tmp dir> <host/shaders>\n");
    return 2;
  }
  if (!make_context()) {
    std::printf("skipped: no EGL/GLES 3 context\n");
    return 77;
  }
  std::printf("GL: %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
  tmp = argv[1];
  GLuint src = make_source(card);
  test_passthrough_and_flip(src);
  test_multipass(src);
  test_scanlines(argv[2]);
  test_native_lines(argv[2]);
  test_bundled(argv[2], src);
  test_upscale_filter(argv[2], src);
  glDeleteTextures(1, &src);
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("ok\n");
  return 0;
}
