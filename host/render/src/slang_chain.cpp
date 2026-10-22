// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shader-stacks.md
#include "dena/slang_chain.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#define STBI_ONLY_PNG
#define STBI_NO_STDIO_WARNINGS
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wsign-compare"
#endif
#include "stb_image.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

namespace dena {
namespace slang {
namespace {

constexpr unsigned kMaxNativeScale = 8;

// Every texture the chain renders into or samples.
struct Target {
  GLuint tex = 0, fbo = 0;
  unsigned w = 0, h = 0, levels = 0;
  GLenum format = 0;
};

enum class Kind {
  kNone, kOriginal, kHistory, kPassOutput, kPassFeedback, kLut, kOutput, kFinalViewport,
  kMvp, kFrameCount, kFrameDirection, kRotation, kFrameTimeDelta, kOriginalFps,
  kOriginalAspect, kTotalSubFrames, kCurrentSubFrame, kParam,
};

struct Ref {
  Kind kind = Kind::kNone;
  int index = 0;
};

struct Member {
  Ref ref;
  bool size = false;  // a *Size vec4 rather than the texture's own semantic
  GLint offset = 0;
  GLenum type = 0;
  GLint matrix_stride = 16;
};

struct Block {
  GLuint buffer = 0, binding = 0;
  std::vector<Member> members;
  std::vector<uint8_t> data;
};

struct SamplerBinding {
  Ref ref;
  GLuint unit = 0;
};

struct PassGl {
  GLuint program = 0;
  std::vector<Block> blocks;
  std::vector<SamplerBinding> samplers;
  Target target[2];  // [cur] this frame; [cur ^ 1] last frame's (feedback)
  int cur = 0;
  bool feedback = false;
  // How later passes sample this pass's output: the settings of the pass
  // after it (that one's input), or its own for the last pass.
  bool read_linear = false, read_mipmap = false;
  Wrap read_wrap = Wrap::kClampToBorder;
  unsigned w = 0, h = 0;  // size this frame
};

struct Lut {
  GLuint tex = 0;
  unsigned w = 0, h = 0;
  bool linear = false, mipmap = false;
  Wrap wrap = Wrap::kClampToBorder;
};

bool parse_index(const std::string &s, const char *prefix, int *k) {
  size_t n = std::strlen(prefix);
  if (s.size() <= n || s.compare(0, n, prefix) != 0) return false;
  int v = 0;
  for (size_t i = n; i < s.size(); i++) {
    if (s[i] < '0' || s[i] > '9' || v > 1000) return false;
    v = v * 10 + (s[i] - '0');
  }
  *k = v;
  return true;
}

bool ends_with(const std::string &s, const char *suffix) {
  size_t n = std::strlen(suffix);
  return s.size() > n && s.compare(s.size() - n, n, suffix) == 0;
}

unsigned native_scale(unsigned w, unsigned h, unsigned nw, unsigned nh) {
  if (!nw || !nh) return 1;
  unsigned k = 1;
  while (k < kMaxNativeScale && w >= (k + 1) * nw && h >= (k + 1) * nh) k++;
  return (w >= k * nw && h >= k * nh) ? k : 1;
}

GLenum internal_format(const Pass &p) {
  if (p.float_framebuffer) return GL_RGBA16F;
  if (p.srgb_framebuffer) return GL_SRGB8_ALPHA8;
  switch (p.format) {
    case Format::kDefault: return GL_RGBA8;
    case Format::kR8G8B8A8Unorm: return GL_RGBA8;
    case Format::kR8G8B8A8Srgb: return GL_SRGB8_ALPHA8;
    case Format::kA2B10G10R10UnormPack32: return GL_RGB10_A2;
    case Format::kR16G16B16A16Sfloat: return GL_RGBA16F;
    case Format::kR32G32B32A32Sfloat: return GL_RGBA32F;
    case Format::kR16Sfloat: return GL_R16F;
    case Format::kR16G16Sfloat: return GL_RG16F;
    case Format::kR32Sfloat: return GL_R32F;
    case Format::kR32G32Sfloat: return GL_RG32F;
    case Format::kR8Unorm: return GL_R8;
    case Format::kR8G8Unorm: return GL_RG8;
    case Format::kR16Unorm: return GL_R16;
    case Format::kR16G16Unorm: return GL_RG16;
    case Format::kR16G16B16A16Unorm: return GL_RGBA16;
    case Format::kR32Uint: return GL_R32UI;
    case Format::kR32Sint: return GL_R32I;
    case Format::kR16Uint: return GL_R16UI;
    case Format::kR16Sint: return GL_R16I;
    case Format::kR8Uint: return GL_R8UI;
    case Format::kR8Sint: return GL_R8I;
  }
  return GL_RGBA8;
}

unsigned mip_levels(unsigned w, unsigned h) {
  unsigned n = 1, m = std::max(w, h);
  while (m > 1) {
    m >>= 1;
    n++;
  }
  return n;
}

GLint gl_wrap(Wrap w) {
  switch (w) {
    case Wrap::kClampToEdge: return GL_CLAMP_TO_EDGE;
    case Wrap::kRepeat: return GL_REPEAT;
    case Wrap::kMirroredRepeat: return GL_MIRRORED_REPEAT;
    case Wrap::kClampToBorder: break;
  }
  return GL_CLAMP_TO_BORDER;
}

void release_target(const Gl &gl, Target *t) {
  if (t->fbo) gl.DeleteFramebuffers(1, &t->fbo);
  if (t->tex) gl.DeleteTextures(1, &t->tex);
  *t = Target{};
}

// (Re)allocates t as w x h, cleared to transparent black. Leaves the draw
// framebuffer bound to it.
bool alloc_target(const Gl &gl, Target *t, unsigned w, unsigned h, GLenum format, unsigned levels) {
  if (t->tex && t->w == w && t->h == h && t->format == format && t->levels == levels) return true;
  release_target(gl, t);
  gl.GenTextures(1, &t->tex);
  gl.BindTexture(GL_TEXTURE_2D, t->tex);
  gl.TexStorage2D(GL_TEXTURE_2D, GLsizei(levels), format, GLsizei(w), GLsizei(h));
  gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, GLint(levels - 1));
  gl.GenFramebuffers(1, &t->fbo);
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, t->fbo);
  gl.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->tex, 0);
  if (gl.CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    release_target(gl, t);
    return false;
  }
  t->w = w;
  t->h = h;
  t->format = format;
  t->levels = levels;
  gl.Disable(GL_SCISSOR_TEST);
  gl.ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  gl.ClearColor(0, 0, 0, 0);
  gl.Clear(GL_COLOR_BUFFER_BIT);
  return true;
}

