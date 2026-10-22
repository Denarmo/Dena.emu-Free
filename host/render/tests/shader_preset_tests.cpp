// Unit tests for the shader preset parser (no GL). Spec: docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later
#include <cstdio>
#include <fstream>
#include <string>

#include "dena/shader_preset.h"

static int failures;

#define CHECK(cond)                                                                    \
  do {                                                                                 \
    if (!(cond)) {                                                                     \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                                      \
    }                                                                                  \
  } while (0)

static std::string dir;

static std::string write(const std::string &name, const std::string &text) {
  std::string path = dir + "/" + name;
  std::ofstream(path, std::ios::binary) << text;
  return path;
}

static const char *kShader = R"glsl(// test
#pragma parameter STRENGTH "Strength (0-1)" 0.5 0.0 1.0 0.05
#pragma  parameter  SIZE "Size" 2.0 1.0 4.0
#if defined(VERTEX)
attribute vec4 VertexCoord;
void main() { gl_Position = VertexCoord; }
#elif defined(FRAGMENT)
void main() { gl_FragColor = vec4(1.0); }
#endif
)glsl";

static void test_preset_keys() {
  write("a.glsl", kShader);
  write("b.glsl", std::string(kShader) + "#pragma parameter OTHER \"Other\" 1 0 2 1\n"
                                          "#pragma parameter STRENGTH \"Dup\" 9 0 9 1\n");
  std::string p = write("p.glslp", R"glsl(# comment
shaders = "3"
shader0 = a.glsl
filter_linear0 = true
scale_type0 = source
scale0 = 2.0
alias0 = "First"   # trailing comment
shader1 = "b.glsl"
scale_type_x1 = viewport
scale_type_y1 = absolute
scale_x1 = 0.5
scale_y1 = 240
float_framebuffer1 = true
wrap_mode1 = repeat
frame_count_mod1 = 2
shader2 = a.glsl
srgb_framebuffer2 = 1
parameters = "STRENGTH;OTHER;MISSING"
STRENGTH = 0.25
OTHER = 2
)glsl");
  dena::ShaderPreset preset;
  std::string err;
  CHECK(dena::parse_preset(p, &preset, &err));
  CHECK(preset.passes.size() == 3);
  if (preset.passes.size() != 3) return;
  const auto &a = preset.passes[0], &b = preset.passes[1], &c = preset.passes[2];
  CHECK(a.filter_linear && a.scale_set);
  CHECK(a.scale_type_x == dena::ScaleType::kSource && a.scale_x == 2.0f && a.scale_y == 2.0f);
  CHECK(a.alias == "First");
  CHECK(a.source.find("gl_FragColor") != std::string::npos);
  CHECK(!b.filter_linear && b.scale_set);
  CHECK(b.scale_type_x == dena::ScaleType::kViewport && b.scale_x == 0.5f);
  CHECK(b.scale_type_y == dena::ScaleType::kAbsolute && b.scale_y == 240.0f);
  CHECK(b.float_framebuffer && b.wrap == dena::WrapMode::kRepeat && b.frame_count_mod == 2);
  CHECK(!c.scale_set && c.srgb_framebuffer && c.wrap == dena::WrapMode::kClampToEdge);
  CHECK(preset.parameters.size() == 3);
  if (preset.parameters.size() != 3) return;
  CHECK(preset.parameters[0].id == "STRENGTH" && preset.parameters[0].label == "Strength (0-1)");
  CHECK(preset.parameters[0].value == 0.25f);  // preset override
  CHECK(preset.parameters[0].max == 1.0f && preset.parameters[0].step == 0.05f);
  CHECK(preset.parameters[1].id == "SIZE" && preset.parameters[1].step == 0.1f);  // default step
  CHECK(preset.parameters[2].id == "OTHER" && preset.parameters[2].value == 2.0f);
}

static void test_single_glsl() {
  dena::ShaderPreset preset;
  std::string err;
  CHECK(dena::parse_preset(write("one.glsl", kShader), &preset, &err));
  CHECK(preset.passes.size() == 1 && !preset.passes[0].scale_set);
  CHECK(preset.parameters.size() == 2);
}

