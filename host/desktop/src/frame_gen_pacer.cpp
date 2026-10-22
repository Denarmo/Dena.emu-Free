// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/frame-generation.md (Timing, Latency gate, Metrics)
#include "frame_gen_pacer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace dena {

namespace {

void push(std::vector<double> *ring, size_t *next, size_t cap, double v) {
  if (ring->size() < cap) {
    ring->push_back(v);
  } else {
    (*ring)[*next] = v;
    *next = (*next + 1) % cap;
  }
}

std::string fmt3(const std::vector<double> &s) {
  if (s.empty()) return "null";
  char t[96];
  std::snprintf(t, sizeof t, "{\"p50\":%.2f,\"p95\":%.2f,\"max\":%.2f}", percentile(s, 50),
                percentile(s, 95), *std::max_element(s.begin(), s.end()));
  return t;
}

}  // namespace

double percentile(std::vector<double> v, double p) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  size_t rank = size_t(std::ceil(p / 100.0 * double(v.size())));
  return v[std::min(v.size() - 1, rank ? rank - 1 : 0)];
}

void FrameGenPacer::set_want(int mode) {
  std::lock_guard<std::mutex> lk(mtx_);
  want_ = mode == 1 || mode == 2 ? mode : 0;
  update_mode_locked();
}

int FrameGenPacer::want() const {
  std::lock_guard<std::mutex> lk(mtx_);
  return want_;
}

void FrameGenPacer::configure(double refresh_hz, double fps) {
  std::lock_guard<std::mutex> lk(mtx_);
  if (refresh_hz > 0) refresh_hz_ = refresh_hz;
  if (fps > 0) fps_ = fps;
  update_mode_locked();
}

void FrameGenPacer::set_context(Context c) {
  std::lock_guard<std::mutex> lk(mtx_);
  context_ = std::move(c);
}

void FrameGenPacer::update_mode_locked() {
  if (!want_) {
    mode_ = 0;
    off_.clear();
  } else if (failed_) {
    mode_ = 0;
    off_ = fail_reason_;
  } else if (refresh_hz_ < kMinRatio * fps_) {
    mode_ = 0;
    off_ = "refresh";
  } else {
    mode_ = want_;
    off_.clear();
  }
  if (!mode_) holding_ = false;
}

int FrameGenPacer::mode() const {
  std::lock_guard<std::mutex> lk(mtx_);
  return mode_;
}

std::string FrameGenPacer::off_reason() const {
  std::lock_guard<std::mutex> lk(mtx_);
  return off_;
}

void FrameGenPacer::fail_gl() {
  std::lock_guard<std::mutex> lk(mtx_);
  failed_ = true;
  fail_reason_ = "gl";
  update_mode_locked();
}

FrameGenPacer::Show FrameGenPacer::on_real(int64_t now_ns, bool can_generate) {
  std::lock_guard<std::mutex> lk(mtx_);
  if (!mode_) return kShowReal;
  if (holding_) {
    // The real frame is late (two in one vsync, or no idle vsync between
    // them): drop the held one, no generated frame (spec, Timing).
    holding_ = false;
    skipped_++;
    return kShowReal;
  }
  if (!can_generate) return kShowReal;
  holding_ = true;
  held_ready_ns_ = now_ns;
  generated_++;
  return kShowGenerated;
}

bool FrameGenPacer::holding() const {
  std::lock_guard<std::mutex> lk(mtx_);
  return holding_;
}

void FrameGenPacer::held_shown(int64_t now_ns) {
  std::lock_guard<std::mutex> lk(mtx_);
  if (!holding_) return;
  holding_ = false;
  const double added = double(now_ns - held_ready_ns_) / 1e6 + last_gpu_ms_;
  push(&added_, &added_next_, kWindow, added);
  push(&added_all_, &added_all_next_, 256, added);
  if (++since_check_ >= kCheckEvery) {
    since_check_ = 0;
    check_gate_locked();
  }
}

void FrameGenPacer::drop_held() {
  std::lock_guard<std::mutex> lk(mtx_);
  holding_ = false;
}

void FrameGenPacer::gpu_ms(double ms) {
  if (ms < 0) return;
  std::lock_guard<std::mutex> lk(mtx_);
  last_gpu_ms_ = ms;
  push(&gpu_, &gpu_next_, 256, ms);
}

void FrameGenPacer::setup_ms(double ms) {
  std::lock_guard<std::mutex> lk(mtx_);
  setup_ms_ = std::max(setup_ms_, ms);
}

double FrameGenPacer::cost_limit_ms() const {
  return 1000.0 / refresh_hz_ + kCostSlackMs;
}

void FrameGenPacer::check_gate_locked() {
  if (!mode_ || added_.size() < size_t(kWindow)) return;
  const double added = percentile(added_, 95);
  const double refresh_ms = 1000.0 / refresh_hz_;
  double limit = refresh_ms + kCostSlackMs;
  bool fail = added > limit;
  if (!fail && context_) {
    double input = -1;
    int run_ahead = 0;
    context_(&input, &run_ahead);
    if (input >= 0) {
      // As desktop_latency.py: post + composite - run-ahead, then the hold.
      const double base = input + kCompositeFrames * refresh_ms - run_ahead * 1000.0 / fps_;
      if (base < kTargetMs && base + added >= kTargetMs) {
        fail = true;
        limit = kTargetMs - base;
      }
    }
  }
  if (!fail) return;
  failed_ = true;
  fail_reason_ = "latency";
  fail_added_ = added;
  fail_limit_ = limit;
  update_mode_locked();
}

void FrameGenPacer::reset() {
  std::lock_guard<std::mutex> lk(mtx_);
  failed_ = false;
  holding_ = false;
  last_gpu_ms_ = 0;
  setup_ms_ = 0;
  since_check_ = 0;
  fail_added_ = fail_limit_ = 0;
  added_.clear();
  gpu_.clear();
  added_all_.clear();
  added_next_ = gpu_next_ = added_all_next_ = 0;
  generated_ = skipped_ = 0;
  update_mode_locked();
}

std::string FrameGenPacer::status() const {
  std::lock_guard<std::mutex> lk(mtx_);
  double added = off_ == "latency" ? fail_added_ : percentile(added_all_, 95);
  double limit = off_ == "latency" ? fail_limit_ : 1000.0 / refresh_hz_ + kCostSlackMs;
  char t[96];
  std::snprintf(t, sizeof t, "%d %s %.1f %.1f", mode_, off_.empty() ? "-" : off_.c_str(), added,
                limit);
  return t;
}

std::string FrameGenPacer::metrics_fields() const {
  std::lock_guard<std::mutex> lk(mtx_);
  char t[512];
  std::snprintf(t, sizeof t,
                "\"frame_generation\":%d,\"frame_generation_want\":%d,"
                "\"frame_generation_off\":\"%s\",\"frame_generation_added_ms\":%s,"
                "\"frame_generation_gpu_ms\":%s,\"generated_frames\":%llu,"
                "\"generated_skipped\":%llu,\"display_hz\":%.2f,"
                "\"frame_generation_setup_ms\":%.1f",
                mode_, want_, off_.c_str(), mode_ ? fmt3(added_all_).c_str() : "null",
                fmt3(gpu_).c_str(), (unsigned long long)generated_, (unsigned long long)skipped_,
                refresh_hz_, setup_ms_);
  return t;
}

}  // namespace dena
