// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/frame-generation.md (Pipeline). Our own method: block
// matching on luma, a per-pixel pick between neighbouring vectors, and a
// warp of the two real frames (provenance.md).
#include "dena/frame_gen.h"

#include <algorithm>

namespace dena {
namespace slang {

namespace {

// One triangle over the viewport, no vertex buffer.
const char kVertex[] = R"(#version 420
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// Step 1: luma at flow size, the box average of u_k x u_k frame pixels.
const char kLuma[] = R"(#version 420
layout(binding = 0) uniform sampler2D src;
uniform int u_k;
out vec4 o;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy) * u_k;
  ivec2 lim = textureSize(src, 0) - 1;
  float s = 0.0;
  for (int y = 0; y < u_k; y++)
    for (int x = 0; x < u_k; x++)
      s += dot(texelFetch(src, min(p + ivec2(x, y), lim), 0).rgb, vec3(0.299, 0.587, 0.114));
  o = vec4(s / float(u_k * u_k));
}
)";

// The half-size luma level.
const char kHalf[] = R"(#version 420
layout(binding = 0) uniform sampler2D src;
out vec4 o;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy) * 2;
  ivec2 lim = textureSize(src, 0) - 1;
  float s = texelFetch(src, min(p, lim), 0).r + texelFetch(src, min(p + ivec2(1, 0), lim), 0).r +
            texelFetch(src, min(p + ivec2(0, 1), lim), 0).r + texelFetch(src, min(p + ivec2(1, 1), lim), 0).r;
  o = vec4(s * 0.25);
}
)";

// Step 2: one fragment per 8x8 block of the half level, +-8 half pixels.
// Motion is from the previous frame to the current one: cur(x) = prev(x - v).
const char kCoarse[] = R"(#version 420
layout(binding = 0) uniform sampler2D prev;
layout(binding = 1) uniform sampler2D cur;
out vec4 o;
void main() {
  ivec2 lim = textureSize(cur, 0) - 1;
  ivec2 base = ivec2(gl_FragCoord.xy) * 8;
  float c[64];
  for (int i = 0; i < 64; i++)
    c[i] = texelFetch(cur, clamp(base + ivec2(i & 7, i >> 3), ivec2(0), lim), 0).r;
  float best = 1e9;
  ivec2 bv = ivec2(0);
  for (int k = -1; k < 289; k++) {
    // k = -1 is zero motion, so it wins ties.
    ivec2 d = k < 0 ? ivec2(0) : ivec2(k % 17 - 8, k / 17 - 8);
    float sad = 0.0;
    for (int i = 0; i < 64; i++)
      sad += abs(c[i] - texelFetch(prev, clamp(base + ivec2(i & 7, i >> 3) - d, ivec2(0), lim), 0).r);
    float cost = sad / 64.0 + 0.004 * float(abs(d.x) + abs(d.y));
    if (cost < best) {
      best = cost;
      bv = d;
    }
  }
  o = vec4(vec2(bv * 2), best, 0.0);
}
)";

// Step 3: one fragment per 8x8 block of flow pixels, +-2 around the coarse
// vectors of its own coarse block and the four next to it.
const char kFine[] = R"(#version 420
layout(binding = 0) uniform sampler2D prev;
layout(binding = 1) uniform sampler2D cur;
layout(binding = 2) uniform sampler2D coarse;
out vec4 o;
ivec2 lim;
ivec2 base;
float c[64];
float cost(ivec2 d) {
  float sad = 0.0;
  for (int i = 0; i < 64; i++)
    sad += abs(c[i] - texelFetch(prev, clamp(base + ivec2(i & 7, i >> 3) - d, ivec2(0), lim), 0).r);
  return sad / 64.0 + 0.002 * float(abs(d.x) + abs(d.y));
}
void main() {
  lim = textureSize(cur, 0) - 1;
  ivec2 b = ivec2(gl_FragCoord.xy);
  base = b * 8;
  for (int i = 0; i < 64; i++)
    c[i] = texelFetch(cur, clamp(base + ivec2(i & 7, i >> 3), ivec2(0), lim), 0).r;
  ivec2 clim = textureSize(coarse, 0) - 1;
  ivec2 cb = b / 2;
  ivec2 centers[5] = ivec2[5](cb, cb + ivec2(1, 0), cb - ivec2(1, 0), cb + ivec2(0, 1), cb - ivec2(0, 1));
  float best = cost(ivec2(0));
  ivec2 bv = ivec2(0);
  for (int k = 0; k < 5; k++) {
    ivec2 cv = ivec2(texelFetch(coarse, clamp(centers[k], ivec2(0), clim), 0).xy);
    for (int j = 0; j < 25; j++) {
      ivec2 d = cv + ivec2(j % 5 - 2, j / 5 - 2);
      float e = cost(d);
      if (e < best) {
        best = e;
        bv = d;
      }
    }
  }
  // The block's own match error, without the motion penalty.
  o = vec4(vec2(bv), best - 0.002 * float(abs(bv.x) + abs(bv.y)), 0.0);
}
)";

