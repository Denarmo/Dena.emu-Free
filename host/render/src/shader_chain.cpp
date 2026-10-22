// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shaders.md
#include "dena/shader_chain.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <utility>

namespace dena {
namespace {

// Attribute slots bound before linking.
constexpr GLuint kVertexCoord = 0, kTexCoord = 1, kColor = 2;
// Texture units: the pass input, the original picture, then the rest.
constexpr GLint kUnitSource = 0, kUnitOriginal = 1, kUnitFirstExtra = 2, kMaxUnits = 16;
constexpr double kSweepSeconds = 8.0;  // SweepPhase period (CRT bloom)

// Used when a source has no vertex half. Matches the fragment's GLSL version.
const char *kStockVertex100 = R"(attribute vec4 VertexCoord;
attribute vec4 TexCoord;
attribute vec4 COLOR;
uniform mat4 MVPMatrix;
varying vec4 TEX0;
varying vec4 COL0;
varying vec2 vTexCoord;
void main() {
  gl_Position = MVPMatrix * VertexCoord;
  TEX0 = TexCoord;
  COL0 = COLOR;
  vTexCoord = TexCoord.xy;
}
)";
const char *kStockVertex300 = R"(#version 300 es
in vec4 VertexCoord;
in vec4 TexCoord;
in vec4 COLOR;
uniform mat4 MVPMatrix;
out vec4 TEX0;
out vec4 COL0;
out vec2 vTexCoord;
void main() {
  gl_Position = MVPMatrix * VertexCoord;
  TEX0 = TexCoord;
  COL0 = COLOR;
  vTexCoord = TexCoord.xy;
}
)";

GLuint compile_shader(GLenum type, const std::string &src, std::string *err) {
  GLuint s = glCreateShader(type);
  const char *p = src.c_str();
  glShaderSource(s, 1, &p, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024] = {0};
    glGetShaderInfoLog(s, sizeof log, nullptr, log);
    *err = std::string(type == GL_VERTEX_SHADER ? "vertex" : "fragment") + " shader: " + log;
    glDeleteShader(s);
    return 0;
  }
  return s;
}

unsigned scaled(ScaleType type, float scale, unsigned input, unsigned viewport) {
  float v = type == ScaleType::kAbsolute   ? scale
            : type == ScaleType::kViewport ? float(viewport) * scale
                                           : float(input) * scale;
  return unsigned(std::max(1.0f, std::round(v)));
}

}  // namespace

GLuint ShaderChain::compile_program(const std::string &vs_src, const std::string &fs_src,
                                    std::string *err) {
  GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src, err);
  if (!vs) return 0;
  GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src, err);
  if (!fs) {
    glDeleteShader(vs);
    return 0;
  }
  GLuint prog = glCreateProgram();
  glAttachShader(prog, vs);
  glAttachShader(prog, fs);
  glBindAttribLocation(prog, kVertexCoord, "VertexCoord");
  glBindAttribLocation(prog, kTexCoord, "TexCoord");
  glBindAttribLocation(prog, kColor, "COLOR");
  glLinkProgram(prog);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(prog, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[1024] = {0};
    glGetProgramInfoLog(prog, sizeof log, nullptr, log);
    *err = std::string("link: ") + log;
    glDeleteProgram(prog);
    return 0;
  }
  return prog;
}

void ShaderChain::lookup_uniforms(Pass &p, size_t index) {
  std::map<std::string, Uni> active;
  GLint n = 0;
  glGetProgramiv(p.program, GL_ACTIVE_UNIFORMS, &n);
  for (GLint i = 0; i < n; i++) {
    char name[128];
    GLint size = 0;
    GLenum type = 0;
    glGetActiveUniform(p.program, GLuint(i), sizeof name, nullptr, &size, &type, name);
    Uni u;
    u.loc = glGetUniformLocation(p.program, name);
    u.type = type;
    active[name] = u;
  }
  auto get = [&](const std::string &name) {
    auto it = active.find(name);
    return it == active.end() ? Uni{} : it->second;
  };
  Uniforms &u = p.u;
  u.texture = get("Texture");
  u.source = get("Source");
  u.texture_size = get("TextureSize");
  u.input_size = get("InputSize");
  u.output_size = get("OutputSize");
  u.orig = get("OrigTexture");
  u.original = get("Original");
  u.orig_texture_size = get("OrigTextureSize");
  u.orig_input_size = get("OrigInputSize");
  u.frame_count = get("FrameCount");
  u.frame_direction = get("FrameDirection");
  u.mvp = get("MVPMatrix");
  u.sweep = get("SweepPhase");
  for (const auto &param : params_) u.params.push_back(get(param.id));
  for (size_t k = 1; k <= index + 1; k++) {
    u.prev_tex.push_back(get("PassPrev" + std::to_string(k) + "Texture"));
    u.prev_size.push_back(get("PassPrev" + std::to_string(k) + "TextureSize"));
  }
  for (size_t j = 0; j < index; j++) {
    const std::string &a = passes_[j].cfg.alias;
    u.alias_tex.push_back(a.empty() ? Uni{} : get(a));
    u.alias_size.push_back(a.empty() ? Uni{} : get(a + "Size"));
  }
}