// The GL state the chain changes, saved and put back around every call, as
// GPU cores share the context.
class SavedState {
 public:
  SavedState(const Gl &gl, GLuint units, GLuint ubo_bindings) : gl_(gl) {
    gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo_);
    gl.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo_);
    gl.GetIntegerv(GL_CURRENT_PROGRAM, &program_);
    gl.GetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao_);
    gl.GetIntegerv(GL_ARRAY_BUFFER_BINDING, &array_buffer_);
    gl.GetIntegerv(GL_UNIFORM_BUFFER_BINDING, &uniform_buffer_);
    gl.GetIntegerv(GL_ACTIVE_TEXTURE, &active_);
    gl.GetIntegerv(GL_VIEWPORT, viewport_);
    gl.GetBooleanv(GL_COLOR_WRITEMASK, mask_);
    gl.GetIntegerv(GL_UNPACK_ALIGNMENT, &unpack_align_);
    gl.GetIntegerv(GL_UNPACK_ROW_LENGTH, &unpack_row_);
    gl.GetIntegerv(GL_PACK_ALIGNMENT, &pack_align_);
    gl.GetIntegerv(GL_PACK_ROW_LENGTH, &pack_row_);
    gl.GetFloatv(GL_COLOR_CLEAR_VALUE, clear_);
    for (size_t i = 0; i < kEnables; i++) enabled_[i] = gl.IsEnabled(kEnable[i]);
    units_.resize(units);
    for (GLuint u = 0; u < units; u++) {
      gl.ActiveTexture(GL_TEXTURE0 + u);
      gl.GetIntegerv(GL_TEXTURE_BINDING_2D, &units_[u].tex);
      gl.GetIntegerv(GL_SAMPLER_BINDING, &units_[u].sampler);
    }
    ubos_.resize(ubo_bindings);
    for (GLuint b = 0; b < ubo_bindings; b++) {
      gl.GetIntegeri_v(GL_UNIFORM_BUFFER_BINDING, b, &ubos_[b].buffer);
      gl.GetIntegeri_v(GL_UNIFORM_BUFFER_START, b, &ubos_[b].start);
      gl.GetIntegeri_v(GL_UNIFORM_BUFFER_SIZE, b, &ubos_[b].size);
    }
  }
  ~SavedState() {
    const Gl &gl = gl_;
    for (GLuint b = 0; b < ubos_.size(); b++) {
      const Ubo &u = ubos_[b];
      if (u.buffer && u.size > 0)
        gl.BindBufferRange(GL_UNIFORM_BUFFER, b, GLuint(u.buffer), u.start, u.size);
      else
        gl.BindBufferBase(GL_UNIFORM_BUFFER, b, GLuint(u.buffer));
    }
    for (GLuint u = 0; u < units_.size(); u++) {
      gl.ActiveTexture(GL_TEXTURE0 + u);
      gl.BindTexture(GL_TEXTURE_2D, GLuint(units_[u].tex));
      gl.BindSampler(u, GLuint(units_[u].sampler));
    }
    for (size_t i = 0; i < kEnables; i++) {
      if (enabled_[i]) gl.Enable(kEnable[i]);
      else gl.Disable(kEnable[i]);
    }
    gl.ActiveTexture(GLenum(active_));
    gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(draw_fbo_));
    gl.BindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(read_fbo_));
    gl.UseProgram(GLuint(program_));
    gl.BindVertexArray(GLuint(vao_));
    gl.BindBuffer(GL_ARRAY_BUFFER, GLuint(array_buffer_));
    gl.BindBuffer(GL_UNIFORM_BUFFER, GLuint(uniform_buffer_));
    gl.Viewport(viewport_[0], viewport_[1], viewport_[2], viewport_[3]);
    gl.ColorMask(mask_[0], mask_[1], mask_[2], mask_[3]);
    gl.ClearColor(clear_[0], clear_[1], clear_[2], clear_[3]);
    gl.PixelStorei(GL_UNPACK_ALIGNMENT, unpack_align_);
    gl.PixelStorei(GL_UNPACK_ROW_LENGTH, unpack_row_);
    gl.PixelStorei(GL_PACK_ALIGNMENT, pack_align_);
    gl.PixelStorei(GL_PACK_ROW_LENGTH, pack_row_);
  }

 private:
  static constexpr size_t kEnables = 7;
  static constexpr GLenum kEnable[kEnables] = {GL_DEPTH_TEST, GL_STENCIL_TEST, GL_BLEND,
                                               GL_SCISSOR_TEST, GL_CULL_FACE,
                                               GL_FRAMEBUFFER_SRGB, GL_RASTERIZER_DISCARD};
  struct Unit {
    GLint tex = 0, sampler = 0;
  };
  struct Ubo {
    GLint buffer = 0, start = 0, size = 0;
  };
  const Gl &gl_;
  GLint draw_fbo_ = 0, read_fbo_ = 0, program_ = 0, vao_ = 0, array_buffer_ = 0;
  GLint uniform_buffer_ = 0, active_ = GL_TEXTURE0, viewport_[4] = {};
  GLint unpack_align_ = 4, unpack_row_ = 0, pack_align_ = 4, pack_row_ = 0;
  GLfloat clear_[4] = {};
  GLboolean mask_[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
  GLboolean enabled_[kEnables] = {};
  std::vector<Unit> units_;
  std::vector<Ubo> ubos_;
};
constexpr GLenum SavedState::kEnable[];

