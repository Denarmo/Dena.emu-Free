// SPDX-License-Identifier: GPL-3.0-or-later
// Frame generation timing and latency gate, without GL: which picture each
// vsync shows (a generated frame, the held real one, a real one at once),
// when frame generation is allowed (refresh rule, latency gate) and its
// metrics. Thread-safe: the emulator thread drives it, any thread reads.
// Spec: docs/specs/frame-generation.md (Timing, Latency gate, Metrics)
#ifndef DENA_FRAME_GEN_PACER_H
#define DENA_FRAME_GEN_PACER_H

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace dena {

class FrameGenPacer {
 public:
  enum Show { kShowReal, kShowGenerated };

  // The latency of the game without frame generation, read when the gate
  // checks: p95 input_to_post in ms (< 0: no samples) and run-ahead frames.
  using Context = std::function<void(double *input_p95_ms, int *run_ahead_frames)>;

  // Any thread: 0 off, 1 interpolate, 2 pixel-art (others are off).
  void set_want(int mode);
  int want() const;
  // At game start and when the refresh changes; a value <= 0 keeps the old.
  void configure(double refresh_hz, double fps);
  void set_context(Context c);
  // Mode in effect (0: off) and why it is not the wanted one ("" when it is).
  int mode() const;
  std::string off_reason() const;
  // A GL failure: off for this game with reason "gl".
  void fail_gl();

  // Emulator thread, a new real frame ready at now_ns at normal speed.
  // can_generate: a previous real frame of the same size is kept.
  Show on_real(int64_t now_ns, bool can_generate);
  // A real frame is held back (shown at the next vsync without a frame).
  bool holding() const;
  // The held real frame was handed to Flutter at now_ns.
  void held_shown(int64_t now_ns);
  // A picture that is not a fresh frame (repaint, rewind, fast-forward)
  // replaced the held one: nothing is held and nothing generated from it.
  void drop_held();
  // GPU time of a generated frame in ms.
  void gpu_ms(double ms);
  // GL set-up (stock preset, filter programs) that ran while the game was
  // running, in ms: a stall the player sees (frame_generation_setup_ms).
  void setup_ms(double ms);
  // New game: counters, samples and a latency/GL fallback are cleared.
  void reset();

  // Gate limits in ms for the current refresh.
  double cost_limit_ms() const;
  // "<mode> <reason or -> <p95 added ms> <limit ms>" (desktop.h).
  std::string status() const;
  // The metrics fields, without braces: `"frame_generation":1,...`.
  std::string metrics_fields() const;

  // Real frames between gate checks and the window each check looks at.
  static constexpr int kCheckEvery = 60;
  static constexpr int kWindow = 120;
  // Composite frames after the post (tools/rig/desktop_latency.py).
  static constexpr int kCompositeFrames = 2;
  static constexpr double kTargetMs = 50.0;  // CLAUDE.md §1
  static constexpr double kCostSlackMs = 2.0;
  // Below this many refreshes per game frame there is no 2x.
  static constexpr double kMinRatio = 1.98;

 private:
  void check_gate_locked();
  void update_mode_locked();

  mutable std::mutex mtx_;
  int want_ = 0;
  int mode_ = 0;
  std::string off_;       // "", "refresh", "latency", "gl"
  bool failed_ = false;   // latency or gl: off until reset()
  std::string fail_reason_;
  double refresh_hz_ = 60, fps_ = 60;
  Context context_;

  bool holding_ = false;
  int64_t held_ready_ns_ = 0;
  double last_gpu_ms_ = 0;
  double setup_ms_ = 0;  // longest set-up during play this game
  int since_check_ = 0;
  double fail_added_ = 0, fail_limit_ = 0;

  std::vector<double> added_, gpu_;  // rings of kWindow and 256
  size_t added_next_ = 0, gpu_next_ = 0;
  std::vector<double> added_all_;    // metrics: last 256
  size_t added_all_next_ = 0;
  uint64_t generated_ = 0, skipped_ = 0;
};

// p (0-100) percentile of v (nearest rank); 0 for an empty one.
double percentile(std::vector<double> v, double p);

}  // namespace dena

#endif
