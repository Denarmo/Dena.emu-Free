// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shader-stacks.md
#include "dena/slang_preset.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>

namespace dena {
namespace slang {
namespace {

constexpr int kMaxReferenceDepth = 16;

bool read_file(const std::string &path, std::string *out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  std::string s = ss.str();
  if (s.size() >= 3 && s.compare(0, 3, "\xEF\xBB\xBF") == 0) s.erase(0, 3);
  s.erase(std::remove(s.begin(), s.end(), '\r'), s.end());
  *out = std::move(s);
  return true;
}

std::string trim(const std::string &s) {
  size_t a = 0, b = s.size();
  while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) a++;
  while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) b--;
  return s.substr(a, b - a);
}

std::string lower(std::string s) {
  for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

bool starts_with(const std::string &s, const char *prefix) { return s.rfind(prefix, 0) == 0; }

std::string dir_of(const std::string &path) {
  size_t slash = path.find_last_of("/\\");
  return slash == std::string::npos ? std::string() : path.substr(0, slash + 1);
}

std::string join(const std::string &dir, const std::string &rel) {
  if (rel.empty()) return rel;
  bool absolute = rel[0] == '/' || rel[0] == '\\' ||
                  (rel.size() > 1 && rel[1] == ':' && std::isalpha(static_cast<unsigned char>(rel[0])));
  return absolute ? rel : dir + rel;
}

// The text inside the first pair of quotes, else the trimmed text.
std::string unquote(const std::string &s) {
  std::string t = trim(s);
  if (!t.empty() && t[0] == '"') {
    size_t close = t.find('"', 1);
    return t.substr(1, close == std::string::npos ? std::string::npos : close - 1);
  }
  return t;
}

struct Prop {
  std::string value;
  std::string dir;  // of the file that set it, for relative paths
};
using Props = std::map<std::string, Prop>;

bool load_props(const std::string &path, int depth, std::vector<std::string> *stack, Props *props,
                std::string *err) {
  if (depth > kMaxReferenceDepth) {
    *err = "#reference nested too deep at " + path;
    return false;
  }
  if (std::find(stack->begin(), stack->end(), path) != stack->end()) {
    *err = "#reference cycle at " + path;
    return false;
  }
  std::string text;
  if (!read_file(path, &text)) {
    *err = "cannot read " + path;
    return false;
  }
  stack->push_back(path);
  const std::string dir = dir_of(path);
  // References first, so this file's own keys override them.
  std::istringstream refs(text);
  std::string line;
  while (std::getline(refs, line)) {
    std::string t = trim(line);
    if (!starts_with(t, "#reference")) continue;
    std::string ref = unquote(t.substr(10));
    if (ref.empty()) continue;
    if (!load_props(join(dir, ref), depth + 1, stack, props, err)) return false;
  }
  std::istringstream in(text);
  while (std::getline(in, line)) {
    std::string t = trim(line);
    if (t.empty() || t[0] == '#') continue;
    size_t eq = t.find('=');
    if (eq == std::string::npos) continue;
    std::string key = trim(t.substr(0, eq)), value = trim(t.substr(eq + 1));
    if (!value.empty() && value[0] == '"') {
      value = unquote(value);
    } else {
      size_t hash = value.find('#');
      if (hash != std::string::npos) value = trim(value.substr(0, hash));
    }
    (*props)[key] = Prop{value, dir};
  }
  stack->pop_back();
  return true;
}

const Prop *get(const Props &p, const std::string &key) {
  auto it = p.find(key);
  return it == p.end() ? nullptr : &it->second;
}

bool parse_bool(const std::string &v) {
  std::string l = lower(v);
  return l == "true" || l == "1";
}

bool parse_float(const std::string &v, float *out) {
  if (v.empty()) return false;
  char *end = nullptr;
  float f = std::strtof(v.c_str(), &end);
  if (end == v.c_str()) return false;
  while (*end && std::isspace(static_cast<unsigned char>(*end))) end++;
  if (*end != '\0') return false;
  *out = f;
  return true;
}

bool parse_scale(const std::string &v, Scale *out) {
  std::string l = lower(v);
  if (l == "source") *out = Scale::kSource;
  else if (l == "viewport") *out = Scale::kViewport;
  else if (l == "absolute") *out = Scale::kAbsolute;
  else if (l == "original") *out = Scale::kOriginal;
  else return false;
  return true;
}

Wrap parse_wrap(const std::string &v) {
  std::string l = lower(v);
  if (l == "clamp_to_edge") return Wrap::kClampToEdge;
  if (l == "repeat") return Wrap::kRepeat;
  if (l == "mirrored_repeat") return Wrap::kMirroredRepeat;
  return Wrap::kClampToBorder;
}

// Splits `a "quoted label" 1 2` into tokens, keeping quoted text whole.
std::vector<std::string> tokenize(const std::string &s) {
  std::vector<std::string> out;
  size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) i++;
    if (i >= s.size()) break;
    if (s[i] == '"') {
      size_t close = s.find('"', i + 1);
      if (close == std::string::npos) close = s.size();
      out.push_back(s.substr(i + 1, close - i - 1));
      i = close + 1;
    } else {
      size_t start = i;
      while (i < s.size() && !std::isspace(static_cast<unsigned char>(s[i]))) i++;
      out.push_back(s.substr(start, i - start));
    }
  }
  return out;
}

