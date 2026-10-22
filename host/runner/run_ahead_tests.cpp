// SPDX-License-Identifier: GPL-3.0-or-later
// Run-ahead logic with a fake core (docs/specs/run-ahead.md, Acceptance).
// The fake's state is the list of inputs its frames ran with.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "run_ahead.h"

namespace {

int failures = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    if (!(cond)) {                                                         \
      std::fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                          \
    }                                                                      \
  } while (0)

class FakeCore : public dena::RunAheadDriver {
 public:
  std::vector<uint16_t> history;  // the state: one input per frame run
  uint16_t input = 0;             // what the next frame reads
  int real = 0, hidden = 0, saves = 0, loads = 0;
  bool fail_save = false;
  std::vector<uint16_t> shown;  // newest history entry after each frame call
  // Sound: per_frame samples a frame makes; block 0 hands them out in the
  // frame, block n keeps them in a buffer outside the state and hands out
  // whole blocks of n (like mGBA's GB path). silent: frames that make none.
  double per_frame = 0;
  size_t block = 0;
  int silent = 0;
  std::vector<size_t> real_audio;  // samples handed out by each real frame

  size_t state_size() override { return (history.size() + 64) * sizeof(uint16_t); }
  bool save(void *buf, size_t size) override {
    if (fail_save) return false;
    saves++;
    std::memset(buf, 0xff, size);
    uint16_t n = uint16_t(history.size());
    std::memcpy(buf, &n, 2);
    if (n) std::memcpy(static_cast<uint8_t *>(buf) + 2, history.data(), history.size() * 2);
    return true;
  }
  bool load(const void *buf, size_t) override {
    loads++;
    uint16_t n;
    std::memcpy(&n, buf, 2);
    history.assign(n, 0);
    if (n) std::memcpy(history.data(), static_cast<const uint8_t *>(buf) + 2, size_t(n) * 2);
    return true;
  }
  size_t step(bool h) override {
    history.push_back(input);
    (h ? hidden : real)++;
    last_.assign(history.begin(), history.end());
    size_t out = 0;
    if (silent > 0) {
      silent--;
    } else {
      made_ += per_frame;
      size_t whole = size_t(std::floor(made_)) - handed_;  // made this frame
      buffered_ += whole;
      handed_ += whole;
      size_t take = block ? buffered_ / block * block : buffered_;
      buffered_ -= take;
      out = take;
    }
    if (!h) real_audio.push_back(out);
    return out;
  }
  double audio_per_frame() override { return per_frame; }
  // What the last stepped frame (the one on screen) had seen.
  std::vector<uint16_t> picture() const { return last_; }

 private:
  std::vector<uint16_t> last_;
  double made_ = 0;
  size_t handed_ = 0, buffered_ = 0;
};

dena::RunAheadInput in(uint16_t b) {
  dena::RunAheadInput i;
  i.buttons[0] = b;
  return i;
}

void frame(dena::RunAhead &ra, FakeCore &c, uint16_t b, bool shown = true) {
  c.input = b;
  ra.frame(c, in(b), shown);
}

void test_off() {
  dena::RunAhead ra;
  FakeCore c;
  ra.configure(dena::kRunAheadPreemptive, 2, 0);  // core not supported
  CHECK(ra.frames() == 0);
  for (int i = 0; i < 5; i++) frame(ra, c, 1);
  CHECK(c.real == 5 && c.hidden == 0 && c.saves == 0);
  ra.configure(dena::kRunAheadOff, 3, 3);
  CHECK(ra.frames() == 0);
  ra.configure(dena::kRunAheadSingle, 9, 3);  // clamped
  CHECK(ra.frames() == 3);
  ra.configure(dena::kRunAheadSingle, 3, 2);  // the core's limit
  CHECK(ra.frames() == 2);
}

void test_single() {
  dena::RunAhead ra;
  FakeCore c;
  ra.configure(dena::kRunAheadSingle, 2, 3);
  frame(ra, c, 0);
  frame(ra, c, 5);
  // The real timeline holds one frame per call; the picture is 2 ahead,
  // predicted with the input held.
  CHECK((c.history == std::vector<uint16_t>{0, 5}));
  CHECK((c.picture() == std::vector<uint16_t>{0, 5, 5, 5}));
  CHECK(c.real == 2 && c.hidden == 4 && c.saves == 2 && c.loads == 2);
  // A catch-up frame that is not shown runs plain.
  frame(ra, c, 5, false);
  CHECK(c.real == 3 && c.hidden == 4 && c.history.size() == 3);
}

void test_preemptive() {
  dena::RunAhead ra;
  FakeCore c;
  ra.configure(dena::kRunAheadPreemptive, 2, 3);
  for (int i = 0; i < 4; i++) frame(ra, c, 0);
  CHECK(c.hidden == 0 && c.loads == 0 && c.saves == 4);
  frame(ra, c, 7);  // input changed: the last 2 frames replay with it
  CHECK((c.history == std::vector<uint16_t>{0, 0, 7, 7, 7}));
  CHECK(c.hidden == 2 && c.loads == 1);
  frame(ra, c, 7);  // held: no replay
  CHECK(c.hidden == 2 && c.loads == 1);
  CHECK((c.history == std::vector<uint16_t>{0, 0, 7, 7, 7, 7}));
  frame(ra, c, 0);  // release replays too
  CHECK((c.history == std::vector<uint16_t>{0, 0, 7, 7, 0, 0, 0}));
  CHECK(c.real == 7 && c.hidden == 4);
}

