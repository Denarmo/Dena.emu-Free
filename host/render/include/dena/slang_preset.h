// libretro slang presets (.slangp) and shaders (.slang): parsing, #include,
// stage split and the rewrite to desktop GLSL. No GL here, so it is testable
// on every host.
// Spec: docs/specs/shader-stacks.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>
#include <vector>

namespace dena {
namespace slang {

enum class Scale { kSource, kViewport, kAbsolute, kOriginal };
enum class Wrap { kClampToBorder, kClampToEdge, kRepeat, kMirroredRepeat };

// Render target formats a pass can ask for (`#pragma format`, VkFormat names
// without VK_FORMAT_). kDefault: RGBA8 unless the preset sets float or sRGB.
enum class Format {
  kDefault, kR8G8B8A8Unorm, kR8G8B8A8Srgb, kA2B10G10R10UnormPack32,
  kR16G16B16A16Sfloat, kR32G32B32A32Sfloat, kR16Sfloat, kR16G16Sfloat,
  kR32Sfloat, kR32G32Sfloat, kR8Unorm, kR8G8Unorm, kR16Unorm, kR16G16Unorm,
  kR16G16B16A16Unorm, kR32Uint, kR32Sint, kR16Uint, kR16Sint, kR8Uint, kR8Sint,
};

// Format for a VkFormat name ("R16G16B16A16_SFLOAT"); false when unknown.
bool parse_format(const std::string &name, Format *out);

struct Pass {
  std::string path;              // the .slang file
  std::string vertex, fragment;  // the stages, includes resolved, pragmas removed
  std::string name;              // #pragma name
  std::string alias;             // aliasN, else the #pragma name
  bool filter_linear = false;
  Wrap wrap = Wrap::kClampToBorder;
  Scale scale_type_x = Scale::kSource, scale_type_y = Scale::kSource;
  float scale_x = 1.0f, scale_y = 1.0f;
  bool scale_set = false;  // the preset gave a scale type for this pass
  bool float_framebuffer = false;
  bool srgb_framebuffer = false;
  bool mipmap_input = false;
  unsigned frame_count_mod = 0;
  Format format = Format::kDefault;  // #pragma format
};

struct Texture {  // a lookup texture (`textures`)
  std::string name, path;
  bool linear = false;
  bool mipmap = false;
  Wrap wrap = Wrap::kClampToBorder;
};

struct Parameter {
  std::string id, label;
  float value = 0, min = 0, max = 0, step = 0;
};

struct Preset {
  std::vector<Pass> passes;
  std::vector<Texture> textures;
  std::vector<Parameter> parameters;  // first-seen order; preset overrides applied
};

// Reads path (.slangp, following #reference) and every pass source. A last
// pass without a scale draws at the viewport. Returns false with a message.
bool load_preset(const std::string &path, Preset *out, std::string *err);

// Reads a .slang file with its #include files resolved (relative to the file
// that names them; a cycle or a missing file is an error).
bool read_source(const std::string &path, std::string *out, std::string *err);

struct Source {
  std::string vertex, fragment;  // pragma lines removed
  std::string name;
  Format format = Format::kDefault;
  std::vector<Parameter> parameters;
};

// Splits a preprocessed source at `#pragma stage` (lines before the first one
// go to both stages) and reads the name, format and parameter pragmas.
bool split_source(const std::string &text, Source *out, std::string *err);

// Rewrites a Vulkan GLSL stage for desktop GL with GLSL `version` (420 to
// 460): the #version line, push constants as a std140 uniform block, no
// descriptor sets, gl_VertexIndex as gl_VertexID.
std::string to_desktop_glsl(const std::string &stage, int version);

}  // namespace slang
}  // namespace dena