// The rest of a `#pragma <word> ...` line, or false.
bool pragma(const std::string &line, const char *word, std::string *rest) {
  std::string t = trim(line);
  if (!starts_with(t, "#pragma")) return false;
  t = trim(t.substr(7));
  size_t n = std::char_traits<char>::length(word);
  if (t.compare(0, n, word) != 0) return false;
  if (t.size() > n && !std::isspace(static_cast<unsigned char>(t[n]))) return false;
  *rest = trim(t.substr(n));
  return true;
}

bool read_source_rec(const std::string &path, std::vector<std::string> *stack, std::string *out,
                     std::string *err) {
  if (std::find(stack->begin(), stack->end(), path) != stack->end()) {
    *err = "#include cycle at " + path;
    return false;
  }
  std::string text;
  if (!read_file(path, &text)) {
    *err = "cannot read " + path;
    return false;
  }
  stack->push_back(path);
  std::istringstream in(text);
  std::string line;
  while (std::getline(in, line)) {
    std::string t = trim(line);
    if (starts_with(t, "#include")) {
      std::string rel = unquote(t.substr(8));
      if (!read_source_rec(join(dir_of(path), rel), stack, out, err)) {
        if (err->find(" (included from ") == std::string::npos)
          *err += " (included from " + path + ")";
        return false;
      }
      continue;
    }
    *out += line;
    *out += '\n';
  }
  stack->pop_back();
  return true;
}

}  // namespace

bool parse_format(const std::string &name, Format *out) {
  static const std::map<std::string, Format> kFormats = {
      {"R8G8B8A8_UNORM", Format::kR8G8B8A8Unorm},
      {"R8G8B8A8_SRGB", Format::kR8G8B8A8Srgb},
      {"A2B10G10R10_UNORM_PACK32", Format::kA2B10G10R10UnormPack32},
      {"R16G16B16A16_SFLOAT", Format::kR16G16B16A16Sfloat},
      {"R32G32B32A32_SFLOAT", Format::kR32G32B32A32Sfloat},
      {"R16_SFLOAT", Format::kR16Sfloat},
      {"R16G16_SFLOAT", Format::kR16G16Sfloat},
      {"R32_SFLOAT", Format::kR32Sfloat},
      {"R32G32_SFLOAT", Format::kR32G32Sfloat},
      {"R8_UNORM", Format::kR8Unorm},
      {"R8G8_UNORM", Format::kR8G8Unorm},
      {"R16_UNORM", Format::kR16Unorm},
      {"R16G16_UNORM", Format::kR16G16Unorm},
      {"R16G16B16A16_UNORM", Format::kR16G16B16A16Unorm},
      {"R32_UINT", Format::kR32Uint},
      {"R32_SINT", Format::kR32Sint},
      {"R16_UINT", Format::kR16Uint},
      {"R16_SINT", Format::kR16Sint},
      {"R8_UINT", Format::kR8Uint},
      {"R8_SINT", Format::kR8Sint},
  };
  auto it = kFormats.find(name);
  if (it == kFormats.end()) return false;
  *out = it->second;
  return true;
}

bool read_source(const std::string &path, std::string *out, std::string *err) {
  out->clear();
  std::vector<std::string> stack;
  return read_source_rec(path, &stack, out, err);
}

