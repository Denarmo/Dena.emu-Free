// SPDX-License-Identifier: GPL-3.0-or-later
// Run-ahead and preemptive frames: hide the game's own input lag by running
// the core ahead with save states. Header-only so every shell that builds
// runner.cpp gets it without a build change; only the desktop turns it on.
// Spec: docs/specs/run-ahead.md
#ifndef DENA_RUN_AHEAD_H
#define DENA_RUN_AHEAD_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace dena {

enum RunAheadMode { kRunAheadOff = 0, kRunAheadPreemptive = 1, kRunAheadSingle = 2 };

constexpr int kRunAheadMaxFrames = 3;

// Frames of run-ahead the core at core_path allows (0: not supported).
inline int run_ahead_core_limit(const std::string &core_path) {
  struct Limit {
    const char *core;
    int frames;
  };
  // Light enough to run 2-4x and serialize every frame (run-ahead.md).
  static const Limit kLimits[] = {
      {"fceumm", 3}, {"bsnes", 3}, {"mgba", 3}, {"fake08", 3},
      {"mednafen_psx", 2},  // Beetle PSX (HW) library names
      {"beetle_psx", 2},
      {"testcore", 3},  // host tests only
  };
  std::string name = core_path.substr(core_path.find_last_of("/\\") + 1);
  for (const auto &l : kLimits)
    if (name.find(l.core) != std::string::npos) return l.frames;
  return 0;
}

// The input a frame ran with, as far as preemptive replays compare it.
struct RunAheadInput {
  uint16_t buttons[8] = {};  // DENA_MAX_PORTS
  bool pointer = false;
  bool operator==(const RunAheadInput &o) const {
    return pointer == o.pointer && std::memcmp(buttons, o.buttons, sizeof buttons) == 0;
  }
  bool operator!=(const RunAheadInput &o) const { return !(*this == o); }
};

// What the runner does for one emulated frame. Inputs are already set on
// the core; hidden frames are muted and skip the frame hooks.
class RunAheadDriver {
 public:
  virtual ~RunAheadDriver() = default;
  virtual size_t state_size() = 0;
  virtual bool save(void *buf, size_t size) = 0;
  virtual bool load(const void *buf, size_t size) = 0;
  // Returns the stereo samples the core handed out during the frame.
  virtual size_t step(bool hidden) = 0;
  // Samples one frame makes (sample rate / fps); 0: do not check the audio.
  virtual double audio_per_frame() { return 0; }
};

// Run-ahead mode needs a core whose sound leaves it in the frame that made
// it. Some keep samples in a buffer their save states do not hold and hand
// them out in fixed blocks (mGBA's GB/GBC path: 512 samples; bsnes: one
// 60 Hz frame): there the hidden frames' sound leaks into the real timeline
// and real sound is dropped with the hidden frames, which crackles. Such a
// core runs preemptive instead. bsnes is known; others give themselves away
// on real frames, where a block-wise core hands out a whole block more or
// less than the frame before (a frame-wise core varies by a sample or two).
// Run-ahead mode starts once kAudioProbeFrames real frames passed the check.
constexpr int kAudioProbeFrames = 30;
constexpr int kAudioSettleFrames = 4;  // after the first sound: boot frames vary

inline bool run_ahead_audio_blocks(const std::string &core_path) {
  std::string name = core_path.substr(core_path.find_last_of("/\\") + 1);
  return name.find("bsnes") != std::string::npos;
}

// Emulator thread only.
class RunAhead {
 public:
  // frames is clamped to 0..limit; mode off or 0 frames runs plain frames.
  void configure(int mode, int frames, int limit) {
    int f = std::clamp(frames, 0, std::min(limit, kRunAheadMaxFrames));
    if (mode == kRunAheadOff || f == 0) mode = kRunAheadOff, f = 0;
    if (mode == mode_ && f == frames_) return;
    mode_ = mode;
    frames_ = f;
    invalidate();
  }
  // A new game: forget everything, including a past failure. audio_blocks:
  // the core is known to hand out sound in blocks (run_ahead_audio_blocks).
  void restart(bool audio_blocks = false) {
    failed_ = false;
    audio_buffered_ = audio_blocks;
    audio_frames_ = probe_frames_ = 0;
    audio_avg_ = 0;
    invalidate();
  }
  // The state changed outside the frame loop: nothing may replay across it.
  void invalidate() { count_ = 0; }

