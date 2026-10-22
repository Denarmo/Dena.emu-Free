// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shader-stacks.md (acceptance tests, host, desktop GL)
// Renders slang presets offscreen in a desktop GL context through EGL
// (surfaceless Mesa works). Exits 77 (skipped) when no GL 4.2 is available.
// Usage: slang_chain_tests <tmp dir> <host/slang-shaders>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "dena/slang_chain.h"

using namespace dena::slang;

namespace {

int failures = 0;
std::string tmp, bundled;

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
  // Surfaceless Mesa may list no configs; EGL_KHR_no_config_context then.
  if (!eglChooseConfig(dpy, attribs, &config, 1, &n) || n == 0) config = EGL_NO_CONFIG_KHR;
  const EGLint ctx_attribs[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 2,
                                EGL_CONTEXT_OPENGL_PROFILE_MASK,
                                EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE};
  EGLContext ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attribs);
  if (ctx == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == EGL_TRUE;
}

void write(const std::string &name, const std::string &text) {
  std::ofstream f(tmp + "/" + name, std::ios::binary);
  f << text;
}

// A one-pass preset whose fragment shader body is `body` (writes FragColor).
std::string one_pass(const std::string &name, const std::string &uniforms, const std::string &samplers,
                     const std::string &body, const std::string &keys = "") {
  write(name + ".slang",
        "#version 450\n"
        "layout(push_constant) uniform Push { vec4 SourceSize; vec4 OriginalSize; vec4 OutputSize; "
        "uint FrameCount; " + uniforms + " } params;\n"
        "layout(std140, set = 0, binding = 0) uniform UBO { mat4 MVP; } global;\n"
        "#pragma stage vertex\n"
        "layout(location = 0) in vec4 Position;\n"
        "layout(location = 1) in vec2 TexCoord;\n"
        "layout(location = 0) out vec2 vTexCoord;\n"
        "void main() { gl_Position = global.MVP * Position; vTexCoord = TexCoord; }\n"
        "#pragma stage fragment\n"
        "layout(location = 0) in vec2 vTexCoord;\n"
        "layout(location = 0) out vec4 FragColor;\n"
        "layout(set = 0, binding = 2) uniform sampler2D Source;\n" + samplers +
        "void main() { " + body + " }\n");
  write(name + ".slangp", "shaders = 1\nshader0 = " + name + ".slang\n" + keys);
  return tmp + "/" + name + ".slangp";
}

uint32_t card(unsigned x, unsigned y) {
  return 0xff000000u | (x & 255) << 16 | (y & 255) << 8 | ((x ^ y) & 255);
}

std::vector<uint32_t> test_card(unsigned w, unsigned h) {
  std::vector<uint32_t> px(size_t(w) * h);
  for (unsigned y = 0; y < h; y++)
    for (unsigned x = 0; x < w; x++) px[size_t(y) * w + x] = card(x, y);
  return px;
}

unsigned channel(uint32_t px, int shift) { return (px >> shift) & 255; }

double brightness(const std::vector<uint32_t> &px) {
  double sum = 0;
  for (uint32_t p : px) sum += channel(p, 16) + channel(p, 8) + channel(p, 0);
  return px.empty() ? 0 : sum / (3.0 * double(px.size()));
}

// DENA_SLANG_DUMP=1 writes each bundled preset's picture to <tmp>/<id>.ppm.
void dump(const std::string &id, const std::vector<uint32_t> &px, unsigned w, unsigned h) {
  if (!std::getenv("DENA_SLANG_DUMP")) return;
  std::ofstream f(tmp + "/" + id + ".ppm", std::ios::binary);
  f << "P6\n" << w << " " << h << "\n255\n";
  for (uint32_t p : px) {
    const char rgb[3] = {char(channel(p, 16)), char(channel(p, 8)), char(channel(p, 0))};
    f.write(rgb, 3);
  }
}

bool near(unsigned a, unsigned b, unsigned tol = 2) { return a > b ? a - b <= tol : b - a <= tol; }

void test_bundled(SlangChain &chain) {
  const std::map<std::string, size_t> kPasses = {
      {"sharp-bilinear", 1}, {"scanlines", 1},   {"crt-fast", 1},
      {"crt-lottes", 1},     {"crt-easymode", 1}, {"crt-aperture", 1},
      {"crt-geom", 1},       {"crt-royale", 12},  {"crt-guest-advanced", 12},
      {"gtu", 3},            {"lcd-grid", 1},     {"lcd3x", 1},
      {"dot-matrix", 1},
  };
  const auto px = test_card(256, 224);
  for (const auto &kv : kPasses) {
    std::string err;
    bool ok = chain.load(bundled + "/" + kv.first + ".slangp", &err);
    if (!ok) std::fprintf(stderr, "%s: %s\n", kv.first.c_str(), err.c_str());
    CHECK(ok);
    if (!ok) continue;
    CHECK(chain.pass_count() == kv.second);
    std::vector<uint32_t> out;
    double best = 0;
    for (int frame = 0; frame < 3; frame++) {  // some stacks fill feedback first
      CHECK(chain.upload(px.data(), 256, 224));
      CHECK(chain.render(1280, 960));
      CHECK(chain.read_output(&out));
      best = std::max(best, brightness(out));
    }
    dump(kv.first, out, 1280, 960);
    CHECK(chain.gl().GetError() == GL_NO_ERROR);
    CHECK(chain.output_width() == 1280 && chain.output_height() == 960);
    CHECK(out.size() == size_t(1280) * 960);
    if (best < 8.0) std::fprintf(stderr, "%s: picture is dark (%.1f)\n", kv.first.c_str(), best);
    CHECK(best >= 8.0);
  }
}