static void test_errors() {
  dena::ShaderPreset preset;
  std::string err;
  CHECK(!dena::parse_preset(dir + "/nope.glslp", &preset, &err) && !err.empty());
  CHECK(!dena::parse_preset(write("n.glslp", "shaders = 0\n"), &preset, &err));
  CHECK(!dena::parse_preset(write("m.glslp", "shaders = 1\nshader0 = missing.glsl\n"), &preset,
                            &err));
  CHECK(err.find("missing.glsl") != std::string::npos);
  CHECK(!dena::parse_preset(write("t.glslp", "shaders = 1\nshader0 = a.glsl\ntextures = LUT\n"
                                             "LUT = lut.png\n"),
                            &preset, &err));
  CHECK(err.find("textures") != std::string::npos);
  write("inc.glsl", "#include \"x.inc\"\n");
  CHECK(!dena::parse_preset(write("i.glslp", "shaders = 1\nshader0 = inc.glsl\n"), &preset, &err));
  CHECK(!dena::parse_preset(write("s.slangp", "shaders = 1\n"), &preset, &err));
}

static void test_prepare_stage() {
  std::string vs = dena::prepare_stage(kShader, "VERTEX");
  std::string fs = dena::prepare_stage(kShader, "FRAGMENT");
  CHECK(vs.find("#define VERTEX\n") == 0);
  CHECK(fs.find("#define FRAGMENT\n") == 0);
  CHECK(vs.find("#pragma") == std::string::npos && fs.find("#pragma") == std::string::npos);
  CHECK(fs.find("#define PARAMETER_UNIFORM") != std::string::npos);
  CHECK(fs.find("precision mediump float;") != std::string::npos);
  CHECK(vs.find("precision mediump float;") == std::string::npos);
  CHECK(fs.find("#line 1\n") != std::string::npos);

  // #version stays first; fragment-only sources have no vertex half.
  std::string v300 = "#version 300 es\nprecision highp float;\nout vec4 c;\nvoid main(){c=vec4(1);}\n";
  CHECK(dena::prepare_stage(v300, "VERTEX").empty());
  std::string f = dena::prepare_stage(v300, "FRAGMENT");
  CHECK(f.find("#version 300 es\n") == 0);
  CHECK(f.find("#define FRAGMENT") == std::string::npos);  // no guards to select
  CHECK(f.find("precision mediump") == std::string::npos);  // has its own

  std::string vertex_only = "#if defined(VERTEX)\nvoid main(){}\n#endif\n";
  CHECK(dena::prepare_stage(vertex_only, "FRAGMENT").empty());
}

static void test_bundled_presets(const std::string &shaders_dir) {
  const char *ids[] = {"sharp-bilinear", "scanlines", "crt-fast", "crt-lottes",
                       "crt-easymode",   "crt-aperture", "crt-geom", "crt-bloom",
                       "lcd-grid",       "lcd3x",     "dot-matrix"};
  for (const char *id : ids) {
    dena::ShaderPreset preset;
    std::string err;
    std::string path = shaders_dir + "/" + id + "/" + id + ".glslp";
    bool ok = dena::parse_preset(path, &preset, &err);
    if (!ok) std::fprintf(stderr, "%s: %s\n", id, err.c_str());
    CHECK(ok && !preset.passes.empty());
  }
}

// shaders.md, Upscale: the filter for cores with no resolution option.
static void test_upscale_filter(const std::string &shaders_dir) {
  dena::ShaderPreset preset;
  std::string err;
  bool ok = dena::parse_preset(shaders_dir + "/_upscale/xbrz-freescale.glslp", &preset, &err);
  if (!ok) std::fprintf(stderr, "_upscale: %s\n", err.c_str());
  CHECK(ok && preset.passes.size() == 1);
  if (ok) CHECK(!preset.passes[0].filter_linear);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: shader_preset_tests <tmp dir> <host/shaders>\n");
    return 2;
  }
  dir = argv[1];
  test_preset_keys();
  test_single_glsl();
  test_errors();
  test_prepare_stage();
  test_bundled_presets(argv[2]);
  test_upscale_filter(argv[2]);
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("ok\n");
  return 0;
}