bool ShaderChain::load(const ShaderPreset &preset, std::string *err) {
  unload();
  if (preset.passes.empty()) {
    *err = "preset has no passes";
    return false;
  }
  params_ = preset.parameters;
  for (size_t i = 0; i < preset.passes.size(); i++) {
    Pass p;
    p.cfg = preset.passes[i];
    std::string fs = prepare_stage(p.cfg.source, "FRAGMENT");
    std::string vs = prepare_stage(p.cfg.source, "VERTEX");
    if (vs.empty())
      vs = fs.find("#version 300 es") != std::string::npos ? kStockVertex300 : kStockVertex100;
    std::string e;
    p.program = fs.empty() ? 0 : compile_program(vs, fs, &e);
    if (!p.program) {
      *err = p.cfg.path + ": " + (fs.empty() ? "no fragment shader" : e);
      unload();
      return false;
    }
    passes_.push_back(std::move(p));
    lookup_uniforms(passes_.back(), i);
  }

  // One quad: VertexCoord (x, y, 0, 1) and TexCoord (x, y, 0, 0) over [0, 1].
  const GLfloat quad[] = {0, 0, 0, 1, 0, 0, 0, 0,  //
                          1, 0, 0, 1, 1, 0, 0, 0,  //
                          0, 1, 0, 1, 0, 1, 0, 0,  //
                          1, 1, 0, 1, 1, 1, 0, 0};
  glGenVertexArrays(1, &vao_);
  glGenBuffers(1, &vbo_);
  glBindVertexArray(vao_);
  glBindBuffer(GL_ARRAY_BUFFER, vbo_);
  glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
  glEnableVertexAttribArray(kVertexCoord);
  glVertexAttribPointer(kVertexCoord, 4, GL_FLOAT, GL_FALSE, 8 * sizeof(GLfloat), nullptr);
  glEnableVertexAttribArray(kTexCoord);
  glVertexAttribPointer(kTexCoord, 4, GL_FLOAT, GL_FALSE, 8 * sizeof(GLfloat),
                        reinterpret_cast<const void *>(4 * sizeof(GLfloat)));
  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  frame_count_ = 0;
  return true;
}

void ShaderChain::unload() {
  for (auto &p : passes_) {
    if (p.program) glDeleteProgram(p.program);
    if (p.fbo) glDeleteFramebuffers(1, &p.fbo);
    if (p.tex) glDeleteTextures(1, &p.tex);
  }
  passes_.clear();
  params_.clear();
  if (vbo_) glDeleteBuffers(1, &vbo_);
  if (vao_) glDeleteVertexArrays(1, &vao_);
  for (auto &row : samplers_)
    for (auto &s : row)
      if (s) glDeleteSamplers(1, &s), s = 0;
  vbo_ = vao_ = 0;
  src_w_ = src_h_ = vp_w_ = vp_h_ = 0;
}

void ShaderChain::swap(ShaderChain &o) noexcept {
  std::swap(passes_, o.passes_);
  std::swap(params_, o.params_);
  std::swap(vbo_, o.vbo_);
  std::swap(vao_, o.vao_);
  std::swap(samplers_, o.samplers_);
  std::swap(src_w_, o.src_w_);
  std::swap(src_h_, o.src_h_);
  std::swap(vp_w_, o.vp_w_);
  std::swap(vp_h_, o.vp_h_);
  std::swap(frame_count_, o.frame_count_);
  std::swap(direction_, o.direction_);
  std::swap(time_, o.time_);
}

bool ShaderChain::set_parameter(const std::string &id, float value) {
  for (auto &p : params_)
    if (p.id == id) {
      p.value = std::clamp(value, std::min(p.min, p.max), std::max(p.min, p.max));
      return true;
    }
  return false;
}