void test_passthrough(SlangChain &chain) {
  std::string err;
  CHECK(chain.load(bundled + "/dena/stock.slangp", &err));
  const auto px = test_card(64, 56);
  CHECK(chain.upload(px.data(), 64, 56));
  CHECK(chain.render(256, 224));
  std::vector<uint32_t> out;
  CHECK(chain.read_output(&out));
  bool same = out.size() == size_t(256) * 224;
  for (unsigned y = 0; same && y < 224; y++)
    for (unsigned x = 0; same && x < 256; x++)
      same = (out[size_t(y) * 256 + x] & 0xffffff) == (card(x / 4, y / 4) & 0xffffff);
  CHECK(same);  // nearest 4x, top row first
}

void test_history_and_feedback(SlangChain &chain) {
  std::string err;
  std::string path = one_pass("history", "", "layout(set = 0, binding = 3) uniform sampler2D OriginalHistory1;\n",
                              "FragColor = texture(OriginalHistory1, vTexCoord);");
  CHECK(chain.load(path, &err));
  std::vector<uint32_t> a(16 * 16, 0xff102030u), b(16 * 16, 0xff405060u), out;
  CHECK(chain.upload(a.data(), 16, 16) && chain.render(16, 16));
  CHECK(chain.read_output(&out) && (out[0] & 0xffffff) == 0);  // no history yet
  CHECK(chain.upload(b.data(), 16, 16) && chain.render(16, 16));
  CHECK(chain.read_output(&out) && (out[0] & 0xffffff) == 0x102030);  // last frame

  path = one_pass("feedback", "", "layout(set = 0, binding = 3) uniform sampler2D PassFeedback0;\n",
                  "FragColor = vec4(texture(PassFeedback0, vTexCoord).rgb + vec3(0.25), 1.0);");
  CHECK(chain.load(path, &err));
  for (int i = 0; i < 2; i++) CHECK(chain.upload(a.data(), 16, 16) && chain.render(16, 16));
  CHECK(chain.read_output(&out));
  CHECK(!out.empty() && near(channel(out[0], 16), 128));
  if (!err.empty()) std::fprintf(stderr, "feedback: %s\n", err.c_str());
}

void test_lut(SlangChain &chain) {
  const std::string png = bundled + "/crt/shaders/crt-royale/TileableLinearApertureGrille15Wide8And5d5SpacingResizeTo64.png";
  std::string path = one_pass("lut", "vec4 MaskSize;", "layout(set = 0, binding = 3) uniform sampler2D Mask;\n",
                              "FragColor = vec4(texture(Mask, vTexCoord).r, params.MaskSize.x / 255.0, "
                              "params.MaskSize.y / 255.0, 1.0);",
                              "textures = Mask\nMask = " + png + "\n");
  std::string err;
  CHECK(chain.load(path, &err));
  if (!err.empty()) std::fprintf(stderr, "lut: %s\n", err.c_str());
  std::vector<uint32_t> a(16 * 16, 0xff000000u), out;
  CHECK(chain.upload(a.data(), 16, 16) && chain.render(64, 64));
  CHECK(chain.read_output(&out));
  unsigned lit = 0;
  for (uint32_t p : out) lit += channel(p, 16) > 0;
  CHECK(lit > 0);  // the mask was sampled
  CHECK(!out.empty() && channel(out[0], 8) == 64);  // MaskSize: 64 wide
}

void test_native_size(SlangChain &chain) {
  std::string path = one_pass("native", "", "",
                              "FragColor = vec4(params.OriginalSize.x / 1024.0, params.SourceSize.y / 1024.0, "
                              "params.OutputSize.x / 1024.0, 1.0);");
  std::string err;
  CHECK(chain.load(path, &err));
  chain.set_native_size(256, 224);
  const auto px = test_card(1024, 896);  // 4x internal resolution
  std::vector<uint32_t> out;
  CHECK(chain.upload(px.data(), 1024, 896) && chain.render(1024, 896));
  CHECK(chain.read_output(&out) && !out.empty());
  if (!out.empty()) {
    CHECK(near(channel(out[0], 16), 64));   // 256 / 1024
    CHECK(near(channel(out[0], 8), 56));    // 224 / 1024
    CHECK(near(channel(out[0], 0), 255));   // the output stays full size
  }
  chain.set_native_size(0, 0);
}

