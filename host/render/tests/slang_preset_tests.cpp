// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shader-stacks.md (acceptance tests, host, no GL)
// Usage: slang_preset_tests <tmp dir> <host/slang-shaders>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>

#include "dena/slang_preset.h"

using namespace dena::slang;

namespace {

int failures = 0;
std::string tmp, bundled;

#define CHECK(cond)                                                   \
  do {                                                                \
    if (!(cond)) {                                                    \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
      failures++;                                                     \
    }                                                                 \
  } while (0)

void write(const std::string &name, const std::string &text) {
  std::ofstream f(tmp + "/" + name, std::ios::binary);
  f << text;
}

bool contains(const std::string &s, const std::string &part) { return s.find(part) != std::string::npos; }

const char *kPass =
    "#version 450\n"
    "layout(push_constant) uniform Push { vec4 SourceSize; float STRENGTH; } params;\n"
    "#pragma parameter STRENGTH \"Strength\" 0.5 0.0 1.0 0.05\n"
    "#pragma name First\n"
    "layout(std140, set = 0, binding = 0) uniform UBO { mat4 MVP; } global;\n"
    "#pragma stage vertex\n"
    "layout(location = 0) in vec4 Position;\n"
    "void main() { gl_Position = global.MVP * Position; int i = gl_VertexIndex; }\n"
    "#pragma stage fragment\n"
    "layout(location = 0) out vec4 FragColor;\n"
    "layout(set = 0, binding = 2) uniform sampler2D Source;\n"
    "void main() { FragColor = vec4(params.STRENGTH); }\n";

void test_keys_and_defaults() {
  write("a.slang", kPass);
  write("keys.slangp",
        "shaders = \"2\"\n"
        "shader0 = a.slang   # a comment\n"
        "filter_linear0 = true\n"
        "wrap_mode0 = repeat\n"
        "scale_type0 = absolute\n"
        "scale_x0 = 320\n"
        "scale_y0 = \"240\"\n"
        "float_framebuffer0 = true\n"
        "mipmap_input0 = 1\n"
        "frame_count_mod0 = 2\n"
        "shader1 = a.slang\n"
        "alias1 = Second\n"
        "srgb_framebuffer1 = true\n"
        "STRENGTH = 0.75\n");
  Preset p;
  std::string err;
  CHECK(load_preset(tmp + "/keys.slangp", &p, &err));
  if (p.passes.size() != 2) {
    CHECK(p.passes.size() == 2);
    return;
  }
  const Pass &a = p.passes[0], &b = p.passes[1];
  CHECK(a.filter_linear);
  CHECK(a.wrap == Wrap::kRepeat);
  CHECK(a.scale_type_x == Scale::kAbsolute && a.scale_type_y == Scale::kAbsolute);
  CHECK(a.scale_x == 320 && a.scale_y == 240);
  CHECK(a.float_framebuffer && a.mipmap_input);
  CHECK(a.frame_count_mod == 2);
  CHECK(a.alias == "First");  // from #pragma name
  CHECK(b.alias == "Second");
  CHECK(b.srgb_framebuffer);
  CHECK(!b.filter_linear);
  CHECK(b.wrap == Wrap::kClampToBorder);
  // An unscaled last pass draws at the viewport.
  CHECK(b.scale_type_x == Scale::kViewport && b.scale_x == 1.0f);
  CHECK(p.parameters.size() == 1);
  if (!p.parameters.empty()) {
    CHECK(p.parameters[0].id == "STRENGTH");
    CHECK(p.parameters[0].label == "Strength");
    CHECK(p.parameters[0].value == 0.75f);  // the preset's override
    CHECK(p.parameters[0].step == 0.05f);
  }
}

void test_reference() {
  write("sub/b.slang", kPass);
  write("sub/base.slangp",
        "shaders = 1\n"
        "shader0 = b.slang\n"
        "scale_type0 = source\n"
        "scale0 = 2.0\n"
        "textures = \"LUT;Other\"\n"
        "LUT = lut.png\n"
        "LUT_linear = true\n"
        "LUT_wrap_mode = mirrored_repeat\n"
        "Other = ../other.png\n"
        "Other_mipmap = true\n"
        "STRENGTH = 0.1\n");
  write("ref.slangp",
        "#reference \"sub/base.slangp\"\n"
        "scale0 = 3.0\n"
        "STRENGTH = 0.9\n");
  Preset p;
  std::string err;
  CHECK(load_preset(tmp + "/ref.slangp", &p, &err));
  CHECK(p.passes.size() == 1);
  if (p.passes.empty()) return;
  CHECK(p.passes[0].path == tmp + "/sub/b.slang");  // relative to the file that named it
  CHECK(p.passes[0].scale_type_x == Scale::kSource);
  CHECK(p.passes[0].scale_x == 3.0f);  // overridden
  CHECK(p.textures.size() == 2);
  if (p.textures.size() == 2) {
    CHECK(p.textures[0].name == "LUT" && p.textures[0].path == tmp + "/sub/lut.png");
    CHECK(p.textures[0].linear && p.textures[0].wrap == Wrap::kMirroredRepeat);
    CHECK(p.textures[1].path == tmp + "/sub/../other.png" && p.textures[1].mipmap);
  }
  CHECK(!p.parameters.empty() && p.parameters[0].value == 0.9f);

  write("cycle1.slangp", "#reference \"cycle2.slangp\"\n");
  write("cycle2.slangp", "#reference \"cycle1.slangp\"\n");
  CHECK(!load_preset(tmp + "/cycle1.slangp", &p, &err));
  CHECK(contains(err, "cycle"));
  CHECK(!load_preset(tmp + "/missing.slangp", &p, &err));
  write("nopass.slangp", "shaders = 1\nshader0 = nothere.slang\n");
  CHECK(!load_preset(tmp + "/nopass.slangp", &p, &err));
  CHECK(contains(err, "nothere.slang"));
}

void test_includes_and_stages() {
  write("inc/common.h", "#define COMMON 1\n#include \"deeper.h\"\n");
  write("inc/deeper.h", "#define DEEPER 2\n");
  write("inc.slang",
        "#version 450\n#include \"inc/common.h\"\n#pragma format R16G16B16A16_SFLOAT\n"
        "#pragma stage vertex\nvoid main() {}\n#pragma stage fragment\nvoid main() { }\n");
  std::string text, err;
  CHECK(read_source(tmp + "/inc.slang", &text, &err));
  CHECK(contains(text, "#define COMMON 1") && contains(text, "#define DEEPER 2"));
  Source src;
  CHECK(split_source(text, &src, &err));
  CHECK(src.format == Format::kR16G16B16A16Sfloat);
  CHECK(contains(src.vertex, "#define DEEPER") && contains(src.fragment, "#define DEEPER"));
  CHECK(!contains(src.vertex, "void main() { }") && contains(src.fragment, "void main() { }"));
  CHECK(!contains(src.vertex, "#pragma"));

  write("loop.h", "#include \"loop.h\"\n");
  CHECK(!read_source(tmp + "/loop.h", &text, &err) && contains(err, "cycle"));
  CHECK(!split_source("#version 450\nvoid main() {}\n", &src, &err));  // no stage
  CHECK(!split_source("#pragma format R5G6B5_WHATEVER\n#pragma stage vertex\n", &src, &err));
  Format f;
  CHECK(parse_format("A2B10G10R10_UNORM_PACK32", &f) && f == Format::kA2B10G10R10UnormPack32);
  CHECK(!parse_format("B8G8R8A8_UNORM_X", &f));
}

void test_desktop_glsl() {
  Source src;
  std::string err;
  CHECK(split_source(kPass, &src, &err));
  std::string v = to_desktop_glsl(src.vertex, 430);
  CHECK(contains(v, "#version 430\n"));
  CHECK(!contains(v, "#version 450"));
  CHECK(!contains(v, "push_constant"));
  CHECK(contains(v, "layout(std140) uniform Push"));
  CHECK(contains(v, "layout(std140, binding = 0) uniform UBO"));
  CHECK(!contains(v, "set ="));
  CHECK(contains(v, "gl_VertexID") && !contains(v, "gl_VertexIndex"));
  std::string f = to_desktop_glsl(src.fragment, 450);
  CHECK(contains(f, "layout(binding = 2) uniform sampler2D Source"));
  CHECK(to_desktop_glsl("void main() {}\n", 420).rfind("#version 420\n", 0) == 0);
  std::string bare = to_desktop_glsl("layout(set = 1) uniform sampler2D X;\n", 450);
  CHECK(contains(bare, "uniform sampler2D X;") && !contains(bare, "layout"));
}

void test_bundled() {
  // Every bundled preset parses, with the pass counts the catalog shows.
  const std::map<std::string, size_t> kPasses = {
      {"sharp-bilinear", 1}, {"scanlines", 1},   {"crt-fast", 1},
      {"crt-lottes", 1},     {"crt-easymode", 1}, {"crt-aperture", 1},
      {"crt-geom", 1},       {"crt-royale", 12},  {"crt-guest-advanced", 12},
      {"gtu", 3},            {"lcd-grid", 1},     {"lcd3x", 1},
      {"dot-matrix", 1},
  };
  for (const auto &kv : kPasses) {
    Preset p;
    std::string err;
    bool ok = load_preset(bundled + "/" + kv.first + ".slangp", &p, &err);
    if (!ok) std::fprintf(stderr, "%s: %s\n", kv.first.c_str(), err.c_str());
    CHECK(ok);
    CHECK(p.passes.size() == kv.second);
    for (const auto &t : p.textures) CHECK(std::ifstream(t.path).good());
  }
  Preset royale;
  std::string err;
  CHECK(load_preset(bundled + "/crt-royale.slangp", &royale, &err));
  CHECK(royale.textures.size() == 6);
  if (royale.passes.size() == 12) {
    CHECK(royale.passes[0].alias == "ORIG_LINEARIZED");
    CHECK(royale.passes[0].srgb_framebuffer);
    CHECK(royale.passes[2].scale_type_x == Scale::kAbsolute && royale.passes[2].scale_x == 320);
  }
  Preset guest;
  CHECK(load_preset(bundled + "/crt-guest-advanced.slangp", &guest, &err));
  CHECK(guest.textures.size() == 4);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <tmp dir> <slang-shaders dir>\n", argv[0]);
    return 2;
  }
  tmp = argv[1];
  bundled = argv[2];
  std::filesystem::create_directories(tmp + "/sub");
  std::filesystem::create_directories(tmp + "/inc");
  test_keys_and_defaults();
  test_reference();
  test_includes_and_stages();
  test_desktop_glsl();
  test_bundled();
  if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
  else std::printf("slang_preset_tests: OK\n");
  return failures ? 1 : 0;
}