// Step 4: per flow pixel, the vector (zero or one of the 3x3 fine blocks
// around it) whose two half-way samples agree best over a 3x3 patch.
const char kPick[] = R"(#version 420
layout(binding = 0) uniform sampler2D prev;
layout(binding = 1) uniform sampler2D cur;
layout(binding = 2) uniform sampler2D fine;
uniform int u_mode;
out vec4 o;
void main() {
  ivec2 p = ivec2(gl_FragCoord.xy);
  ivec2 size = textureSize(cur, 0);
  ivec2 lim = size - 1;
  vec2 inv = 1.0 / vec2(size);
  ivec2 flim = textureSize(fine, 0) - 1;
  ivec2 fb = p / 8;
  float best = 1e9;
  vec2 bv = vec2(0.0);
  for (int k = -1; k < 9; k++) {
    vec2 v = vec2(0.0);
    if (k >= 0) {
      vec4 f = texelFetch(fine, clamp(fb + ivec2(k % 3 - 1, k / 3 - 1), ivec2(0), flim), 0);
      // A block whose best match is still poor has no real motion (noise,
      // a scene cut): its vector would only move unrelated pixels.
      if (f.z > 0.06) continue;
      v = f.xy;
    }
    vec2 s = floor(v * 0.5 + 0.5);
    float err = 0.0;
    for (int q = 0; q < 9; q++) {
      ivec2 x = p + ivec2(q % 3 - 1, q / 3 - 1);
      float a, b;
      if (u_mode == 2) {
        a = texelFetch(prev, clamp(x - ivec2(s), ivec2(0), lim), 0).r;
        b = texelFetch(cur, clamp(x + ivec2(v - s), ivec2(0), lim), 0).r;
      } else {
        a = texture(prev, (vec2(x) + 0.5 - v * 0.5) * inv).r;
        b = texture(cur, (vec2(x) + 0.5 + v * 0.5) * inv).r;
      }
      err += abs(a - b);
    }
    err /= 9.0;
    if (err < best - 1e-5) {
      best = err;
      bv = v;
    }
  }
  // Nothing explains this pixel (new content, a scene cut): no motion, so
  // the newest frame shows through.
  if (best > 0.06) bv = vec2(0.0);
  o = vec4(bv, best, 0.0);
}
)";

// Step 5: the in-between frame at frame size.
const char kSynth[] = R"(#version 420
layout(binding = 0) uniform sampler2D prev;
layout(binding = 1) uniform sampler2D cur;
layout(binding = 2) uniform sampler2D pick;
uniform int u_mode;
uniform int u_f;
out vec4 o;
void main() {
  ivec2 x = ivec2(gl_FragCoord.xy);
  ivec2 size = textureSize(cur, 0);
  vec2 v = texelFetch(pick, min(x / u_f, textureSize(pick, 0) - 1), 0).xy;
  if (u_mode == 2) {
    // Whole game pixels: the current frame's own pixels, moved back by
    // what is left of the motion after half of it (rounded).
    vec2 s = floor(v * 0.5 + 0.5);
    ivec2 shift = ivec2(v - s) * u_f;
    o = texelFetch(cur, clamp(x + shift, ivec2(0), size - 1), 0);
  } else {
    vec2 h = v * 0.5 * float(u_f);
    vec2 inv = 1.0 / vec2(size);
    vec4 a = texture(prev, (vec2(x) + 0.5 - h) * inv);
    vec4 b = texture(cur, (vec2(x) + 0.5 + h) * inv);
    vec3 d = abs(a.rgb - b.rgb);
    // Where the two warps disagree, the newest frame as it is wins: no ghosts.
    vec4 c = texelFetch(cur, x, 0);
    o = mix((a + b) * 0.5, c, smoothstep(0.04, 0.12, max(d.r, max(d.g, d.b))));
  }
  o.a = 1.0;
}
)";