GLuint compile(const Gl &gl, GLenum type, const std::string &src, std::string *log) {
  GLuint s = gl.CreateShader(type);
  const char *text = src.c_str();
  gl.ShaderSource(s, 1, &text, nullptr);
  gl.CompileShader(s);
  GLint ok = 0;
  gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char buf[2048] = {};
    gl.GetShaderInfoLog(s, sizeof buf - 1, nullptr, buf);
    *log = std::string(type == GL_VERTEX_SHADER ? "vertex: " : "fragment: ") + buf;
    gl.DeleteShader(s);
    return 0;
  }
  return s;
}

std::string base_name(const std::string &path) {
  size_t slash = path.find_last_of("/\\");
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

}  // namespace

struct SlangChain::Pipeline {
  Preset preset;
  std::vector<PassGl> passes;
  std::vector<Lut> luts;
  std::vector<Target> history;  // ring of past source frames
  size_t history_head = 0;      // slot of OriginalHistory1
  GLuint copy_fbo = 0;
  GLuint units = 0, ubo_bindings = 0;
  bool original_mipmap = false;
  Target *out = nullptr;
};

namespace {

// Texture semantics by name, for pass i (shader-stacks.md, Renderer).
Ref resolve_texture(const std::string &n, size_t i, const Preset &p) {
  int k = 0;
  if (n == "Original") return {Kind::kOriginal, 0};
  if (n == "Source") return i == 0 ? Ref{Kind::kOriginal, 0} : Ref{Kind::kPassOutput, int(i) - 1};
  if (parse_index(n, "OriginalHistory", &k))
    return k == 0 ? Ref{Kind::kOriginal, 0} : Ref{Kind::kHistory, k};
  if (parse_index(n, "PassOutput", &k))
    return size_t(k) < i ? Ref{Kind::kPassOutput, k} : Ref{};
  if (parse_index(n, "PassFeedback", &k))
    return size_t(k) < p.passes.size() ? Ref{Kind::kPassFeedback, k} : Ref{};
  for (size_t j = 0; j < p.passes.size(); j++) {
    const std::string &a = p.passes[j].alias;
    if (a.empty()) continue;
    if (n == a) return j < i ? Ref{Kind::kPassOutput, int(j)} : Ref{};
    if (n == a + "Feedback") return Ref{Kind::kPassFeedback, int(j)};
  }
  for (size_t j = 0; j < p.textures.size(); j++)
    if (n == p.textures[j].name) return {Kind::kLut, int(j)};
  return {};
}

// A uniform block member by name: a semantic, a *Size, or a parameter.
Member resolve_member(const std::string &n, size_t i, const Preset &p) {
  Member m;
  static const struct {
    const char *name;
    Kind kind;
  } kScalars[] = {
      {"MVP", Kind::kMvp},
      {"FrameCount", Kind::kFrameCount},
      {"FrameDirection", Kind::kFrameDirection},
      {"Rotation", Kind::kRotation},
      {"FrameTimeDelta", Kind::kFrameTimeDelta},
      {"OriginalFPS", Kind::kOriginalFps},
      {"OriginalAspect", Kind::kOriginalAspect},
      {"OriginalAspectRotated", Kind::kOriginalAspect},
      {"TotalSubFrames", Kind::kTotalSubFrames},
      {"CurrentSubFrame", Kind::kCurrentSubFrame},
  };
  for (const auto &s : kScalars)
    if (n == s.name) {
      m.ref.kind = s.kind;
      return m;
    }
  if (ends_with(n, "Size")) {
    std::string base = n.substr(0, n.size() - 4);
    m.size = true;
    if (base == "Output") m.ref.kind = Kind::kOutput;
    else if (base == "FinalViewport") m.ref.kind = Kind::kFinalViewport;
    else m.ref = resolve_texture(base, i, p);
    if (m.ref.kind != Kind::kNone) return m;
    m.size = false;
  }
  for (size_t j = 0; j < p.parameters.size(); j++)
    if (n == p.parameters[j].id) {
      m.ref = {Kind::kParam, int(j)};
      return m;
    }
  return m;
}

}  // namespace

SlangChain::SlangChain() = default;
SlangChain::~SlangChain() = default;