bool split_source(const std::string &text, Source *out, std::string *err) {
  *out = Source{};
  enum { kBoth, kVertex, kFragment } stage = kBoth;
  bool any_stage = false;
  std::istringstream in(text);
  std::string line, rest;
  while (std::getline(in, line)) {
    if (pragma(line, "stage", &rest)) {
      std::string s = lower(rest);
      if (s == "vertex") stage = kVertex;
      else if (s == "fragment") stage = kFragment;
      else {
        *err = "unknown #pragma stage " + rest;
        return false;
      }
      any_stage = true;
      line.clear();
    } else if (pragma(line, "name", &rest)) {
      out->name = rest;
      line.clear();
    } else if (pragma(line, "format", &rest)) {
      if (!parse_format(rest, &out->format)) {
        *err = "unknown #pragma format " + rest;
        return false;
      }
      line.clear();
    } else if (pragma(line, "parameter", &rest)) {
      auto tok = tokenize(rest);
      Parameter p;
      if (tok.size() >= 5) {
        p.id = tok[0];
        p.label = tok[1];
        bool ok = parse_float(tok[2], &p.value) && parse_float(tok[3], &p.min) &&
                  parse_float(tok[4], &p.max);
        if (tok.size() < 6 || !parse_float(tok[5], &p.step)) p.step = 0;
        bool seen = false;
        for (const auto &q : out->parameters) seen |= q.id == p.id;
        if (ok && !seen) out->parameters.push_back(p);
      }
      line.clear();
    }
    if (stage != kFragment) out->vertex += line + "\n";
    if (stage != kVertex) out->fragment += line + "\n";
  }
  if (!any_stage) {
    *err = "no #pragma stage";
    return false;
  }
  return true;
}

std::string to_desktop_glsl(const std::string &stage, int version) {
  // #version: the first one is replaced, or one is added.
  const std::string version_line = "#version " + std::to_string(version);
  std::string s;
  bool versioned = false;
  {
    std::istringstream in(stage);
    std::string line;
    while (std::getline(in, line)) {
      if (!versioned && starts_with(trim(line), "#version")) {
        line = version_line;
        versioned = true;
      }
      s += line + "\n";
    }
  }
  if (!versioned) s = version_line + "\n" + s;

  // layout(...) qualifiers: drop descriptor sets, push_constant -> std140.
  static const std::regex kLayout(R"(layout\s*\(([^)]*)\))");
  std::string result;
  auto begin = std::sregex_iterator(s.begin(), s.end(), kLayout);
  size_t last = 0;
  for (auto it = begin; it != std::sregex_iterator(); ++it) {
    const std::smatch &m = *it;
    result += s.substr(last, size_t(m.position(0)) - last);
    last = size_t(m.position(0) + m.length(0));
    std::vector<std::string> keep;
    bool push = false, std140 = false;
    std::stringstream parts(m[1].str());
    std::string q;
    while (std::getline(parts, q, ',')) {
      std::string t = trim(q);
      std::string key = trim(t.substr(0, t.find('=')));
      if (key == "set") continue;
      if (key == "push_constant") {
        push = true;
        continue;
      }
      if (key == "std140") std140 = true;
      if (key == "std430" && push) continue;
      if (!t.empty()) keep.push_back(t);
    }
    if (push && !std140) keep.insert(keep.begin(), "std140");
    if (keep.empty()) continue;  // layout() with only a set: drop it
    result += "layout(";
    for (size_t i = 0; i < keep.size(); i++) result += (i ? ", " : "") + keep[i];
    result += ")";
  }
  result += s.substr(last);

  static const std::regex kVertexIndex(R"(\bgl_VertexIndex\b)");
  static const std::regex kInstanceIndex(R"(\bgl_InstanceIndex\b)");
  result = std::regex_replace(result, kVertexIndex, "gl_VertexID");
  result = std::regex_replace(result, kInstanceIndex, "gl_InstanceID");
  return result;
}