  // Frames hidden from the latency right now (0 when off or failed).
  int frames() const { return failed_ ? 0 : frames_; }
  int mode() const {
    if (failed_) return kRunAheadOff;
    bool probing = probe_frames_ < kAudioProbeFrames;
    return mode_ == kRunAheadSingle && (audio_buffered_ || probing) ? int(kRunAheadPreemptive)
                                                                    : mode_;
  }
  // The core holds sound across frames: run-ahead mode runs preemptive.
  bool audio_buffered() const { return audio_buffered_; }

  // Runs one real frame for `in`. shown: this frame's picture is presented
  // (the last one of a vsync). Falls back to a plain frame when off.
  void frame(RunAheadDriver &d, const RunAheadInput &in, bool shown) {
    if (d.audio_per_frame() <= 0) probe_frames_ = kAudioProbeFrames;  // nothing to check
    if (frames() == 0) return real(d);
    if (mode() == kRunAheadSingle) single(d, shown);
    else preemptive(d, in);
  }

 private:
  struct Slot {
    std::vector<uint8_t> state;  // the core before this frame ran
    RunAheadInput input;
  };

  bool save_into(RunAheadDriver &d, std::vector<uint8_t> &buf) {
    size_t size = d.state_size();
    if (size == 0) return false;
    if (buf.size() != size) buf.assign(size, 0);
    return d.save(buf.data(), size);
  }

  void fail() {
    failed_ = true;
    invalidate();
  }

  // A frame of the real timeline; its sound is checked (kAudioProbeFrames).
  void real(RunAheadDriver &d) {
    size_t n = d.step(false);
    double per = d.audio_per_frame();
    if (probe_frames_ < kAudioProbeFrames) probe_frames_++;
    if (per <= 0 || audio_buffered_ || (audio_frames_ == 0 && n == 0)) return;
    if (++audio_frames_ <= kAudioSettleFrames) {
      audio_avg_ = double(n);
      return;
    }
    if (std::fabs(double(n) - audio_avg_) > per / 4) {
      audio_buffered_ = true;  // for this game (restart)
      invalidate();
      return;
    }
    audio_avg_ += (double(n) - audio_avg_) / 8;
  }

  void single(RunAheadDriver &d, bool shown) {
    real(d);
    if (!shown || audio_buffered_) return;  // found out now: no hidden frame
    if (!save_into(d, real_)) return fail();
    for (int i = 0; i < frames_; i++) d.step(true);
    if (!d.load(real_.data(), real_.size())) fail();  // stays ahead: rare, and only once
  }

  void preemptive(RunAheadDriver &d, const RunAheadInput &in) {
    size_t n = size_t(frames_);
    if (ring_.size() != n) {
      ring_.assign(n, Slot{});
      count_ = 0;
    }
    if (count_ == n && newest().input != in) {
      // Replay the last n frames as if the new input had come n frames ago.
      Slot &first = ring_[head_];
      if (!d.load(first.state.data(), first.state.size())) return fail_and_step(d);
      bool ok = true;  // after a failed save, still replay to the present
      for (size_t k = 0; k < n; k++) {
        Slot &s = ring_[(head_ + k) % n];
        if (k > 0 && ok) ok = save_into(d, s.state);
        s.input = in;
        d.step(true);
      }
      if (!ok) return fail_and_step(d);
    }
    // The oldest slot becomes the newest: the state before this frame.
    Slot &s = ring_[head_];
    if (!save_into(d, s.state)) return fail_and_step(d);
    s.input = in;
    head_ = (head_ + 1) % n;
    count_ = std::min(count_ + 1, n);
    real(d);
  }

  void fail_and_step(RunAheadDriver &d) {
    fail();
    real(d);
  }

  const Slot &newest() const { return ring_[(head_ + ring_.size() - 1) % ring_.size()]; }

  int mode_ = kRunAheadOff;
  int frames_ = 0;
  bool failed_ = false;
  std::vector<uint8_t> real_;  // single mode: the real frame's state
  std::vector<Slot> ring_;     // preemptive: oldest at head_
  size_t head_ = 0, count_ = 0;
  bool audio_buffered_ = false;
  int audio_frames_ = 0;    // real frames since the core's first sound
  int probe_frames_ = 0;    // real frames checked, up to kAudioProbeFrames
  double audio_avg_ = 0;    // samples per real frame, smoothed
};

}  // namespace dena

#endif