bool SlangChain::init(ProcAddress proc, std::string *err) {
  if (ready_) return true;
  const char *missing = nullptr;
  if (!gl_.load(proc, &missing)) {
    *err = std::string("Shader stacks need OpenGL 4.2 (") + (missing ? missing : "?") + " missing)";
    return false;
  }
  GLint major = 0, minor = 0;
  gl_.GetIntegerv(GL_MAJOR_VERSION, &major);
  gl_.GetIntegerv(GL_MINOR_VERSION, &minor);
  const int v = major * 10 + minor;
  if (v < 42) {
    *err = "Shader stacks need OpenGL 4.2";
    return false;
  }
  glsl_version_ = v >= 46 ? 460 : v >= 45 ? 450 : v >= 44 ? 440 : v >= 43 ? 430 : 420;

  SavedState saved(gl_, 1, 0);
  // Position (0..1, Vulkan-style MVP) and TexCoord, as a triangle strip.
  const GLfloat quad[] = {0, 0, 0, 1, 0, 0,  //
                          1, 0, 0, 1, 1, 0,  //
                          0, 1, 0, 1, 0, 1,  //
                          1, 1, 0, 1, 1, 1};
  gl_.GenVertexArrays(1, &vao_);
  gl_.GenBuffers(1, &vbo_);
  gl_.BindVertexArray(vao_);
  gl_.BindBuffer(GL_ARRAY_BUFFER, vbo_);
  gl_.BufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
  gl_.VertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat), nullptr);
  gl_.VertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                          reinterpret_cast<const void *>(4 * sizeof(GLfloat)));
  gl_.EnableVertexAttribArray(0);
  gl_.EnableVertexAttribArray(1);
  const uint32_t zero = 0;
  gl_.ActiveTexture(GL_TEXTURE0);
  gl_.GenTextures(1, &black_);
  gl_.BindTexture(GL_TEXTURE_2D, black_);
  gl_.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 1, 1);
  gl_.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
  gl_.PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  gl_.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &zero);
  ready_ = gl_.GetError() == GL_NO_ERROR;
  if (!ready_) *err = "Shader stacks: GL setup failed";
  return ready_;
}