GLuint ShaderChain::sampler(bool linear, WrapMode wrap) {
  GLuint &s = samplers_[linear][int(wrap)];
  if (s) return s;
  glGenSamplers(1, &s);
  GLint filter = linear ? GL_LINEAR : GL_NEAREST;
  GLint w = wrap == WrapMode::kRepeat           ? GL_REPEAT
            : wrap == WrapMode::kMirroredRepeat ? GL_MIRRORED_REPEAT
                                                : GL_CLAMP_TO_EDGE;
  glSamplerParameteri(s, GL_TEXTURE_MIN_FILTER, filter);
  glSamplerParameteri(s, GL_TEXTURE_MAG_FILTER, filter);
  glSamplerParameteri(s, GL_TEXTURE_WRAP_S, w);
  glSamplerParameteri(s, GL_TEXTURE_WRAP_T, w);
  return s;
}

bool ShaderChain::ensure_targets(unsigned w, unsigned h, unsigned vp_w, unsigned vp_h) {
  if (w == src_w_ && h == src_h_ && vp_w == vp_w_ && vp_h == vp_h_) return true;
  unsigned in_w = w, in_h = h;
  for (size_t i = 0; i < passes_.size(); i++) {
    Pass &p = passes_[i];
    bool last = i + 1 == passes_.size();
    if (last) {
      p.out_w = vp_w;
      p.out_h = vp_h;
      break;
    }
    // Without a scale, middle passes keep their input size (source x 1).
    p.out_w = p.cfg.scale_set ? scaled(p.cfg.scale_type_x, p.cfg.scale_x, in_w, vp_w) : in_w;
    p.out_h = p.cfg.scale_set ? scaled(p.cfg.scale_type_y, p.cfg.scale_y, in_h, vp_h) : in_h;
    if (p.fbo) glDeleteFramebuffers(1, &p.fbo);
    if (p.tex) glDeleteTextures(1, &p.tex);
    GLenum formats[2] = {p.cfg.float_framebuffer   ? GLenum(GL_RGBA16F)
                         : p.cfg.srgb_framebuffer ? GLenum(GL_SRGB8_ALPHA8)
                                                  : GLenum(GL_RGBA8),
                         GL_RGBA8};
    bool complete = false;
    for (GLenum fmt : formats) {
      glGenTextures(1, &p.tex);
      glBindTexture(GL_TEXTURE_2D, p.tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, fmt, GLsizei(p.out_w), GLsizei(p.out_h));
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glGenFramebuffers(1, &p.fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, p.fbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, p.tex, 0);
      complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
      p.format = fmt;
      if (complete) break;
      // Float targets need EXT_color_buffer_float; fall back to RGBA8.
      glDeleteFramebuffers(1, &p.fbo);
      glDeleteTextures(1, &p.tex);
      p.fbo = p.tex = 0;
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (!complete) return false;
    in_w = p.out_w;
    in_h = p.out_h;
  }
  src_w_ = w;
  src_h_ = h;
  vp_w_ = vp_w;
  vp_h_ = vp_h;
  return true;
}

namespace {

void set_size(GLint loc, GLenum type, float x, float y) {
  if (loc < 0) return;
  if (type == GL_FLOAT_VEC4) glUniform4f(loc, x, y, 1.0f / x, 1.0f / y);
  else if (type == GL_FLOAT_VEC2) glUniform2f(loc, x, y);
}

void set_number(GLint loc, GLenum type, double v) {
  if (loc < 0) return;
  if (type == GL_INT) glUniform1i(loc, GLint(v));
  else if (type == GL_UNSIGNED_INT) glUniform1ui(loc, GLuint(v));
  else if (type == GL_FLOAT) glUniform1f(loc, GLfloat(v));
}

void set_unit(GLint loc, GLenum type, GLint unit) {
  if (loc >= 0 && type == GL_SAMPLER_2D) glUniform1i(loc, unit);
}

}  // namespace

void ShaderChain::render(GLuint source, unsigned w, unsigned h, GLuint target_fbo, int x, int y,
                         unsigned vp_w, unsigned vp_h, bool flip_y) {
  if (passes_.empty() || !w || !h || !vp_w || !vp_h) return;
  // Texture coordinates are normalized, so only the sizes change.
  unsigned k = native_scale(w, h, native_w_, native_h_);
  w /= k;
  h /= k;
  if (!ensure_targets(w, h, vp_w, vp_h)) return;
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_CULL_FACE);
  glBindVertexArray(vao_);
  glVertexAttrib4f(kColor, 1, 1, 1, 1);
  // VertexCoord [0, 1] to clip space; t = 0 (the picture's top) at row 0 of
  // a framebuffer, or at the top of a window when flipped.
  const GLfloat mvp_fbo[16] = {2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, -1, -1, 0, 1};
  const GLfloat mvp_flip[16] = {2, 0, 0, 0, 0, -2, 0, 0, 0, 0, 1, 0, -1, 1, 0, 1};
  double sweep = std::fmod(time_, kSweepSeconds) / kSweepSeconds;
  int units_used = kUnitFirstExtra;

  unsigned in_w = w, in_h = h;
  GLuint input = source;
  for (size_t i = 0; i < passes_.size(); i++) {
    Pass &p = passes_[i];
    const Uniforms &u = p.u;
    bool last = i + 1 == passes_.size();
    if (last) {
      glBindFramebuffer(GL_FRAMEBUFFER, target_fbo);
      glViewport(x, y, GLsizei(vp_w), GLsizei(vp_h));
    } else {
      glBindFramebuffer(GL_FRAMEBUFFER, p.fbo);
      glViewport(0, 0, GLsizei(p.out_w), GLsizei(p.out_h));
    }
    glUseProgram(p.program);
    GLuint smp = sampler(p.cfg.filter_linear, p.cfg.wrap);

    glActiveTexture(GL_TEXTURE0 + kUnitSource);
    glBindTexture(GL_TEXTURE_2D, input);
    glBindSampler(kUnitSource, smp);
    set_unit(u.texture.loc, u.texture.type, kUnitSource);
    set_unit(u.source.loc, u.source.type, kUnitSource);
    glActiveTexture(GL_TEXTURE0 + kUnitOriginal);
    glBindTexture(GL_TEXTURE_2D, source);
    glBindSampler(kUnitOriginal, smp);
    set_unit(u.orig.loc, u.orig.type, kUnitOriginal);
    set_unit(u.original.loc, u.original.type, kUnitOriginal);

    GLint unit = kUnitFirstExtra;
    auto bind_extra = [&](const Uni &tex, const Uni &size, GLuint t, unsigned tw, unsigned th) {
      if (tex.loc >= 0 && unit < kMaxUnits) {
        glActiveTexture(GL_TEXTURE0 + unit);
        glBindTexture(GL_TEXTURE_2D, t);
        glBindSampler(GLuint(unit), smp);
        set_unit(tex.loc, tex.type, unit);
        unit++;
      }
      set_size(size.loc, size.type, float(tw), float(th));
    };
    // PassPrevK: K = 1 is this pass's input; K = i + 1 is the original.
    for (size_t k = 1; k <= i + 1; k++) {
      size_t from = i - k;  // wraps for the original
      bool orig = k == i + 1;
      bind_extra(u.prev_tex[k - 1], u.prev_size[k - 1], orig ? source : passes_[from].tex,
                 orig ? w : passes_[from].out_w, orig ? h : passes_[from].out_h);
    }
    for (size_t j = 0; j < i; j++)
      bind_extra(u.alias_tex[j], u.alias_size[j], passes_[j].tex, passes_[j].out_w,
                 passes_[j].out_h);
    units_used = std::max(units_used, int(unit));

    set_size(u.texture_size.loc, u.texture_size.type, float(in_w), float(in_h));
    set_size(u.input_size.loc, u.input_size.type, float(in_w), float(in_h));
    set_size(u.output_size.loc, u.output_size.type, float(p.out_w), float(p.out_h));
    set_size(u.orig_texture_size.loc, u.orig_texture_size.type, float(w), float(h));
    set_size(u.orig_input_size.loc, u.orig_input_size.type, float(w), float(h));
    unsigned fc = p.cfg.frame_count_mod ? frame_count_ % p.cfg.frame_count_mod : frame_count_;
    set_number(u.frame_count.loc, u.frame_count.type, fc);
    set_number(u.frame_direction.loc, u.frame_direction.type, direction_);
    set_number(u.sweep.loc, u.sweep.type, sweep);
    if (u.mvp.loc >= 0)
      glUniformMatrix4fv(u.mvp.loc, 1, GL_FALSE, last && flip_y ? mvp_flip : mvp_fbo);
    for (size_t k = 0; k < params_.size(); k++)
      set_number(u.params[k].loc, u.params[k].type, params_[k].value);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    input = p.tex;
    in_w = p.out_w;
    in_h = p.out_h;
  }
  frame_count_++;

  for (int i = 0; i < units_used; i++) {
    glActiveTexture(GL_TEXTURE0 + i);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindSampler(GLuint(i), 0);
  }
  glActiveTexture(GL_TEXTURE0);
  glUseProgram(0);
  glBindVertexArray(0);
}

}  // namespace dena
