// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/frame-generation.md (acceptance tests, host, no GL)
#include <cstdio>
#include <cstdlib>
#include <string>

#include "frame_gen_pacer.h"

static int g_failed = 0;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      g_failed++;                                                 \
    }                                                             \
  } while (0)

using namespace dena;

static bool has(const std::string &s, const std::string &part) {
  return s.find(part) != std::string::npos;
}

// What a refresh-driven platform does: per vsync either a new real frame
// (generated now, real held) or, with none, the held real frame. Returns
// the pictures shown as a string: g generated, r real at once, h held real,
// . nothing new.
static std::string run(FrameGenPacer &p, double hz, double fps, int vsyncs, double hold_ms = -1) {
  std::string shown;
  const double period = 1000.0 / hz, frame = 1000.0 / fps;
  double next_due = 0;
  for (int v = 0; v < vsyncs; v++) {
    const double t = v * period;
    int due = 0;
    while (t + 2 >= next_due && due < 3) {
      due++;
      next_due += frame;
    }
    const int64_t ns = int64_t(t * 1e6);
    if (due) {
      shown += p.on_real(ns, true) == FrameGenPacer::kShowGenerated ? 'g' : 'r';
    } else if (p.holding()) {
      p.held_shown(hold_ms < 0 ? ns : int64_t((t - period + hold_ms) * 1e6));
      shown += 'h';
    } else {
      shown += '.';
    }
  }
  return shown;
}

static void test_cadence() {
  FrameGenPacer p;
  p.set_want(1);
  p.configure(120, 60);
  CHECK(p.mode() == 1 && p.off_reason().empty());
  CHECK(run(p, 120, 60, 8) == "ghghghgh");
  // 144 Hz: the held frame stays on screen for the extra vsyncs; one
  // generated frame per real frame.
  p.reset();
  const std::string s = run(p, 144, 60, 24);
  size_t g = 0, h = 0, r = 0;
  for (char c : s) g += c == 'g', h += c == 'h', r += c == 'r';
  CHECK(g == 10 && h == 10 && r == 0);
  CHECK(s.substr(0, 5) == "gh.gh");
  // 240 Hz: g h . .
  p.reset();
  CHECK(run(p, 240, 60, 8) == "gh..gh..");
}

static void test_late_frame() {
  FrameGenPacer p;
  p.set_want(2);
  p.configure(120, 60);
  CHECK(p.on_real(0, true) == FrameGenPacer::kShowGenerated);
  CHECK(p.holding());
  // A second real frame before an idle vsync: no generated frame, the held
  // one is dropped and the new one shows at once.
  CHECK(p.on_real(8000000, true) == FrameGenPacer::kShowReal);
  CHECK(!p.holding());
  CHECK(has(p.metrics_fields(), "\"generated_skipped\":1"));
  // No previous frame (first frame, size change): shown as it is.
  CHECK(p.on_real(16000000, false) == FrameGenPacer::kShowReal);
  CHECK(!p.holding());
}

static void test_drop_held() {
  FrameGenPacer p;
  p.set_want(1);
  p.configure(120, 60);
  CHECK(p.on_real(0, true) == FrameGenPacer::kShowGenerated);
  p.drop_held();  // pause, rewind, fast-forward, a repaint
  CHECK(!p.holding());
  CHECK(p.on_real(16000000, true) == FrameGenPacer::kShowGenerated);
}

static void test_refresh_rule() {
  FrameGenPacer p;
  p.set_want(1);
  p.configure(60, 60);
  CHECK(p.mode() == 0 && p.off_reason() == "refresh");
  CHECK(p.on_real(0, true) == FrameGenPacer::kShowReal);
  p.configure(90, 60);  // Deck OLED
  CHECK(p.mode() == 0 && p.off_reason() == "refresh");
  p.configure(119.88, 60.0988);  // NES on a 119.88 Hz screen
  CHECK(p.mode() == 1);
  p.configure(100, 50);  // PAL at 100 Hz
  CHECK(p.mode() == 1);
  p.configure(118, 60);  // 1.97x
  CHECK(p.mode() == 0);
  // The want survives; back on a fast screen it applies again.
  p.configure(144, 60);
  CHECK(p.mode() == 1);
  p.set_want(0);
  CHECK(p.mode() == 0 && p.off_reason().empty());
  p.set_want(7);
  CHECK(p.want() == 0);
}

