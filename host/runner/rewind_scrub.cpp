// SPDX-License-Identifier: GPL-3.0-or-later
// Long rewind: the rewind budget and scrubbing the buffer while paused.
// Spec: docs/specs/rewind.md (Long rewind)
#include <algorithm>
#include <cstdint>

#include "runner.h"

namespace dena {

namespace {

// Deltas one scrub step applies before it shows a picture and lets other
// commands run; a long jump continues in further steps.
constexpr size_t kScrubStepBytes = 48u << 20;

}  // namespace

void Runner::set_rewind_budget(size_t bytes) {
  run_on_emu([&] {
    if (bytes == rewind_budget_) return;
    rewind_budget_ = bytes;
    if (core_) reset_rewind();
  });
}

Runner::RewindInfo Runner::rewind_info() {
  RewindInfo info;
  run_on_emu([&] {
    if (!rewind_) return;
    info.count = dena_rewind_count(rewind_);
    info.position = dena_rewind_position(rewind_);
    info.bytes = dena_rewind_bytes(rewind_);
    info.budget = rewind_budget_;
    info.fps = av_.fps > 0 ? av_.fps : 60.0;
  });
  return info;
}

bool Runner::begin_scrub(RewindInfo *info) {
  bool ok = false;
  run_on_emu([&] {
    if (!core_ || !rewind_ || !rewind_enabled_ || hardcore_ || !paused_) return;
    if (!scrubbing_) {
      // The live point is up to an interval newer than the last capture:
      // capture it so cancelling returns to exactly where the game paused.
      const size_t size = dena_core_state_size(core_);
      if (size != rewind_state_.size()) rewind_state_.assign(size, 0);
      if (!size || dena_core_save_state(core_, rewind_state_.data(), size) != 0 ||
          dena_rewind_push(rewind_, rewind_state_.data(), size) != 0)
        return;
      scrubbing_ = true;
    }
    scrub_target_ = dena_rewind_position(rewind_);
    ok = true;
  });
  if (ok && info) *info = rewind_info();
  return ok;
}

void Runner::scrub_to(size_t position) {
  scrub_target_ = position;
  if (scrub_queued_.exchange(true)) return;  // the queued step reads the newest target
  {
    std::lock_guard<std::mutex> lk(cmd_mtx_);
    cmds_.push_back([this] { scrub_step(); });
  }
  platform_->wake();
}

// Emulator thread.
void Runner::scrub_step() {
  scrub_queued_ = false;
  if (!scrubbing_ || !rewind_) return;
  const size_t target = scrub_target_;
  if (dena_rewind_seek(rewind_, target, kScrubStepBytes, rewind_state_.data(),
                       rewind_state_.size()) != 0)
    return;
  show_rewind_state();
  repaint();
  // Not there yet (a long jump): go on after the commands queued meanwhile.
  if (dena_rewind_position(rewind_) != std::min(target, dena_rewind_count(rewind_)))
    scrub_to(scrub_target_);
}

void Runner::end_scrub(bool keep) {
  run_on_emu([&] {
    if (!scrubbing_ || !rewind_) {
      scrubbing_ = false;
      return;
    }
    scrubbing_ = false;
    scrub_queued_ = false;
    run_ahead_.invalidate();  // the state moved (run-ahead.md)
    if (keep) {
      // The core already holds the state at the cursor (scrub_step reloads it).
      dena_rewind_keep(rewind_);
    } else if (dena_rewind_seek(rewind_, dena_rewind_count(rewind_), SIZE_MAX,
                                rewind_state_.data(), rewind_state_.size()) == 0) {
      show_rewind_state();
      repaint();
    }
    rewind_tick_ = 0;
    next_due_ns_ = 0;
  });
}

}  // namespace dena