GLuint shader(const Gl &gl, GLenum type, const char *src, std::string *err) {
  GLuint s = gl.CreateShader(type);
  gl.ShaderSource(s, 1, &src, nullptr);
  gl.CompileShader(s);
  GLint ok = 0;
  gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char buf[2048] = {};
    gl.GetShaderInfoLog(s, sizeof buf - 1, nullptr, buf);
    *err = std::string("frame generation shader: ") + buf;
    gl.DeleteShader(s);
    return 0;
  }
  return s;
}

GLuint program(const Gl &gl, const char *fragment, std::string *err) {
  GLuint vs = shader(gl, GL_VERTEX_SHADER, kVertex, err);
  if (!vs) return 0;
  GLuint fs = shader(gl, GL_FRAGMENT_SHADER, fragment, err);
  if (!fs) {
    gl.DeleteShader(vs);
    return 0;
  }
  GLuint p = gl.CreateProgram();
  gl.AttachShader(p, vs);
  gl.AttachShader(p, fs);
  gl.LinkProgram(p);
  gl.DeleteShader(vs);
  gl.DeleteShader(fs);
  GLint ok = 0;
  gl.GetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    char buf[2048] = {};
    gl.GetProgramInfoLog(p, sizeof buf - 1, nullptr, buf);
    *err = std::string("frame generation program: ") + buf;
    gl.DeleteProgram(p);
    return 0;
  }
  return p;
}

void uniform(const Gl &gl, GLuint prog, const char *name, int v) {
  gl.UseProgram(prog);
  GLint loc = gl.GetUniformLocation(prog, name);
  if (loc >= 0) gl.Uniform1i(loc, v);
}

unsigned blocks(unsigned n, unsigned size) { return std::max(1u, (n + size - 1) / size); }

}  // namespace

void FrameGen::flow_size(unsigned w, unsigned h, unsigned nw, unsigned nh, unsigned *fw,
                         unsigned *fh, unsigned *factor) {
  unsigned f = 1;
  if (nw && nh && w >= nw && h >= nh && w % nw == 0 && h % nh == 0 && w / nw == h / nh) {
    f = w / nw;  // a k-times internal resolution frame: flow at the game's own pixels
  } else {
    while (w / f > 640 || h / f > 480) f++;
  }
  *factor = f;
  *fw = std::max(1u, w / f);
  *fh = std::max(1u, h / f);
}

