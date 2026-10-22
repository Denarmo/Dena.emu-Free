// Experimental 2x frame generation on desktop GL 4.2+: block-matching motion
// search between the last two real frames and an in-between frame built from
// it, either blended (interpolate) or by whole-pixel shifts (pixel-art).
// Plugs into SlangChain as its source filter. Every call needs the GL context
// current on this thread. Spec: docs/specs/frame-generation.md
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>

#include "dena/gl_api.h"
#include "dena/slang_chain.h"

namespace dena {
namespace slang {

class FrameGen : public SourceFilter {
 public:
  enum Mode { kInterpolate = 1, kPixelArt = 2 };
  // What the next filter() call does with the frame it gets.
  enum Next {
    kPass,      // shade the frame as it is (a held real frame, a repaint)
    kPush,      // keep it as the newest real frame, shade it as it is
    kGenerate,  // keep it, shade the frame between the previous one and it
  };

  FrameGen() = default;
  ~FrameGen() override = default;  // GL objects must already be gone (release())
  FrameGen(const FrameGen &) = delete;
  FrameGen &operator=(const FrameGen &) = delete;

  // Compiles the programs. False with a message.
  bool init(const Gl &gl, std::string *err);
  bool ready() const { return ready_; }
  void release(const Gl &gl);

  void set_mode(int mode) { mode_ = mode == kPixelArt ? kPixelArt : kInterpolate; }
  int mode() const { return mode_; }
  // The game's native size (shader-stacks.md, Native lines); 0 = unknown.
  void set_native_size(unsigned w, unsigned h) { native_w_ = w, native_h_ = h; }
  void next(Next n) { next_ = n; }
  // Forgets the kept frames (a jump: state load, rewind, a new game).
  void invalidate() { frames_ = 0; }
  // A w x h real frame was kept before, so kGenerate can make a frame.
  bool has_previous(unsigned w, unsigned h) const {
    return frames_ > 0 && w == w_ && h == h_;
  }
  // GPU time of the last finished generated frame in ms, -1 when none
  // finished since the last call.
  double take_gpu_ms(const Gl &gl);
  // The flow size for a w x h frame and the whole factor between them.
  static void flow_size(unsigned w, unsigned h, unsigned native_w, unsigned native_h,
                        unsigned *fw, unsigned *fh, unsigned *factor);
  uint64_t generated() const { return generated_; }

  GLuint filter(const Gl &gl, GLuint tex, unsigned *w, unsigned *h) override;

 private:
  struct Target {
    GLuint tex = 0, fbo = 0;
    unsigned w = 0, h = 0;
  };
  bool alloc(const Gl &gl, Target *t, unsigned w, unsigned h, GLenum fmt);
  void free_target(const Gl &gl, Target *t);
  bool ensure(const Gl &gl, unsigned w, unsigned h);
  bool push(const Gl &gl, GLuint tex);
  bool generate(const Gl &gl);
  void pass(const Gl &gl, GLuint program, const Target &out);
  void bind(const Gl &gl, GLuint unit, GLuint tex, bool linear);

  bool ready_ = false;
  int mode_ = kInterpolate;
  Next next_ = kPass;
  unsigned native_w_ = 0, native_h_ = 0;
  unsigned w_ = 0, h_ = 0, fw_ = 0, fh_ = 0, factor_ = 1;
  unsigned frames_ = 0;  // real frames kept since the last invalidate (capped)
  int cur_ = 0;          // index of the newest of the two kept frames
  uint64_t generated_ = 0;

  GLuint vao_ = 0, read_fbo_ = 0, nearest_ = 0, linear_ = 0;
  GLuint luma_prog_ = 0, half_prog_ = 0, coarse_prog_ = 0, fine_prog_ = 0;
  GLuint pick_prog_ = 0, synth_prog_ = 0;
  Target color_[2], luma_[2], half_[2];
  Target coarse_, fine_, pick_, out_;

  static constexpr int kQueries = 4;
  GLuint queries_[kQueries] = {};
  bool query_busy_[kQueries] = {};
  int query_next_ = 0;
};

}  // namespace slang
}  // namespace dena