bool load_preset(const std::string &path, Preset *out, std::string *err) {
  *out = Preset{};
  Props props;
  std::vector<std::string> stack;
  if (!load_props(path, 0, &stack, &props, err)) return false;

  const Prop *count_p = get(props, "shaders");
  float count_f = 0;
  if (!count_p || !parse_float(count_p->value, &count_f) || count_f < 1 || count_f > 64) {
    *err = "no shaders in " + path;
    return false;
  }
  const unsigned count = unsigned(count_f);
  for (unsigned i = 0; i < count; i++) {
    const std::string n = std::to_string(i);
    const Prop *sp = get(props, "shader" + n);
    if (!sp || sp->value.empty()) {
      *err = "pass " + n + " has no shader in " + path;
      return false;
    }
    Pass pass;
    pass.path = join(sp->dir, sp->value);
    std::string text;
    if (!read_source(pass.path, &text, err)) return false;
    Source src;
    if (!split_source(text, &src, err)) {
      *err = pass.path + ": " + *err;
      return false;
    }
    pass.vertex = std::move(src.vertex);
    pass.fragment = std::move(src.fragment);
    pass.name = src.name;
    pass.format = src.format;
    for (const auto &p : src.parameters) {
      bool seen = false;
      for (const auto &q : out->parameters) seen |= q.id == p.id;
      if (!seen) out->parameters.push_back(p);
    }

    if (const Prop *p = get(props, "filter_linear" + n)) pass.filter_linear = parse_bool(p->value);
    if (const Prop *p = get(props, "wrap_mode" + n)) pass.wrap = parse_wrap(p->value);
    if (const Prop *p = get(props, "float_framebuffer" + n)) pass.float_framebuffer = parse_bool(p->value);
    if (const Prop *p = get(props, "srgb_framebuffer" + n)) pass.srgb_framebuffer = parse_bool(p->value);
    if (const Prop *p = get(props, "mipmap_input" + n)) pass.mipmap_input = parse_bool(p->value);
    if (const Prop *p = get(props, "alias" + n)) pass.alias = p->value;
    if (pass.alias.empty()) pass.alias = pass.name;
    if (const Prop *p = get(props, "frame_count_mod" + n)) {
      float f = 0;
      if (parse_float(p->value, &f) && f > 0) pass.frame_count_mod = unsigned(f);
    }

    Scale type;
    if (const Prop *p = get(props, "scale_type" + n)) {
      if (parse_scale(p->value, &type)) {
        pass.scale_type_x = pass.scale_type_y = type;
        pass.scale_set = true;
      }
    }
    if (const Prop *p = get(props, "scale_type_x" + n)) {
      if (parse_scale(p->value, &type)) {
        pass.scale_type_x = type;
        pass.scale_set = true;
      }
    }
    if (const Prop *p = get(props, "scale_type_y" + n)) {
      if (parse_scale(p->value, &type)) {
        pass.scale_type_y = type;
        pass.scale_set = true;
      }
    }
    float f = 0;
    if (const Prop *p = get(props, "scale" + n))
      if (parse_float(p->value, &f)) pass.scale_x = pass.scale_y = f;
    if (const Prop *p = get(props, "scale_x" + n))
      if (parse_float(p->value, &f)) pass.scale_x = f;
    if (const Prop *p = get(props, "scale_y" + n))
      if (parse_float(p->value, &f)) pass.scale_y = f;
    if (!pass.scale_set) pass.scale_x = pass.scale_y = 1.0f;
    out->passes.push_back(std::move(pass));
  }
  Pass &last = out->passes.back();
  if (!last.scale_set) {
    last.scale_type_x = last.scale_type_y = Scale::kViewport;
    last.scale_x = last.scale_y = 1.0f;
  }

  if (const Prop *tp = get(props, "textures")) {
    std::stringstream names(tp->value);
    std::string name;
    while (std::getline(names, name, ';')) {
      name = trim(name);
      if (name.empty()) continue;
      const Prop *pp = get(props, name);
      if (!pp || pp->value.empty()) {
        *err = "texture " + name + " has no file in " + path;
        return false;
      }
      Texture t;
      t.name = name;
      t.path = join(pp->dir, pp->value);
      if (const Prop *p = get(props, name + "_linear")) t.linear = parse_bool(p->value);
      if (const Prop *p = get(props, name + "_mipmap")) t.mipmap = parse_bool(p->value);
      if (const Prop *p = get(props, name + "_wrap_mode")) t.wrap = parse_wrap(p->value);
      out->textures.push_back(t);
    }
  }

  for (auto &p : out->parameters) {
    float v = 0;
    if (const Prop *pp = get(props, p.id))
      if (parse_float(pp->value, &v)) p.value = v;
  }
  return true;
}

}  // namespace slang
}  // namespace dena