void test_preemptive_needs_history() {
  dena::RunAhead ra;
  FakeCore c;
  ra.configure(dena::kRunAheadPreemptive, 3, 3);
  frame(ra, c, 0);
  frame(ra, c, 1);  // only 1 frame of history: no replay yet
  CHECK(c.loads == 0);
  frame(ra, c, 1);
  frame(ra, c, 1);
  ra.invalidate();  // e.g. a state load
  frame(ra, c, 2);
  frame(ra, c, 3);
  CHECK(c.loads == 0);
  CHECK((c.history == std::vector<uint16_t>{0, 1, 1, 1, 2, 3}));
}

void test_failure() {
  dena::RunAhead ra;
  FakeCore c;
  ra.configure(dena::kRunAheadPreemptive, 1, 3);
  c.fail_save = true;
  frame(ra, c, 0);
  CHECK(ra.frames() == 0 && c.real == 1);
  c.fail_save = false;
  frame(ra, c, 1);
  CHECK(c.saves == 0 && c.real == 2);  // stays off for this game
  ra.restart();
  CHECK(ra.frames() == 1);
  dena::RunAhead single;
  FakeCore d;
  single.configure(dena::kRunAheadSingle, 1, 3);
  d.fail_save = true;
  frame(single, d, 0);
  CHECK(single.frames() == 0 && d.real == 1 && d.hidden == 0);
}

// Run-ahead mode keeps a core whose sound leaves it in its own frame, even
// with a silent boot and a rate that is not a whole number per frame; it
// starts after the probe, which runs preemptive.
void test_audio_aligned() {
  dena::RunAhead ra;
  FakeCore c;
  c.per_frame = 48000 / 60.0988;  // 798.7: 798 or 799 per frame
  c.silent = 5;
  ra.configure(dena::kRunAheadSingle, 2, 3);
  for (int i = 0; i < dena::kAudioProbeFrames; i++) {
    CHECK(ra.mode() == dena::kRunAheadPreemptive);
    frame(ra, c, 0);
  }
  CHECK(ra.mode() == dena::kRunAheadSingle && c.hidden == 0);
  for (int i = 0; i < 1000; i++) frame(ra, c, uint16_t(i / 7 % 2));
  CHECK(!ra.audio_buffered() && ra.mode() == dena::kRunAheadSingle);
  CHECK(c.hidden == 2000);
  for (size_t i = 5; i < c.real_audio.size(); i++)
    CHECK(c.real_audio[i] == 798 || c.real_audio[i] == 799);
  // A driver without a rate is not probed.
  dena::RunAhead quiet;
  FakeCore q;
  quiet.configure(dena::kRunAheadSingle, 1, 3);
  frame(quiet, q, 0);
  CHECK(quiet.mode() == dena::kRunAheadSingle && q.hidden == 1);
}

// A core that hands sound out in blocks from a buffer outside its state
// falls back to preemptive for the game during the probe, before any
// run-ahead frame; a new game checks again.
void test_audio_buffered() {
  dena::RunAhead ra;
  FakeCore c;
  c.per_frame = 32768 / 59.7275;  // GB: 548.6 a frame, out in blocks of 512
  c.block = 512;
  ra.configure(dena::kRunAheadSingle, 1, 3);
  int used = 0;
  while (!ra.audio_buffered() && used < dena::kAudioProbeFrames) frame(ra, c, 1), used++;
  CHECK(ra.audio_buffered() && used < dena::kAudioProbeFrames);
  for (int i = 0; i < 40; i++) frame(ra, c, 1);  // held: preemptive replays nothing
  CHECK(ra.mode() == dena::kRunAheadPreemptive && ra.frames() == 1 && c.hidden == 0);
  frame(ra, c, 0);
  CHECK(c.hidden == 1);
  ra.restart();
  CHECK(!ra.audio_buffered());
  // bsnes's blocks are one frame long, so its frames look even: it is known.
  CHECK(dena::run_ahead_audio_blocks("C:/x/cores/bsnes_libretro.dll"));
  CHECK(!dena::run_ahead_audio_blocks("mgba_libretro.so"));
  CHECK(!dena::run_ahead_audio_blocks("fceumm_libretro.so"));
  ra.restart(true);
  CHECK(ra.audio_buffered() && ra.mode() == dena::kRunAheadPreemptive);
  // Preemptive is not changed by the check.
  dena::RunAhead pre;
  FakeCore p;
  p.per_frame = 548.6;
  p.block = 512;
  pre.configure(dena::kRunAheadPreemptive, 1, 3);
  for (int i = 0; i < 20; i++) frame(pre, p, 1);
  CHECK(pre.audio_buffered() && pre.mode() == dena::kRunAheadPreemptive);
}

void test_core_limits() {
  CHECK(dena::run_ahead_core_limit("C:/x/cores/fceumm_libretro.dll") == 3);
  CHECK(dena::run_ahead_core_limit("/app/lib/cores/bsnes_libretro.so") == 3);
  CHECK(dena::run_ahead_core_limit("mgba_libretro.so") == 3);
  CHECK(dena::run_ahead_core_limit("mednafen_psx_hw_libretro.so") == 2);
  CHECK(dena::run_ahead_core_limit("melonds_libretro.so") == 0);
  CHECK(dena::run_ahead_core_limit("ppsspp_libretro.dll") == 0);
  CHECK(dena::run_ahead_core_limit("mupen64plus_next_libretro.so") == 0);
}

}  // namespace

int main() {
  test_off();
  test_single();
  test_preemptive();
  test_preemptive_needs_history();
  test_failure();
  test_audio_aligned();
  test_audio_buffered();
  test_core_limits();
  if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
  return failures ? 1 : 0;
}