bool FrameGen::init(const Gl &gl, std::string *err) {
  if (ready_) return true;
  struct {
    GLuint *out;
    const char *src;
  } progs[] = {{&luma_prog_, kLuma}, {&half_prog_, kHalf}, {&coarse_prog_, kCoarse},
               {&fine_prog_, kFine}, {&pick_prog_, kPick}, {&synth_prog_, kSynth}};
  for (auto &p : progs) {
    *p.out = program(gl, p.src, err);
    if (!*p.out) {
      release(gl);
      return false;
    }
  }
  GLint saved_prog = 0;
  gl.GetIntegerv(GL_CURRENT_PROGRAM, &saved_prog);
  uniform(gl, luma_prog_, "u_k", 1);
  gl.UseProgram(GLuint(saved_prog));
  gl.GenVertexArrays(1, &vao_);
  gl.GenFramebuffers(1, &read_fbo_);
  gl.GenSamplers(1, &nearest_);
  gl.GenSamplers(1, &linear_);
  for (GLuint s : {nearest_, linear_}) {
    const GLint f = s == linear_ ? GL_LINEAR : GL_NEAREST;
    gl.SamplerParameteri(s, GL_TEXTURE_MIN_FILTER, f);
    gl.SamplerParameteri(s, GL_TEXTURE_MAG_FILTER, f);
    gl.SamplerParameteri(s, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.SamplerParameteri(s, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  gl.GenQueries(kQueries, queries_);
  ready_ = true;
  return true;
}

void FrameGen::release(const Gl &gl) {
  for (GLuint *p : {&luma_prog_, &half_prog_, &coarse_prog_, &fine_prog_, &pick_prog_, &synth_prog_})
    if (*p) {
      gl.DeleteProgram(*p);
      *p = 0;
    }
  for (int i = 0; i < 2; i++) {
    free_target(gl, &color_[i]);
    free_target(gl, &luma_[i]);
    free_target(gl, &half_[i]);
  }
  for (Target *t : {&coarse_, &fine_, &pick_, &out_}) free_target(gl, t);
  if (vao_) gl.DeleteVertexArrays(1, &vao_);
  if (read_fbo_) gl.DeleteFramebuffers(1, &read_fbo_);
  if (nearest_) gl.DeleteSamplers(1, &nearest_);
  if (linear_) gl.DeleteSamplers(1, &linear_);
  if (queries_[0]) gl.DeleteQueries(kQueries, queries_);
  vao_ = read_fbo_ = nearest_ = linear_ = 0;
  for (int i = 0; i < kQueries; i++) {
    queries_[i] = 0;
    query_busy_[i] = false;
  }
  w_ = h_ = fw_ = fh_ = 0;
  frames_ = 0;
  ready_ = false;
}

bool FrameGen::alloc(const Gl &gl, Target *t, unsigned w, unsigned h, GLenum fmt) {
  free_target(gl, t);
  gl.GenTextures(1, &t->tex);
  gl.BindTexture(GL_TEXTURE_2D, t->tex);
  gl.TexStorage2D(GL_TEXTURE_2D, 1, fmt, GLsizei(w), GLsizei(h));
  gl.GenFramebuffers(1, &t->fbo);
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, t->fbo);
  gl.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->tex, 0);
  t->w = w;
  t->h = h;
  return gl.CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

void FrameGen::free_target(const Gl &gl, Target *t) {
  if (t->fbo) gl.DeleteFramebuffers(1, &t->fbo);
  if (t->tex) gl.DeleteTextures(1, &t->tex);
  *t = Target{};
}

bool FrameGen::ensure(const Gl &gl, unsigned w, unsigned h) {
  unsigned fw, fh, f;
  flow_size(w, h, native_w_, native_h_, &fw, &fh, &f);
  if (w == w_ && h == h_ && fw == fw_ && fh == fh_ && f == factor_) return true;
  frames_ = 0;  // nothing to generate from across a size change
  w_ = h_ = 0;
  gl.ActiveTexture(GL_TEXTURE0);
  const unsigned hw = std::max(1u, fw / 2), hh = std::max(1u, fh / 2);
  bool ok = true;
  for (int i = 0; i < 2; i++) {
    ok = ok && alloc(gl, &color_[i], w, h, GL_RGBA8);
    ok = ok && alloc(gl, &luma_[i], fw, fh, GL_R16F);
    ok = ok && alloc(gl, &half_[i], hw, hh, GL_R16F);
  }
  ok = ok && alloc(gl, &coarse_, blocks(hw, 8), blocks(hh, 8), GL_RGBA16F);
  ok = ok && alloc(gl, &fine_, blocks(fw, 8), blocks(fh, 8), GL_RGBA16F);
  ok = ok && alloc(gl, &pick_, fw, fh, GL_RGBA16F);
  ok = ok && alloc(gl, &out_, w, h, GL_RGBA8);
  if (!ok) return false;
  w_ = w;
  h_ = h;
  fw_ = fw;
  fh_ = fh;
  factor_ = f;
  return true;
}

void FrameGen::bind(const Gl &gl, GLuint unit, GLuint tex, bool linear) {
  gl.ActiveTexture(GL_TEXTURE0 + unit);
  gl.BindTexture(GL_TEXTURE_2D, tex);
  gl.BindSampler(unit, linear ? linear_ : nearest_);
}

void FrameGen::pass(const Gl &gl, GLuint prog, const Target &out) {
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, out.fbo);
  gl.Viewport(0, 0, GLsizei(out.w), GLsizei(out.h));
  gl.UseProgram(prog);
  gl.DrawArrays(GL_TRIANGLES, 0, 3);
}

bool FrameGen::push(const Gl &gl, GLuint tex) {
  cur_ ^= 1;
  // The real frame into our own texture: the source is overwritten by the
  // next one while we still need it as "previous".
  gl.BindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo_);
  gl.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, color_[cur_].fbo);
  gl.BlitFramebuffer(0, 0, GLint(w_), GLint(h_), 0, 0, GLint(w_), GLint(h_), GL_COLOR_BUFFER_BIT,
                     GL_NEAREST);
  gl.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
  gl.BindVertexArray(vao_);
  bind(gl, 0, color_[cur_].tex, false);
  uniform(gl, luma_prog_, "u_k", int(factor_));
  pass(gl, luma_prog_, luma_[cur_]);
  bind(gl, 0, luma_[cur_].tex, false);
  pass(gl, half_prog_, half_[cur_]);
  frames_ = std::min(frames_ + 1, 2u);
  return true;
}

