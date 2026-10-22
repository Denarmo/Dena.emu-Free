// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shaders.md
#include "dena/shader_preset.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>

namespace dena {
namespace {

bool read_file(const std::string &path, std::string *out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  *out = ss.str();
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

std::string dir_of(const std::string &path) {
  size_t slash = path.find_last_of("/\\");
  return slash == std::string::npos ? std::string() : path.substr(0, slash + 1);
}

bool ends_with(const std::string &s, const std::string &suffix) {
  return s.size() >= suffix.size() && lower(s.substr(s.size() - suffix.size())) == suffix;
}

// key = value lines; '#' starts a comment outside quotes; quotes are removed.
std::map<std::string, std::string> parse_properties(const std::string &text) {
  std::map<std::string, std::string> props;
  std::istringstream in(text);
  std::string line;
  while (std::getline(in, line)) {
    std::string t = trim(line);
    if (t.empty() || t[0] == '#') continue;
    size_t eq = t.find('=');
    if (eq == std::string::npos) continue;
    std::string key = trim(t.substr(0, eq)), value = trim(t.substr(eq + 1));
    if (!value.empty() && value[0] == '"') {
      size_t close = value.find('"', 1);
      value = value.substr(1, close == std::string::npos ? std::string::npos : close - 1);
    } else {
      size_t hash = value.find('#');
      if (hash != std::string::npos) value = trim(value.substr(0, hash));
    }
    props[key] = value;
  }
  return props;
}

bool parse_bool(const std::string &v) {
  std::string l = lower(v);
  return l == "true" || l == "1";
}

bool parse_float(const std::string &v, float *out) {
  if (v.empty()) return false;
  char *end = nullptr;
  float f = std::strtof(v.c_str(), &end);
  if (end == v.c_str() || *end != '\0') return false;
  *out = f;
  return true;
}

ScaleType parse_scale_type(const std::string &v) {
  std::string l = lower(v);
  if (l == "viewport") return ScaleType::kViewport;
  if (l == "absolute") return ScaleType::kAbsolute;
  return ScaleType::kSource;
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

bool is_pragma_parameter(const std::string &line) {
  std::string t = trim(line);
  if (t.rfind("#pragma", 0) != 0) return false;
  return trim(t.substr(7)).rfind("parameter", 0) == 0;
}

bool has_stage(const std::string &source, const char *stage) {
  std::string s(stage);
  return source.find("defined(" + s + ")") != std::string::npos ||
         source.find("defined " + s) != std::string::npos ||
         source.find("#ifdef " + s) != std::string::npos;
}

}  // namespace

void parse_parameters(const std::string &source, std::vector<ShaderParameter> *params) {
  std::istringstream in(source);
  std::string line;
  while (std::getline(in, line)) {
    if (!is_pragma_parameter(line)) continue;
    std::string t = trim(line);
    t = trim(t.substr(t.find("parameter") + 9));
    auto tok = tokenize(t);
    if (tok.size() < 5) continue;
    ShaderParameter p;
    p.id = tok[0];
    p.label = tok[1];
    if (!parse_float(tok[2], &p.value) || !parse_float(tok[3], &p.min) ||
        !parse_float(tok[4], &p.max))
      continue;
    if (tok.size() < 6 || !parse_float(tok[5], &p.step)) p.step = 0.1f;
    bool seen = false;
    for (const auto &q : *params) seen |= q.id == p.id;
    if (!seen) params->push_back(p);
  }
}

std::string prepare_stage(const std::string &source, const char *stage) {
  bool vertex = std::string(stage) == "VERTEX";
  bool guarded = has_stage(source, "VERTEX") || has_stage(source, "FRAGMENT");
  if (vertex && !has_stage(source, "VERTEX")) return {};
  if (!vertex && guarded && !has_stage(source, "FRAGMENT")) return {};

  std::string version, body;
  std::istringstream in(source);
  std::string line;
  bool first_code = true;
  while (std::getline(in, line)) {
    if (is_pragma_parameter(line)) {
      body += "\n";  // keep line numbers in compiler messages
      continue;
    }
    if (first_code && trim(line).rfind("#version", 0) == 0) {
      version = trim(line) + "\n";
      body += "\n";
      continue;
    }
    if (!trim(line).empty() && trim(line).rfind("//", 0) != 0) first_code = false;
    body += line + "\n";
  }
  std::string head = version;
  if (guarded) head += std::string("#define ") + stage + "\n";
  head += "#define PARAMETER_UNIFORM\n";
  if (!vertex && source.find("precision ") == std::string::npos)
    head += "precision mediump float;\n";
  // Restart numbering so compiler messages point at the original lines.
  return head + "#line 1\n" + body;
}

bool parse_preset(const std::string &path, ShaderPreset *out, std::string *err) {
  *out = ShaderPreset{};
  std::string text;
  if (!read_file(path, &text)) {
    *err = "cannot read " + path;
    return false;
  }
  if (ends_with(path, ".glsl")) {
    ShaderPass pass;
    pass.path = path;
    pass.source = text;
    parse_parameters(text, &out->parameters);
    out->passes.push_back(pass);
    return true;
  }
  if (ends_with(path, ".slangp") || ends_with(path, ".slang")) {
    *err = "slang shaders are not supported";
    return false;
  }

  auto props = parse_properties(text);
  float count_f = 0;
  if (!props.count("shaders") || !parse_float(props["shaders"], &count_f) || count_f < 1 ||
      count_f > 16) {
    *err = "preset has no valid 'shaders' count";
    return false;
  }
  if (props.count("textures") && !trim(props["textures"]).empty()) {
    *err = "lookup textures are not supported yet";
    return false;
  }
  unsigned count = unsigned(count_f);
  std::string base = dir_of(path);
  for (unsigned i = 0; i < count; i++) {
    std::string n = std::to_string(i);
    auto get = [&](const std::string &k) -> const std::string * {
      auto it = props.find(k + n);
      return it == props.end() ? nullptr : &it->second;
    };
    ShaderPass pass;
    const std::string *shader = get("shader");
    if (!shader || shader->empty()) {
      *err = "pass " + n + " has no shader";
      return false;
    }
    pass.path = base + *shader;
    if (!read_file(pass.path, &pass.source)) {
      *err = "cannot read " + pass.path;
      return false;
    }
    if (pass.source.find("#include") != std::string::npos) {
      *err = "#include in shaders is not supported yet";
      return false;
    }
    if (const auto *v = get("filter_linear")) pass.filter_linear = parse_bool(*v);
    const std::string *st = get("scale_type"), *stx = get("scale_type_x"), *sty = get("scale_type_y");
    if (st || stx || sty) {
      pass.scale_set = true;
      pass.scale_type_x = parse_scale_type(stx ? *stx : st ? *st : "source");
      pass.scale_type_y = parse_scale_type(sty ? *sty : st ? *st : "source");
    }
    float f;
    if (const auto *v = get("scale"); v && parse_float(*v, &f)) pass.scale_x = pass.scale_y = f;
    if (const auto *v = get("scale_x"); v && parse_float(*v, &f)) pass.scale_x = f;
    if (const auto *v = get("scale_y"); v && parse_float(*v, &f)) pass.scale_y = f;
    if (const auto *v = get("alias")) pass.alias = *v;
    if (const auto *v = get("float_framebuffer")) pass.float_framebuffer = parse_bool(*v);
    if (const auto *v = get("srgb_framebuffer")) pass.srgb_framebuffer = parse_bool(*v);
    if (const auto *v = get("wrap_mode")) {
      std::string w = lower(*v);
      pass.wrap = w == "repeat" ? WrapMode::kRepeat
                  : w == "mirrored_repeat" ? WrapMode::kMirroredRepeat
                                           : WrapMode::kClampToEdge;
    }
    if (const auto *v = get("frame_count_mod"); v && parse_float(*v, &f) && f > 0)
      pass.frame_count_mod = unsigned(f);
    parse_parameters(pass.source, &out->parameters);
    out->passes.push_back(std::move(pass));
  }
  // Preset values for parameters: `parameters = "a;b"` then `a = 0.5`.
  if (props.count("parameters")) {
    std::istringstream ids(props["parameters"]);
    std::string id;
    while (std::getline(ids, id, ';')) {
      id = trim(id);
      float v;
      if (id.empty() || !props.count(id) || !parse_float(props[id], &v)) continue;
      for (auto &p : out->parameters)
        if (p.id == id) p.value = v;
    }
  }
  return true;
}

unsigned native_scale(unsigned w, unsigned h, unsigned native_w, unsigned native_h) {
  if (!native_w || !native_h) return 1;
  unsigned k = std::min(w / native_w, h / native_h);
  return k < 1 ? 1 : k > 8 ? 8 : k;
}

}  // namespace dena