GLuint SlangChain::sampler(bool linear, bool mipmap, Wrap wrap) {
  GLuint &s = samplers_[linear][mipmap][int(wrap)];
  if (s) return s;
  gl_.GenSamplers(1, &s);
  GLint min = linear ? (mipmap ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR)
                     : (mipmap ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
  gl_.SamplerParameteri(s, GL_TEXTURE_MIN_FILTER, min);
  gl_.SamplerParameteri(s, GL_TEXTURE_MAG_FILTER, linear ? GL_LINEAR : GL_NEAREST);
  gl_.SamplerParameteri(s, GL_TEXTURE_WRAP_S, gl_wrap(wrap));
  gl_.SamplerParameteri(s, GL_TEXTURE_WRAP_T, gl_wrap(wrap));
  const GLfloat border[4] = {0, 0, 0, 0};
  gl_.SamplerParameterfv(s, GL_TEXTURE_BORDER_COLOR, border);
  return s;
}

namespace {

void release_pipeline(const Gl &gl, SlangChain::Pipeline *p) {
  for (auto &pass : p->passes) {
    if (pass.program) gl.DeleteProgram(pass.program);
    for (auto &b : pass.blocks)
      if (b.buffer) gl.DeleteBuffers(1, &b.buffer);
    release_target(gl, &pass.target[0]);
    release_target(gl, &pass.target[1]);
  }
  for (auto &l : p->luts)
    if (l.tex) gl.DeleteTextures(1, &l.tex);
  for (auto &h : p->history) release_target(gl, &h);
  if (p->copy_fbo) gl.DeleteFramebuffers(1, &p->copy_fbo);
  p->passes.clear();
  p->luts.clear();
  p->history.clear();
  p->copy_fbo = 0;
}

}  // namespace

bool SlangChain::load(const std::string &path, std::string *err) {
  if (!ready_) {
    *err = "Shader stacks need OpenGL 4.2";
    return false;
  }
  auto pipe = std::make_unique<Pipeline>();
  if (!load_preset(path, &pipe->preset, err)) return false;
  const Preset &pr = pipe->preset;
  SavedState saved(gl_, 1, 0);
  bool ok = true;
  int history = 0;

  // Lookup textures.
  for (const auto &t : pr.textures) {
    int w = 0, h = 0, n = 0;
    stbi_uc *px = stbi_load(t.path.c_str(), &w, &h, &n, 4);
    if (!px) {
      *err = "cannot read texture " + t.path;
      ok = false;
      break;
    }
    Lut l;
    l.w = unsigned(w);
    l.h = unsigned(h);
    l.linear = t.linear;
    l.mipmap = t.mipmap;
    l.wrap = t.wrap;
    const unsigned levels = t.mipmap ? mip_levels(l.w, l.h) : 1;
    gl_.ActiveTexture(GL_TEXTURE0);
    gl_.GenTextures(1, &l.tex);
    gl_.BindTexture(GL_TEXTURE_2D, l.tex);
    gl_.TexStorage2D(GL_TEXTURE_2D, GLsizei(levels), GL_RGBA8, w, h);
    gl_.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
    gl_.PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    gl_.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    if (levels > 1) gl_.GenerateMipmap(GL_TEXTURE_2D);
    stbi_image_free(px);
    pipe->luts.push_back(l);
  }

  // Programs and their uniforms.
  pipe->passes.resize(ok ? pr.passes.size() : 0);
  for (size_t i = 0; ok && i < pr.passes.size(); i++) {
    const Pass &p = pr.passes[i];
    PassGl &pg = pipe->passes[i];
    std::string log;
    GLuint vs = compile(gl_, GL_VERTEX_SHADER, to_desktop_glsl(p.vertex, glsl_version_), &log);
    GLuint fs = vs ? compile(gl_, GL_FRAGMENT_SHADER, to_desktop_glsl(p.fragment, glsl_version_), &log) : 0;
    if (!vs || !fs) {
      if (vs) gl_.DeleteShader(vs);
      *err = "pass " + std::to_string(i) + " (" + base_name(p.path) + ") " + log;
      ok = false;
      break;
    }
    pg.program = gl_.CreateProgram();
    gl_.AttachShader(pg.program, vs);
    gl_.AttachShader(pg.program, fs);
    gl_.LinkProgram(pg.program);
    gl_.DeleteShader(vs);
    gl_.DeleteShader(fs);
    GLint linked = 0;
    gl_.GetProgramiv(pg.program, GL_LINK_STATUS, &linked);
    if (!linked) {
      char buf[2048] = {};
      gl_.GetProgramInfoLog(pg.program, sizeof buf - 1, nullptr, buf);
      *err = "pass " + std::to_string(i) + " (" + base_name(p.path) + ") link: " + buf;
      ok = false;
      break;
    }
    gl_.UseProgram(pg.program);

    auto note = [&](const Ref &r) {
      if (r.kind == Kind::kHistory) history = std::max(history, r.index);
      if (r.kind == Kind::kPassFeedback) pipe->passes[size_t(r.index)].feedback = true;
    };

    GLint blocks = 0;
    gl_.GetProgramiv(pg.program, GL_ACTIVE_UNIFORM_BLOCKS, &blocks);
    for (GLint b = 0; b < blocks; b++) {
      Block blk;
      blk.binding = GLuint(b);
      char bname[256] = {};
      gl_.GetActiveUniformBlockName(pg.program, GLuint(b), sizeof bname - 1, nullptr, bname);
      GLint size = 0, count = 0;
      gl_.GetActiveUniformBlockiv(pg.program, GLuint(b), GL_UNIFORM_BLOCK_DATA_SIZE, &size);
      gl_.GetActiveUniformBlockiv(pg.program, GLuint(b), GL_UNIFORM_BLOCK_ACTIVE_UNIFORMS, &count);
      std::vector<GLint> idx(size_t(std::max(count, 0)));
      if (count > 0)
        gl_.GetActiveUniformBlockiv(pg.program, GLuint(b), GL_UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES,
                                    idx.data());
      std::vector<GLuint> uidx(idx.begin(), idx.end());
      std::vector<GLint> offs(uidx.size()), types(uidx.size()), strides(uidx.size());
      if (!uidx.empty()) {
        gl_.GetActiveUniformsiv(pg.program, GLsizei(uidx.size()), uidx.data(), GL_UNIFORM_OFFSET, offs.data());
        gl_.GetActiveUniformsiv(pg.program, GLsizei(uidx.size()), uidx.data(), GL_UNIFORM_TYPE, types.data());
        gl_.GetActiveUniformsiv(pg.program, GLsizei(uidx.size()), uidx.data(), GL_UNIFORM_MATRIX_STRIDE,
                                strides.data());
      }
      const std::string prefix = std::string(bname) + ".";
      for (size_t u = 0; u < uidx.size(); u++) {
        char name[256] = {};
        GLint asize = 0;
        GLenum type = 0;
        gl_.GetActiveUniform(pg.program, uidx[u], sizeof name - 1, nullptr, &asize, &type, name);
        std::string n = name;
        if (n.compare(0, prefix.size(), prefix) == 0) n = n.substr(prefix.size());
        if (ends_with(n, "[0]")) n = n.substr(0, n.size() - 3);
        Member m = resolve_member(n, i, pr);
        if (m.ref.kind == Kind::kNone) continue;
        note(m.ref);
        m.offset = offs[u];
        m.type = GLenum(types[u]);
        m.matrix_stride = strides[u] > 0 ? strides[u] : 16;
        blk.members.push_back(m);
      }
      blk.data.assign(size_t(std::max(size, 16)), 0);
      gl_.UniformBlockBinding(pg.program, GLuint(b), blk.binding);
      gl_.GenBuffers(1, &blk.buffer);
      gl_.BindBuffer(GL_UNIFORM_BUFFER, blk.buffer);
      gl_.BufferData(GL_UNIFORM_BUFFER, GLsizeiptr(blk.data.size()), nullptr, GL_STREAM_DRAW);
      pg.blocks.push_back(std::move(blk));
    }
    pipe->ubo_bindings = std::max(pipe->ubo_bindings, GLuint(blocks));

    GLint uniforms = 0;
    gl_.GetProgramiv(pg.program, GL_ACTIVE_UNIFORMS, &uniforms);
    GLuint unit = 0;
    for (GLint u = 0; u < uniforms; u++) {
      const GLuint ui = GLuint(u);
      GLint block = -1;
      gl_.GetActiveUniformsiv(pg.program, 1, &ui, GL_UNIFORM_BLOCK_INDEX, &block);
      if (block != -1) continue;
      char name[256] = {};
      GLint asize = 0;
      GLenum type = 0;
      gl_.GetActiveUniform(pg.program, ui, sizeof name - 1, nullptr, &asize, &type, name);
      if (type != GL_SAMPLER_2D) continue;
      GLint loc = gl_.GetUniformLocation(pg.program, name);
      if (loc < 0) continue;
      SamplerBinding sb;
      sb.ref = resolve_texture(name, i, pr);
      note(sb.ref);
      sb.unit = unit++;
      gl_.Uniform1i(loc, GLint(sb.unit));
      pg.samplers.push_back(sb);
    }
    pipe->units = std::max(pipe->units, unit);
  }

  if (ok) {
    // How each pass's output is read, and whether it needs mipmaps.
    for (size_t i = 0; i < pipe->passes.size(); i++) {
      const Pass &reader = pr.passes[std::min(i + 1, pr.passes.size() - 1)];
      PassGl &pg = pipe->passes[i];
      pg.read_linear = reader.filter_linear;
      pg.read_wrap = reader.wrap;
      pg.read_mipmap = i + 1 < pr.passes.size() && reader.mipmap_input;
    }
    pipe->original_mipmap = pr.passes[0].mipmap_input;
    pipe->history.resize(size_t(history));
    gl_.GenFramebuffers(1, &pipe->copy_fbo);
    if (gl_.GetError() != GL_NO_ERROR) {
      *err = "Shader stacks: GL error while loading " + base_name(path);
      ok = false;
    }
  }
  if (!ok) {
    release_pipeline(gl_, pipe.get());
    return false;
  }
  if (pipe_) release_pipeline(gl_, pipe_.get());
  pipe_ = std::move(pipe);
  frame_count_ = 0;
  return true;
}

void SlangChain::unload() {
  if (!pipe_) return;
  SavedState saved(gl_, 1, 0);
  release_pipeline(gl_, pipe_.get());
  pipe_.reset();
}

void SlangChain::release() {
  if (!ready_) return;
  unload();
  for (auto &a : samplers_)
    for (auto &b : a)
      for (auto &s : b)
        if (s) {
          gl_.DeleteSamplers(1, &s);
          s = 0;
        }
  if (src_fbo_) gl_.DeleteFramebuffers(1, &src_fbo_);
  if (src_tex_) gl_.DeleteTextures(1, &src_tex_);
  if (black_) gl_.DeleteTextures(1, &black_);
  if (vbo_) gl_.DeleteBuffers(1, &vbo_);
  if (vao_) gl_.DeleteVertexArrays(1, &vao_);
  src_fbo_ = src_tex_ = black_ = vbo_ = vao_ = 0;
  src_w_ = src_h_ = src_alloc_w_ = src_alloc_h_ = src_levels_ = 0;
  ready_ = false;
}

bool SlangChain::ensure_source(unsigned w, unsigned h) {
  const unsigned levels = pipe_ && pipe_->original_mipmap ? mip_levels(w, h) : 1;
  if (src_tex_ && src_alloc_w_ == w && src_alloc_h_ == h && src_levels_ == levels) return true;
  if (src_fbo_) gl_.DeleteFramebuffers(1, &src_fbo_);
  if (src_tex_) gl_.DeleteTextures(1, &src_tex_);
  src_fbo_ = src_tex_ = 0;
  gl_.ActiveTexture(GL_TEXTURE0);
  gl_.GenTextures(1, &src_tex_);
  gl_.BindTexture(GL_TEXTURE_2D, src_tex_);
  gl_.TexStorage2D(GL_TEXTURE_2D, GLsizei(levels), GL_RGBA8, GLsizei(w), GLsizei(h));
  gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, GLint(levels - 1));
  gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ONE);  // XRGB: no alpha
  gl_.GenFramebuffers(1, &src_fbo_);
  gl_.BindFramebuffer(GL_DRAW_FRAMEBUFFER, src_fbo_);
  gl_.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src_tex_, 0);
  if (gl_.CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
  src_alloc_w_ = w;
  src_alloc_h_ = h;
  src_levels_ = levels;
  return true;
}