bool FrameGen::generate(const Gl &gl) {
  const int prev = cur_ ^ 1;
  gl.BindVertexArray(vao_);
  bind(gl, 0, half_[prev].tex, false);
  bind(gl, 1, half_[cur_].tex, false);
  pass(gl, coarse_prog_, coarse_);
  bind(gl, 0, luma_[prev].tex, false);
  bind(gl, 1, luma_[cur_].tex, false);
  bind(gl, 2, coarse_.tex, false);
  pass(gl, fine_prog_, fine_);
  // Interpolation samples half pixels: linear luma.
  const bool lin = mode_ != kPixelArt;
  bind(gl, 0, luma_[prev].tex, lin);
  bind(gl, 1, luma_[cur_].tex, lin);
  bind(gl, 2, fine_.tex, false);
  uniform(gl, pick_prog_, "u_mode", mode_);
  pass(gl, pick_prog_, pick_);
  bind(gl, 0, color_[prev].tex, lin);
  bind(gl, 1, color_[cur_].tex, lin);
  bind(gl, 2, pick_.tex, false);
  uniform(gl, synth_prog_, "u_mode", mode_);
  uniform(gl, synth_prog_, "u_f", int(factor_));
  pass(gl, synth_prog_, out_);
  generated_++;
  return true;
}

double FrameGen::take_gpu_ms(const Gl &gl) {
  double ms = -1;
  // Oldest first, so the newest finished one is what is returned.
  for (int k = 0; k < kQueries; k++) {
    const int i = (query_next_ + k) % kQueries;
    if (!query_busy_[i]) continue;
    GLint avail = 0;
    gl.GetQueryObjectiv(queries_[i], GL_QUERY_RESULT_AVAILABLE, &avail);
    if (!avail) continue;
    GLuint64 ns = 0;
    gl.GetQueryObjectui64v(queries_[i], GL_QUERY_RESULT, &ns);
    query_busy_[i] = false;
    ms = double(ns) / 1e6;
  }
  return ms;
}

GLuint FrameGen::filter(const Gl &gl, GLuint tex, unsigned *w, unsigned *h) {
  const Next n = next_;
  next_ = kPass;  // one call each: a later render without next() shades as is
  if (!ready_ || n == kPass || !tex) return tex;
  if (!ensure(gl, *w, *h)) return tex;
  for (GLenum e : {GL_DEPTH_TEST, GL_STENCIL_TEST, GL_BLEND, GL_SCISSOR_TEST, GL_CULL_FACE,
                   GL_FRAMEBUFFER_SRGB, GL_RASTERIZER_DISCARD})
    gl.Disable(e);
  gl.ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  const bool gen = n == kGenerate && frames_ > 0;
  const int q = query_next_;
  const bool timed = gen && !query_busy_[q];
  if (timed) gl.BeginQuery(GL_TIME_ELAPSED, queries_[q]);
  push(gl, tex);
  if (gen) generate(gl);
  if (timed) {
    gl.EndQuery(GL_TIME_ELAPSED);
    query_busy_[q] = true;
    query_next_ = (q + 1) % kQueries;
  }
  return gen ? out_.tex : tex;
}

}  // namespace slang
}  // namespace dena