void test_state_restored(SlangChain &chain) {
  const Gl &gl = chain.gl();
  std::string err;
  CHECK(chain.load(bundled + "/crt-royale.slangp", &err));
  GLuint fbo = 0, tex = 0;
  gl.GenTextures(1, &tex);
  gl.BindTexture(GL_TEXTURE_2D, tex);
  gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 8, 8);
  gl.GenFramebuffers(1, &fbo);
  gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
  gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  gl.Viewport(1, 2, 3, 4);
  gl.Enable(GL_BLEND);
  gl.ActiveTexture(GL_TEXTURE3);
  const auto px = test_card(256, 224);
  CHECK(chain.upload(px.data(), 256, 224) && chain.render(640, 480));
  GLint v[4] = {}, draw = 0, read = 0, active = 0, bound = 0;
  gl.GetIntegerv(GL_VIEWPORT, v);
  gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
  gl.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
  gl.GetIntegerv(GL_ACTIVE_TEXTURE, &active);
  gl.ActiveTexture(GL_TEXTURE0);
  gl.GetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
  CHECK(v[0] == 1 && v[1] == 2 && v[2] == 3 && v[3] == 4);
  CHECK(GLuint(draw) == fbo && GLuint(read) == fbo);
  CHECK(active == GL_TEXTURE3);
  CHECK(GLuint(bound) == tex);
  CHECK(gl.IsEnabled(GL_BLEND));
  gl.Disable(GL_BLEND);
  gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
  gl.DeleteFramebuffers(1, &fbo);
  gl.DeleteTextures(1, &tex);
}

void test_4k(SlangChain &chain) {
  std::string err;
  CHECK(chain.load(bundled + "/crt-royale.slangp", &err));
  const auto px = test_card(256, 224);
  const auto t0 = std::chrono::steady_clock::now();
  CHECK(chain.upload(px.data(), 256, 224) && chain.render(3840, 2160));
  chain.gl().Finish();
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  CHECK(chain.output_width() == 3840 && chain.output_height() == 2160);
  CHECK(chain.gl().GetError() == GL_NO_ERROR);
  std::printf("crt-royale 3840x2160: %zu passes, %.0f ms (software GL here)\n", chain.pass_count(), ms);
  for (size_t i = 0; i < chain.pass_count(); i++)
    std::printf("  pass %zu: %ux%u\n", i, chain.pass_width(i), chain.pass_height(i));
}

class RedFilter : public SourceFilter {
 public:
  explicit RedFilter(const Gl &gl) {
    gl.GenTextures(1, &tex);
    gl.BindTexture(GL_TEXTURE_2D, tex);
    gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 4, 4);
    std::vector<uint32_t> red(16, 0xff0000ffu);  // RGBA bytes: R=255
    gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, red.data());
  }
  GLuint filter(const Gl &, GLuint, unsigned *w, unsigned *h) override {
    calls++;
    *w = 4;
    *h = 4;
    return tex;
  }
  GLuint tex = 0;
  int calls = 0;
};

void test_source_filter(SlangChain &chain) {
  std::string err;
  CHECK(chain.load(bundled + "/dena/stock.slangp", &err));
  RedFilter red(chain.gl());
  chain.set_source_filter(&red);
  std::vector<uint32_t> blue(16 * 16, 0xff0000ffu), out;
  CHECK(chain.upload(blue.data(), 16, 16) && chain.render(32, 32));
  CHECK(red.calls == 1);
  CHECK(chain.read_output(&out) && !out.empty() && (out[0] & 0xffffff) == 0xff0000);
  chain.set_source_filter(nullptr);
  chain.gl().DeleteTextures(1, &red.tex);
}

void test_errors(SlangChain &chain) {
  std::string err;
  CHECK(chain.load(bundled + "/dena/stock.slangp", &err));
  std::string bad = one_pass("broken", "", "", "FragColor = undefined_thing;");
  CHECK(!chain.load(bad, &err));
  CHECK(err.find("broken.slang") != std::string::npos);
  CHECK(chain.loaded() && chain.pass_count() == 1);  // the previous preset stays
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <tmp dir> <slang-shaders dir>\n", argv[0]);
    return 2;
  }
  tmp = argv[1];
  bundled = std::filesystem::absolute(argv[2]).string();
  std::filesystem::create_directories(tmp);
  if (!make_context()) {
    std::printf("slang_chain_tests: no desktop GL through EGL, skipped\n");
    return 77;
  }
  SlangChain chain;
  std::string err;
  if (!chain.init(proc, &err)) {
    std::printf("slang_chain_tests: %s, skipped\n", err.c_str());
    return 77;
  }
  std::printf("GL %s, GLSL %d\n", reinterpret_cast<const char *>(chain.gl().GetString(GL_VERSION)),
              chain.glsl_version());
  test_passthrough(chain);
  test_history_and_feedback(chain);
  test_lut(chain);
  test_native_size(chain);
  test_source_filter(chain);
  test_errors(chain);
  test_state_restored(chain);
  test_bundled(chain);
  test_4k(chain);
  chain.release();
  if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
  else std::printf("slang_chain_tests: OK\n");
  return failures ? 1 : 0;
}