static void test_cost_gate() {
  FrameGenPacer p;
  p.set_want(1);
  p.configure(120, 60);
  CHECK(p.cost_limit_ms() > 10.3 && p.cost_limit_ms() < 10.4);
  // A held frame shown one refresh later plus 1 ms of GPU: passes.
  p.gpu_ms(1.0);
  run(p, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(p.mode() == 1);
  CHECK(has(p.status(), "1 - "));
  // 4 ms of GPU on top of the hold: over 10.3 ms, off for this game.
  p.gpu_ms(4.0);
  run(p, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(p.mode() == 0 && p.off_reason() == "latency");
  CHECK(has(p.status(), "0 latency 12.3 10.3"));
  CHECK(p.on_real(0, true) == FrameGenPacer::kShowReal);
  // A new game starts again.
  p.reset();
  CHECK(p.mode() == 1 && p.off_reason().empty());
}

static void test_total_gate() {
  // 30 ms post + 2 x 8.3 composite = 46.7 ms without frame generation; the
  // 8.3 ms hold takes it over 50 ms.
  FrameGenPacer p;
  p.set_want(1);
  p.configure(120, 60);
  int run_ahead = 0;
  p.set_context([&](double *in, int *ra) {
    *in = 30;
    *ra = run_ahead;
  });
  run(p, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(p.mode() == 0 && p.off_reason() == "latency");
  CHECK(has(p.status(), "0 latency 8.3 3.3"));
  // With one frame of run-ahead (-16.7 ms) the hold is paid for.
  p.reset();
  run_ahead = 1;
  run(p, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(p.mode() == 1);
  // Already over 50 ms without it: frame generation is not what breaks it.
  FrameGenPacer q;
  q.set_want(1);
  q.configure(120, 60);
  q.set_context([](double *in, int *ra) {
    *in = 45;
    *ra = 0;
  });
  run(q, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(q.mode() == 1);
  // No input samples: only the cost rule.
  FrameGenPacer n;
  n.set_want(2);
  n.configure(120, 60);
  n.set_context([](double *in, int *) { *in = -1; });
  run(n, 120, 60, 2 * FrameGenPacer::kWindow + 4);
  CHECK(n.mode() == 2);
}

static void test_gl_failure() {
  FrameGenPacer p;
  p.set_want(1);
  p.configure(120, 60);
  p.fail_gl();
  CHECK(p.mode() == 0 && p.off_reason() == "gl");
  p.set_want(2);  // stays off for this game
  CHECK(p.mode() == 0 && p.off_reason() == "gl");
  CHECK(has(p.status(), "0 gl "));
}

static void test_metrics() {
  FrameGenPacer p;
  std::string m = p.metrics_fields();
  CHECK(has(m, "\"frame_generation\":0,\"frame_generation_want\":0,\"frame_generation_off\":\"\""));
  CHECK(has(m, "\"frame_generation_added_ms\":null"));
  CHECK(has(m, "\"generated_frames\":0"));
  CHECK(has(m, "\"display_hz\":60.00"));
  CHECK(has(m, "\"frame_generation_setup_ms\":0.0"));
  p.set_want(1);
  p.configure(144, 60);
  p.gpu_ms(0.5);
  run(p, 144, 60, 12);
  m = p.metrics_fields();
  CHECK(has(m, "\"frame_generation\":1,\"frame_generation_want\":1"));
  CHECK(has(m, "\"frame_generation_added_ms\":{\"p50\":"));
  CHECK(has(m, "\"frame_generation_gpu_ms\":{\"p50\":0.50"));
  CHECK(has(m, "\"generated_frames\":5"));
  CHECK(has(m, "\"display_hz\":144.00"));
  // GL set-up inside a running game (the longest is kept); a new game clears it.
  p.setup_ms(42.25);
  p.setup_ms(3);
  CHECK(has(p.metrics_fields(), "\"frame_generation_setup_ms\":42.2"));
  p.reset();
  CHECK(has(p.metrics_fields(), "\"frame_generation_setup_ms\":0.0"));
}

static void test_percentile() {
  CHECK(percentile({}, 95) == 0);
  CHECK(percentile({3, 1, 2}, 50) == 2);
  std::vector<double> v;
  for (int i = 1; i <= 100; i++) v.push_back(i);
  CHECK(percentile(v, 95) == 95);
  CHECK(percentile(v, 100) == 100);
}

int main() {
  test_cadence();
  test_late_frame();
  test_drop_held();
  test_refresh_rule();
  test_cost_gate();
  test_total_gate();
  test_gl_failure();
  test_metrics();
  test_percentile();
  if (g_failed) {
    std::fprintf(stderr, "%d failure(s)\n", g_failed);
    return 1;
  }
  std::printf("frame_gen_pacer_tests: OK\n");
  return 0;
}