bool SlangChain::upload(const uint32_t *xrgb, unsigned w, unsigned h) {
  if (!ready_ || !xrgb || !w || !h) return false;
  SavedState saved(gl_, 1, 0);
  if (!ensure_source(w, h)) return false;
  gl_.ActiveTexture(GL_TEXTURE0);
  gl_.BindTexture(GL_TEXTURE_2D, src_tex_);
  gl_.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
  gl_.PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  gl_.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(w), GLsizei(h), GL_BGRA, GL_UNSIGNED_BYTE, xrgb);
  if (src_levels_ > 1) gl_.GenerateMipmap(GL_TEXTURE_2D);
  src_w_ = w;
  src_h_ = h;
  return true;
}

bool SlangChain::copy_from(GLuint fbo, unsigned w, unsigned h, bool bottom_left) {
  if (!ready_ || !w || !h) return false;
  SavedState saved(gl_, 1, 0);
  if (!ensure_source(w, h)) return false;
  gl_.Disable(GL_SCISSOR_TEST);
  gl_.Disable(GL_FRAMEBUFFER_SRGB);
  gl_.BindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
  gl_.BindFramebuffer(GL_DRAW_FRAMEBUFFER, src_fbo_);
  // Row 0 of the source is the picture's top.
  const GLint y0 = bottom_left ? GLint(h) : 0, y1 = bottom_left ? 0 : GLint(h);
  gl_.BlitFramebuffer(0, 0, GLint(w), GLint(h), 0, y0, GLint(w), y1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  if (src_levels_ > 1) {
    gl_.ActiveTexture(GL_TEXTURE0);
    gl_.BindTexture(GL_TEXTURE_2D, src_tex_);
    gl_.GenerateMipmap(GL_TEXTURE_2D);
  }
  src_w_ = w;
  src_h_ = h;
  return true;
}

bool SlangChain::render(unsigned vp_w, unsigned vp_h) {
  if (!src_tex_ || !src_w_) return false;
  return draw(src_tex_, src_w_, src_h_, vp_w, vp_h);
}

bool SlangChain::render_texture(GLuint tex, unsigned w, unsigned h, unsigned vp_w, unsigned vp_h) {
  return draw(tex, w, h, vp_w, vp_h);
}

bool SlangChain::draw(GLuint tex, unsigned w, unsigned h, unsigned vp_w, unsigned vp_h) {
  if (!ready_ || !pipe_ || !tex || !w || !h || !vp_w || !vp_h) return false;
  Pipeline &pl = *pipe_;
  const Preset &pr = pl.preset;
  // A source filter may use units 0-3 (frame_gen.h).
  SavedState saved(gl_, std::max<GLuint>(pl.units, filter_ ? 4 : 1), pl.ubo_bindings);

  if (filter_) tex = filter_->filter(gl_, tex, &w, &h);
  if (!tex || !w || !h) return false;
  const bool own_source = tex == src_tex_;

  // Sizes the shaders see: native for a k-times frame (Native lines).
  const unsigned k = native_scale(w, h, native_w_, native_h_);
  const unsigned ow = w / k, oh = h / k;
  GLint max_size = 4096;
  gl_.GetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
  auto axis = [&](Scale type, float scale, unsigned source, unsigned viewport, unsigned original) {
    double v = 0;
    switch (type) {
      case Scale::kSource: v = double(source) * scale; break;
      case Scale::kViewport: v = double(viewport) * scale; break;
      case Scale::kAbsolute: v = scale; break;
      case Scale::kOriginal: v = double(original) * scale; break;
    }
    long r = std::lround(v);
    return unsigned(std::clamp<long>(r, 1, max_size));
  };
  unsigned sw = ow, sh = oh;
  for (size_t i = 0; i < pl.passes.size(); i++) {
    const Pass &p = pr.passes[i];
    PassGl &pg = pl.passes[i];
    pg.w = axis(p.scale_type_x, p.scale_x, sw, vp_w, ow);
    pg.h = axis(p.scale_type_y, p.scale_y, sh, vp_h, oh);
    const GLenum fmt = internal_format(p);
    const unsigned levels = pg.read_mipmap ? mip_levels(pg.w, pg.h) : 1;
    if (!alloc_target(gl_, &pg.target[pg.cur], pg.w, pg.h, fmt, levels)) return false;
    if (pg.feedback && !alloc_target(gl_, &pg.target[pg.cur ^ 1], pg.w, pg.h, fmt, levels)) return false;
    sw = pg.w;
    sh = pg.h;
  }
  for (auto &t : pl.history)
    if (!alloc_target(gl_, &t, w, h, GL_RGBA8, own_source ? src_levels_ : 1)) return false;

  const auto now = std::chrono::steady_clock::now();
  const double delta_us = frame_count_ == 0 ? 0.0
      : std::chrono::duration<double, std::micro>(now - last_time_).count();
  last_time_ = now;
  // Vulkan-style: Position (0..1) to clip space, no flip (row 0 = top).
  static const GLfloat kMvp[16] = {2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, -1, -1, 0, 1};

  gl_.Disable(GL_DEPTH_TEST);
  gl_.Disable(GL_STENCIL_TEST);
  gl_.Disable(GL_BLEND);
  gl_.Disable(GL_SCISSOR_TEST);
  gl_.Disable(GL_CULL_FACE);
  gl_.Disable(GL_RASTERIZER_DISCARD);
  gl_.ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  gl_.BindVertexArray(vao_);

  struct Tex {
    GLuint tex;
    GLuint smp;
    unsigned w, h;
  };
  const Pass &first = pr.passes[0];
  auto texture_of = [&](const Ref &r) -> Tex {
    switch (r.kind) {
      case Kind::kOriginal:
        return {tex, sampler(first.filter_linear, first.mipmap_input && own_source, first.wrap), ow, oh};
      case Kind::kHistory: {
        const size_t n = pl.history.size();
        const Target &t = pl.history[(pl.history_head + size_t(r.index) - 1) % n];
        return {t.tex, sampler(first.filter_linear, t.levels > 1, first.wrap), ow, oh};
      }
      case Kind::kPassOutput:
      case Kind::kPassFeedback: {
        const PassGl &p = pl.passes[size_t(r.index)];
        const Target &t = p.target[r.kind == Kind::kPassOutput ? p.cur : p.cur ^ 1];
        return {t.tex ? t.tex : black_, sampler(p.read_linear, p.read_mipmap, p.read_wrap), p.w, p.h};
      }
      case Kind::kLut: {
        const Lut &l = pl.luts[size_t(r.index)];
        return {l.tex, sampler(l.linear, l.mipmap, l.wrap), l.w, l.h};
      }
      default: break;
    }
    return {black_, sampler(false, false, Wrap::kClampToEdge), 1, 1};
  };

  for (size_t i = 0; i < pl.passes.size(); i++) {
    const Pass &p = pr.passes[i];
    PassGl &pg = pl.passes[i];
    const Target &t = pg.target[pg.cur];
    gl_.BindFramebuffer(GL_DRAW_FRAMEBUFFER, t.fbo);
    gl_.Viewport(0, 0, GLsizei(t.w), GLsizei(t.h));
    if (t.format == GL_SRGB8_ALPHA8) gl_.Enable(GL_FRAMEBUFFER_SRGB);
    else gl_.Disable(GL_FRAMEBUFFER_SRGB);
    gl_.UseProgram(pg.program);
    for (const auto &sb : pg.samplers) {
      Tex x = texture_of(sb.ref);
      gl_.ActiveTexture(GL_TEXTURE0 + sb.unit);
      gl_.BindTexture(GL_TEXTURE_2D, x.tex);
      gl_.BindSampler(sb.unit, x.smp);
    }
    const uint64_t fc = p.frame_count_mod ? frame_count_ % p.frame_count_mod : frame_count_;
    for (auto &b : pg.blocks) {
      for (const auto &m : b.members) {
        uint8_t *dst = b.data.data() + m.offset;
        if (size_t(m.offset) + 16 > b.data.size() && m.type != GL_FLOAT && m.type != GL_INT &&
            m.type != GL_UNSIGNED_INT)
          continue;
        float vec[4] = {0, 0, 0, 0};
        double scalar = 0;
        bool is_vec = false;
        if (m.size) {
          unsigned sx = 0, sy = 0;
          if (m.ref.kind == Kind::kOutput) sx = t.w, sy = t.h;
          else if (m.ref.kind == Kind::kFinalViewport) sx = vp_w, sy = vp_h;
          else {
            Tex x = texture_of(m.ref);
            sx = x.w, sy = x.h;
          }
          vec[0] = float(sx);
          vec[1] = float(sy);
          vec[2] = sx ? 1.0f / float(sx) : 0.0f;
          vec[3] = sy ? 1.0f / float(sy) : 0.0f;
          is_vec = true;
        } else {
          switch (m.ref.kind) {
            case Kind::kMvp:
              if (m.type == GL_FLOAT_MAT4 && size_t(m.offset + 3 * m.matrix_stride + 16) <= b.data.size())
                for (int c = 0; c < 4; c++) std::memcpy(dst + c * m.matrix_stride, kMvp + 4 * c, 16);
              continue;
            case Kind::kFrameCount: scalar = double(fc); break;
            case Kind::kFrameDirection: scalar = direction_; break;
            case Kind::kRotation: scalar = 0; break;
            case Kind::kFrameTimeDelta: scalar = delta_us; break;
            case Kind::kOriginalFps: scalar = fps_; break;
            case Kind::kOriginalAspect: scalar = oh ? double(ow) / double(oh) : 1.0; break;
            case Kind::kTotalSubFrames:
            case Kind::kCurrentSubFrame: scalar = 1; break;
            case Kind::kParam: scalar = pr.parameters[size_t(m.ref.index)].value; break;
            default: continue;
          }
        }
        switch (m.type) {
          case GL_FLOAT_VEC4:
            if (!is_vec) vec[0] = float(scalar);
            std::memcpy(dst, vec, 16);
            break;
          case GL_FLOAT_VEC2:
            if (!is_vec) vec[0] = float(scalar);
            std::memcpy(dst, vec, 8);
            break;
          case GL_FLOAT: {
            float f = is_vec ? vec[0] : float(scalar);
            std::memcpy(dst, &f, 4);
            break;
          }
          case GL_INT: {
            int32_t v = int32_t(is_vec ? vec[0] : scalar);
            std::memcpy(dst, &v, 4);
            break;
          }
          case GL_UNSIGNED_INT: {
            uint32_t v = uint32_t(is_vec ? vec[0] : std::max(0.0, scalar));
            std::memcpy(dst, &v, 4);
            break;
          }
          default: break;
        }
      }
      gl_.BindBuffer(GL_UNIFORM_BUFFER, b.buffer);
      gl_.BufferSubData(GL_UNIFORM_BUFFER, 0, GLsizeiptr(b.data.size()), b.data.data());
      gl_.BindBufferBase(GL_UNIFORM_BUFFER, b.binding, b.buffer);
    }
    gl_.DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    if (pg.read_mipmap) {
      gl_.ActiveTexture(GL_TEXTURE0);
      gl_.BindTexture(GL_TEXTURE_2D, t.tex);
      gl_.GenerateMipmap(GL_TEXTURE_2D);
    }
  }
  PassGl &last = pl.passes.back();
  pl.out = &last.target[last.cur];

  // This frame becomes OriginalHistory1; feedback targets swap.
  if (!pl.history.empty()) {
    const size_t n = pl.history.size();
    pl.history_head = (pl.history_head + n - 1) % n;
    Target &h = pl.history[pl.history_head];
    gl_.Disable(GL_FRAMEBUFFER_SRGB);
    gl_.BindFramebuffer(GL_READ_FRAMEBUFFER, pl.copy_fbo);
    gl_.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    gl_.BindFramebuffer(GL_DRAW_FRAMEBUFFER, h.fbo);
    gl_.BlitFramebuffer(0, 0, GLint(w), GLint(h.h), 0, 0, GLint(w), GLint(h.h), GL_COLOR_BUFFER_BIT,
                        GL_NEAREST);
    gl_.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    if (h.levels > 1) {
      gl_.ActiveTexture(GL_TEXTURE0);
      gl_.BindTexture(GL_TEXTURE_2D, h.tex);
      gl_.GenerateMipmap(GL_TEXTURE_2D);
    }
  }
  for (auto &pg : pl.passes)
    if (pg.feedback) pg.cur ^= 1;
  frame_count_++;
  return true;
}

GLuint SlangChain::output_framebuffer() const { return pipe_ && pipe_->out ? pipe_->out->fbo : 0; }
unsigned SlangChain::output_width() const { return pipe_ && pipe_->out ? pipe_->out->w : 0; }
unsigned SlangChain::output_height() const { return pipe_ && pipe_->out ? pipe_->out->h : 0; }

bool SlangChain::read_output(std::vector<uint32_t> *out) {
  const GLuint fbo = output_framebuffer();
  if (!fbo) return false;
  SavedState saved(gl_, 1, 0);
  const unsigned w = output_width(), h = output_height();
  out->resize(size_t(w) * h);
  gl_.BindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
  gl_.PixelStorei(GL_PACK_ALIGNMENT, 4);
  gl_.PixelStorei(GL_PACK_ROW_LENGTH, 0);
  gl_.ReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_BGRA, GL_UNSIGNED_BYTE, out->data());
  return gl_.GetError() == GL_NO_ERROR;
}

size_t SlangChain::pass_count() const { return pipe_ ? pipe_->passes.size() : 0; }
unsigned SlangChain::pass_width(size_t i) const {
  return pipe_ && i < pipe_->passes.size() ? pipe_->passes[i].w : 0;
}
unsigned SlangChain::pass_height(size_t i) const {
  return pipe_ && i < pipe_->passes.size() ? pipe_->passes[i].h : 0;
}
const Preset *SlangChain::preset() const { return pipe_ ? &pipe_->preset : nullptr; }

}  // namespace slang
}  // namespace dena
