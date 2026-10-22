// SPDX-License-Identifier: GPL-3.0-or-later
// Shared runner acceptance tests (docs/specs/shared-runner.md) with the test
// core and a fake platform: vsyncs are driven by hand, audio is a fake output.
// Usage: runner_tests <testcore> <tmpdir>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "runner.h"

namespace {

int failures = 0;

#define CHECK(cond)                                               \
  do {                                                            \
    if (!(cond)) {                                                \
      std::fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                 \
    }                                                             \
  } while (0)

class FakePlatform : public dena::RunnerPlatform {
 public:
  std::vector<uint64_t> shown;  // hash of every frame drawn (emulator thread)
  bool surface = true;
  int audio_rate = 48000;

  void wait(bool) override {
    std::unique_lock<std::mutex> lk(mtx_);
    cv_.wait_for(lk, std::chrono::milliseconds(20), [this] { return woken_; });
    woken_ = false;
  }
  void wake() override {
    std::lock_guard<std::mutex> lk(mtx_);
    woken_ = true;
    cv_.notify_all();
  }
  bool has_surface() override { return surface; }
  bool gpu = false;  // a GPU platform (hw-render.md); frames show as hash 0
  bool gpu_started = false;
  bool start_gpu(unsigned, unsigned, bool, bool) override { return gpu_started = gpu; }
  bool gpu_ready() override { return gpu_started; }
  uintptr_t gpu_framebuffer() override { return 0; }
  void *gl_proc_address(const char *) override { return nullptr; }
  void stop_gpu() override { gpu_started = false; }
  bool draw_software(const dena_frame &f, int) override {
    shown.push_back(dena_frame_hash(&f));
    return true;
  }
  bool draw_gpu(unsigned, unsigned, bool, int) override {
    shown.push_back(0);
    return true;
  }
  bool read_pixels(unsigned, unsigned, bool, std::vector<uint32_t> &) override { return false; }
  int open_audio() override { return audio_rate; }
  bool start_audio() override { return true; }
  void pause_audio() override {}
  void close_audio() override {}

 private:
  std::mutex mtx_;
  std::condition_variable cv_;
  bool woken_ = false;
};

const int64_t kPeriod = 16666667;  // the test core runs at 60 fps
const int kRight = 1 << 7;         // RETRO_DEVICE_ID_JOYPAD_RIGHT
const int kA = 1 << 8;             // RETRO_DEVICE_ID_JOYPAD_A

struct Fixture {
  FakePlatform fake;
  dena::Runner runner{&fake};
  int64_t t = 1000000000LL;

  void vsync(int64_t step) {
    t += step;
    runner.run_on_emu([&] { runner.on_vsync(t); });
  }
  unsigned long long frames() {
    unsigned long long n = 0;
    std::sscanf(runner.metrics_json().c_str(), "{\"frames\":%llu", &n);
    return n;
  }
  double audio_ms() {
    std::string m = runner.metrics_json();
    double ms = -1;
    size_t at = m.find("\"audio_buffer_ms\":");
    if (at != std::string::npos) std::sscanf(m.c_str() + at, "\"audio_buffer_ms\":%lf", &ms);
    return ms;
  }
  uint64_t last() {
    uint64_t h = 0;
    runner.run_on_emu([&] { h = fake.shown.empty() ? 0 : fake.shown.back(); });
    return h;
  }
};

std::string g_core, g_dir, g_rom;

bool exists(const std::string &p) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (f) std::fclose(f);
  return f != nullptr;
}

void write_file(const std::string &p, const char *data) {
  FILE *f = std::fopen(p.c_str(), "wb");
  if (!f) return;
  std::fputs(data, f);
  std::fclose(f);
}

int start(Fixture &fx, const std::string &name) {
  return fx.runner.start(g_core, g_rom, g_dir, g_dir + "/" + name + ".srm",
                         g_dir + "/" + name + ".state");
}

void test_lifecycle() {
  std::remove((g_dir + "/life.state").c_str());
  std::remove((g_dir + "/life.srm").c_str());
  {
    Fixture fx;
    CHECK(start(fx, "life") == dena::Runner::kStartFresh);
    CHECK(start(fx, "life") == dena::Runner::kStartError);  // already running
    for (int i = 0; i < 5; i++) fx.vsync(kPeriod);
    fx.runner.stop();
    CHECK(exists(g_dir + "/life.state"));
  }
  {
    Fixture fx;
    CHECK(start(fx, "life") == dena::Runner::kStartResumed);
    fx.runner.stop();
  }
  write_file(g_dir + "/life.state", "not a state");
  std::remove((g_dir + "/life.state.bad").c_str());
  {
    Fixture fx;
    CHECK(start(fx, "life") == dena::Runner::kStartBadState);
    CHECK(exists(g_dir + "/life.state.bad"));
    fx.runner.stop();
  }
  {
    Fixture fx;
    CHECK(fx.runner.start(g_dir + "/no_such_core", g_rom, g_dir, "", "") ==
          dena::Runner::kStartError);
    CHECK(!fx.runner.error().empty());
  }
}

// Frames run in one second of vsyncs at the given display period.
unsigned long long frames_per_second(int64_t vsync_period) {
  Fixture fx;
  start(fx, "pace");
  int n = int(1000000000LL / vsync_period);
  for (int i = 0; i < n; i++) fx.vsync(vsync_period);
  unsigned long long f = fx.frames();
  fx.runner.stop();
  return f;
}

void test_pacing() {
  for (int64_t p : {kPeriod, int64_t(11111111), int64_t(8333333)}) {
    unsigned long long f = frames_per_second(p);
    if (f < 59 || f > 61) std::fprintf(stderr, "period %lld: %llu frames\n", (long long)p, f);
    CHECK(f >= 59 && f <= 61);
  }
  Fixture fx;
  start(fx, "pace");
  fx.vsync(kPeriod);
  unsigned long long f0 = fx.frames();
  fx.vsync(3 * kPeriod);  // a short hitch catches up (at most 3 per vsync)
  CHECK(fx.frames() - f0 == 3);
  f0 = fx.frames();
  fx.vsync(500000000LL);  // a long stall resyncs instead of racing
  CHECK(fx.frames() - f0 == 1);
  fx.runner.set_speed(3);
  f0 = fx.frames();
  for (int i = 0; i < 10; i++) fx.vsync(kPeriod);
  CHECK(fx.frames() - f0 == 30);
  fx.runner.set_speed(99);  // clamped to 8
  f0 = fx.frames();
  fx.vsync(kPeriod);
  CHECK(fx.frames() - f0 == 8);
  fx.runner.set_speed(1);
  fx.fake.surface = false;  // no surface: nothing runs
  f0 = fx.frames();
  fx.vsync(kPeriod);
  CHECK(fx.frames() == f0);
  fx.runner.stop();
}

void test_pause() {
  std::remove((g_dir + "/pause.state").c_str());
  std::remove((g_dir + "/pause.srm").c_str());
  Fixture fx;
  start(fx, "pause");
  fx.runner.set_buttons(0, 1 << 3, dena::now_ns());  // Start: changes battery RAM
  fx.vsync(kPeriod);
  fx.runner.set_buttons(0, 0, dena::now_ns());
  fx.vsync(kPeriod);
  fx.runner.pause();
  CHECK(fx.runner.paused());
  CHECK(exists(g_dir + "/pause.state"));
  CHECK(exists(g_dir + "/pause.srm"));
  unsigned long long f0 = fx.frames();
  fx.vsync(kPeriod);
  CHECK(fx.frames() == f0);
  fx.runner.resume();
  fx.vsync(kPeriod);
  CHECK(fx.frames() == f0 + 1);
  fx.runner.stop();
}

void test_rewind() {
  Fixture fx;
  start(fx, "rewind");
  for (int i = 0; i < 40; i++) fx.vsync(kPeriod);
  std::vector<uint64_t> history;
  fx.runner.run_on_emu([&] { history = fx.fake.shown; });
  auto seen = [&](uint64_t h) {
    for (uint64_t x : history)
      if (x == h) return true;
    return false;
  };
  uint64_t newest = history.back();
  fx.runner.set_rewinding(true);
  CHECK(fx.runner.rewinding());
  for (int i = 0; i < 8; i++) fx.vsync(kPeriod);
  uint64_t back = fx.last();
  CHECK(back != newest && seen(back));
  fx.runner.set_rewinding(false);
  fx.vsync(kPeriod);
  CHECK(seen(fx.last()));  // resumed from the captured point
  // L2 hold: a gamepad's L2 rewinds only when configured.
  fx.runner.set_buttons(0, 1 << 12, dena::now_ns());
  CHECK(!fx.runner.rewinding());
  fx.runner.configure_rewind(true, true);
  CHECK(fx.runner.rewinding());
  fx.runner.set_buttons(0, 0, dena::now_ns());
  CHECK(!fx.runner.rewinding());
  fx.runner.stop();
}

// rewind.md, Long rewind: scrubbing while paused, then keep or cancel.
uint64_t frame_after_pause(bool scrub_and_cancel) {
  // A fresh boot each time (no auto-saved state to resume).
  std::remove((g_dir + "/scrub_pause.state").c_str());
  Fixture fx;
  start(fx, "scrub_pause");
  fx.runner.set_rewind_budget(64u << 20);
  for (int i = 0; i < 31; i++) fx.vsync(kPeriod);
  fx.runner.pause();
  if (scrub_and_cancel) {
    dena::Runner::RewindInfo info;
    CHECK(fx.runner.begin_scrub(&info));
    fx.runner.scrub_to(info.position / 2);
    fx.runner.scrub_to(2);
    fx.runner.end_scrub(false);
  }
  fx.runner.resume();
  fx.vsync(kPeriod);
  uint64_t h = fx.last();
  fx.runner.stop();
  return h;
}

void test_scrub() {
  std::remove((g_dir + "/scrub.state").c_str());
  Fixture fx;
  start(fx, "scrub");
  dena::Runner::RewindInfo info;
  CHECK(!fx.runner.begin_scrub(&info));  // only while paused
  fx.runner.set_rewind_budget(256u << 20);
  for (int i = 0; i < 40; i++) fx.vsync(kPeriod);
  info = fx.runner.rewind_info();
  CHECK(info.budget == 256u << 20 && info.fps > 0);
  CHECK(info.count >= 18 && info.position == info.count);
  std::vector<uint64_t> history;
  fx.runner.run_on_emu([&] { history = fx.fake.shown; });
  auto index_of = [&](uint64_t h) {
    for (size_t i = 0; i < history.size(); i++)
      if (history[i] == h) return int(i);
    return -1;
  };
  fx.runner.pause();
  CHECK(fx.runner.begin_scrub(&info));
  CHECK(info.position == info.count && info.count >= 19);
  const size_t newest = info.count;
  fx.runner.scrub_to(newest - 10);
  fx.runner.run_on_emu([] {});  // the scrub step ran before this
  const int far = index_of(fx.last());
  CHECK(far >= 0);
  fx.runner.scrub_to(newest - 4);  // forward again
  fx.runner.run_on_emu([] {});
  const int near = index_of(fx.last());
  CHECK(near > far);
  CHECK(fx.runner.rewind_info().count == newest);  // nothing dropped yet
  fx.runner.scrub_to(newest - 10);
  fx.runner.end_scrub(true);
  CHECK(fx.runner.rewind_info().count == newest - 10);
  fx.runner.resume();
  fx.vsync(kPeriod);
  CHECK(index_of(fx.last()) == far);  // plays on from the kept point
  // A new budget starts an empty buffer.
  fx.runner.set_rewind_budget(128u << 20);
  CHECK(fx.runner.rewind_info().count == 0);
  fx.runner.stop();
  // Cancelling returns to exactly where the game paused.
  CHECK(frame_after_pause(true) == frame_after_pause(false));
}

void set_env(const char *k, const char *v) {
#ifdef _WIN32
  _putenv_s(k, v ? v : "");
#else
  if (v) setenv(k, v, 1);
  else unsetenv(k);
#endif
}

std::string read_file(const std::string &p) {
  std::string out;
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return out;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
  std::fclose(f);
  return out;
}

// rewind.md: a state too large for the budget turns rewind off; L2 is then
// an ordinary button and the game keeps running.
void test_heavy_state() {
  set_env("DENA_TEST_STATE_PAD", "20000000");
  Fixture fx;
  start(fx, "heavy");
  fx.runner.set_rewind_budget(1u << 30);  // a big budget doesn't lift the cap
  for (int i = 0; i < 5; i++) fx.vsync(kPeriod);
  fx.runner.set_rewinding(true);
  CHECK(!fx.runner.rewinding());
  fx.runner.set_rewinding(false);
  fx.runner.configure_rewind(true, true);
  fx.runner.set_buttons(0, 1 << 12, dena::now_ns());
  CHECK(!fx.runner.rewinding());
  unsigned long long before = fx.frames();
  for (int i = 0; i < 3; i++) fx.vsync(kPeriod);
  CHECK(fx.frames() > before);
  fx.runner.stop();
  set_env("DENA_TEST_STATE_PAD", nullptr);
}

// rewind.md: the rewind capture runs after the frame is posted, so a slow
// state (melonDS: 6.5 MB) never sits between an input and its frame.
void test_capture_after_post() {
  set_env("DENA_TEST_SAVE_MS", "12");
  Fixture fx;
  start(fx, "slowsave");
  fx.runner.set_rewind_budget(64u << 20);
  for (int i = 0; i < 4; i++) fx.vsync(kPeriod);
  int held = 0;
  for (int i = 0; i < 24; i++) {
    fx.runner.set_buttons(0, held ^= kRight, dena::now_ns());
    fx.vsync(kPeriod);
  }
  double p95 = fx.runner.input_p95_ms();
  CHECK(p95 >= 0 && p95 < 8);
  // Rewind still captured: stepping back works.
  fx.runner.set_rewinding(true);
  CHECK(fx.runner.rewinding());
  fx.runner.set_rewinding(false);
  fx.runner.stop();
  set_env("DENA_TEST_SAVE_MS", nullptr);
}

// game-session.md: a GPU core that refuses states during its boot resumes a
// few frames in, and the saved state is not overwritten before that.
void test_late_state() {
  set_env("DENA_TEST_HW", "1");
  std::string state = g_dir + "/late.state";
  std::remove(state.c_str());
  std::remove((state + ".bad").c_str());
  {
    Fixture fx;
    fx.fake.gpu = true;
    CHECK(start(fx, "late") == dena::Runner::kStartFresh);
    for (int i = 0; i < 10; i++) fx.vsync(kPeriod);
    fx.runner.stop();
  }
  std::string saved = read_file(state);
  CHECK(!saved.empty());
  set_env("DENA_TEST_LATE_STATE", "3");
  {
    Fixture fx;  // stopped before the core accepts the state
    fx.fake.gpu = true;
    CHECK(start(fx, "late") == dena::Runner::kStartResumed);
    fx.runner.stop();
    CHECK(read_file(state) == saved);
  }
  {
    Fixture fx;  // accepted once the core is ready
    fx.fake.gpu = true;
    CHECK(start(fx, "late") == dena::Runner::kStartResumed);
    for (int i = 0; i < 6; i++) fx.vsync(kPeriod);
    fx.runner.stop();
    CHECK(!exists(state + ".bad"));
    CHECK(read_file(state) != saved);  // saved again after resuming
  }
  set_env("DENA_TEST_LATE_STATE", nullptr);
  set_env("DENA_TEST_HW", nullptr);
}

void test_states_and_cheats() {
  Fixture fx;
  start(fx, "slot");
  for (int i = 0; i < 5; i++) fx.vsync(kPeriod);
  std::string slot = g_dir + "/slot1.state", png = g_dir + "/slot1.png";
  CHECK(fx.runner.save_state(slot, png) == 0);
  CHECK(exists(png));
  fx.vsync(kPeriod);
  uint64_t after_save = fx.last();
  for (int i = 0; i < 10; i++) fx.vsync(kPeriod);
  CHECK(fx.runner.load_state(slot) == 0);
  fx.vsync(kPeriod);
  CHECK(fx.last() == after_save);
  CHECK(fx.runner.load_state(g_dir + "/no_such.state") != 0);

  CHECK(fx.runner.load_state(slot) == 0);
  fx.runner.set_cheats({"REDSQUARE"});
  fx.vsync(kPeriod);
  CHECK(fx.last() != after_save);
  fx.runner.set_cheats({});
  CHECK(fx.runner.load_state(slot) == 0);
  fx.vsync(kPeriod);
  CHECK(fx.last() == after_save);
  CHECK(fx.runner.screenshot(g_dir + "/shot.png") == 0);
  CHECK(fx.runner.pixel(0, 0) >= 0);
  CHECK(fx.runner.pixel(-1, 0) == -1);
  fx.runner.stop();
}

// The RAM mailbox (pico8-launcher-cart.md): writes go in before a frame and
// the watched window is read back after it.
void test_ram_mailbox() {
  Fixture fx;
  start(fx, "ram");
  uint8_t got[2] = {0, 0};
  CHECK(!fx.runner.read_ram(got, 2));  // nothing watched yet
  fx.runner.watch_ram(0, 2);
  const uint8_t v = 41;
  fx.runner.write_ram(0, &v, 1);
  fx.runner.write_ram(255, got, 2);  // past the end: dropped
  fx.vsync(kPeriod);
  CHECK(fx.runner.read_ram(got, 2));
  CHECK(got[0] == 41 && got[1] == 42);
  CHECK(!fx.runner.read_ram(got, 3));  // larger than the window
  fx.runner.watch_ram(250, 10);         // window past the end: no snapshot
  fx.vsync(kPeriod);
  CHECK(!fx.runner.read_ram(got, 1));
  fx.runner.stop();
}

void test_audio() {
  Fixture fx;
  start(fx, "audio");
  double ms0 = fx.audio_ms();
  CHECK(ms0 > 30);  // prefilled
  for (int i = 0; i < 5; i++) fx.vsync(kPeriod);
  double ms1 = fx.audio_ms();
  CHECK(ms1 > ms0);  // nobody reads the fake output, so the ring fills
  fx.runner.set_speed(4);
  for (int i = 0; i < 5; i++) fx.vsync(kPeriod);
  CHECK(fx.audio_ms() == ms1);  // muted while fast-forwarding
  std::vector<int16_t> out(480 * 2);
  fx.runner.read_audio(out.data(), 480);
  CHECK(fx.audio_ms() < ms1);
  fx.runner.stop();

  Fixture silent;
  silent.fake.audio_rate = 0;  // no audio device: the game still runs
  CHECK(start(silent, "audio") >= 0);
  silent.vsync(kPeriod);
  CHECK(silent.frames() == 1);
  silent.runner.stop();
}

// run-ahead.md: plays kFrames vsyncs with RIGHT held from frame `press`,
// after the audio probe's frames (run_ahead.h, held still); returns the hash
// shown after each of the kFrames vsyncs and the auto-save state.
struct Played {
  std::vector<uint64_t> shown;
  std::string state;
  double audio_ms = 0;
  std::string metrics;
};

const int kFrames = 20;

Played play(int mode, int frames, int press) {
  std::remove((g_dir + "/ahead.state").c_str());
  std::remove((g_dir + "/ahead.srm").c_str());
  Played out;
  Fixture fx;
  fx.runner.set_run_ahead(mode, frames);
  start(fx, "ahead");
  for (int k = 0; k < dena::kAudioProbeFrames; k++) fx.vsync(kPeriod);
  for (int k = 0; k < kFrames; k++) {
    if (k == press) fx.runner.set_buttons(0, kRight, dena::now_ns());
    fx.vsync(kPeriod);
    out.shown.push_back(fx.last());
  }
  out.audio_ms = fx.audio_ms();
  out.metrics = fx.runner.metrics_json();
  fx.runner.stop();
  out.state = read_file(g_dir + "/ahead.state");
  return out;
}

void test_run_ahead() {
  const int press = 8;
  Played plain = play(dena::kRunAheadOff, 0, press);
  CHECK(plain.metrics.find("\"run_ahead\":0}") != std::string::npos);
  for (int n = 1; n <= 3; n++) {
    // Run-ahead shows the frame plain play shows n vsyncs later, while the
    // real timeline (and its sound) stays the plain one.
    Played ra = play(dena::kRunAheadSingle, n, press);
    for (int k = 0; k + n < kFrames; k++)
      if (k >= press || k + n < press) CHECK(ra.shown[size_t(k)] == plain.shown[size_t(k + n)]);
    CHECK(ra.shown[size_t(press - 1)] != plain.shown[size_t(press - 1 + n)]);  // predicted
    CHECK(!ra.state.empty() && ra.state == plain.state);
    CHECK(ra.audio_ms == plain.audio_ms);
    CHECK(ra.metrics.find("\"run_ahead\":" + std::to_string(n) + "}") != std::string::npos);

    // Preemptive frames: the press takes effect as if it came n frames
    // earlier, on real frames.
    Played early = play(dena::kRunAheadOff, 0, press - n);
    Played pre = play(dena::kRunAheadPreemptive, n, press);
    for (int k = 0; k < kFrames; k++) {
      if (k >= press) CHECK(pre.shown[size_t(k)] == early.shown[size_t(k)]);
      else CHECK(pre.shown[size_t(k)] == plain.shown[size_t(k)]);
    }
    CHECK(!pre.state.empty() && pre.state == early.state);
  }
  // Cores without support run plain whatever the setting.
  CHECK(dena::run_ahead_core_limit(g_core) == 3);
}

// run-ahead.md, audio: the stereo samples played after each vsync, with
// input changes at `changes` (none: held from the start).
std::vector<uint64_t> audio_per_frame(int mode, int frames, const std::vector<int> &changes,
                                      std::string *metrics = nullptr) {
  std::remove((g_dir + "/sound.state").c_str());
  std::remove((g_dir + "/sound.srm").c_str());
  std::vector<uint64_t> out;
  Fixture fx;
  fx.runner.set_run_ahead(mode, frames);
  start(fx, "sound");
  int buttons = 0;
  uint64_t before = fx.runner.audio_samples_played();
  for (int k = 0; k < 150; k++) {
    for (int c : changes)
      if (k == c) fx.runner.set_buttons(0, buttons ^= kRight, dena::now_ns());
    fx.vsync(kPeriod);
    uint64_t now = fx.runner.audio_samples_played();
    out.push_back(now - before);
    before = now;
  }
  if (metrics) *metrics = fx.runner.metrics_json();
  fx.runner.stop();
  return out;
}

uint64_t total(const std::vector<uint64_t> &v) {
  uint64_t t = 0;
  for (uint64_t n : v) t += n;
  return t;
}

void test_run_ahead_audio() {
  // Sound leaves the test core in the frame that made it: every method and
  // depth plays exactly what plain play does, frame by frame, while presses
  // make preemptive replay and run-ahead predict.
  const std::vector<int> changes = {30, 70, 100, 101, 120};
  std::vector<uint64_t> plain = audio_per_frame(dena::kRunAheadOff, 0, changes);
  CHECK(plain.size() == 150 && plain[10] == 735 && total(plain) == 150 * 735);
  for (int mode : {int(dena::kRunAheadSingle), int(dena::kRunAheadPreemptive)}) {
    for (int n = 1; n <= 3; n++) {
      std::string m;
      CHECK(audio_per_frame(mode, n, changes, &m) == plain);
      CHECK(m.find("\"run_ahead_method\":" + std::to_string(mode) + ",") != std::string::npos);
    }
  }

  // A core that holds sound in a buffer its states do not keep and hands it
  // out in blocks (mGBA's GB path): run-ahead falls back to preemptive at
  // once, so held input plays exactly what plain play does.
  set_env("DENA_TEST_AUDIO_BLOCK", "512");
  std::vector<uint64_t> blocks = audio_per_frame(dena::kRunAheadOff, 0, {});
  CHECK(blocks[0] == 512 && blocks[1] == 512 && blocks[2] == 1024);
  for (int n = 1; n <= 3; n++) {
    std::string m;
    CHECK(audio_per_frame(dena::kRunAheadSingle, n, {}, &m) == blocks);
    CHECK(m.find("\"run_ahead_method\":1,\"run_ahead\":" + std::to_string(n) + "}") !=
          std::string::npos);
    CHECK(audio_per_frame(dena::kRunAheadPreemptive, n, {}) == blocks);
    // Each replay can shift its blocks by less than one; nothing piles up.
    for (int mode : {int(dena::kRunAheadSingle), int(dena::kRunAheadPreemptive)}) {
      long long diff = (long long)total(audio_per_frame(mode, n, changes)) -
                       (long long)total(audio_per_frame(dena::kRunAheadOff, 0, changes));
      CHECK(diff > -1024 && diff < 1024);
    }
  }
  set_env("DENA_TEST_AUDIO_BLOCK", nullptr);
}

// The same with a real core (runner_tests --audio, DENA_CORES_DIR): run-ahead
// mode with held input plays what plain play does on a frame-wise core, and
// falls back to preemptive (method 1) on a block-wise one such as mGBA's GB.
void test_core_audio(int method) {
  std::vector<uint64_t> plain = audio_per_frame(dena::kRunAheadOff, 0, {});
  for (int n = 1; n <= 3; n++) {
    std::string m;
    std::vector<uint64_t> ra = audio_per_frame(dena::kRunAheadSingle, n, {}, &m);
    CHECK(m.find("\"run_ahead_method\":" + std::to_string(method) + ",") != std::string::npos);
    CHECK(total(ra) > 0);
    // mGBA's GBA path smooths its reads with an average kept outside its
    // states, which hidden frames move by a few samples.
    for (size_t k = 0; k < ra.size(); k++)
      CHECK(ra[k] + 8 >= plain[k] && ra[k] <= plain[k] + 8);
  }
}


// What one frame and one state round trip cost on a core (ms, median of n),
// for the latency bench's notes.
void frame_costs(int n) {
  char err[256] = "";
  dena_core *c = dena_core_load(g_core.c_str(), err, sizeof err);
  // DENA_BENCH_OPTIONS="key=value;key=value": core options to compare.
  if (const char *opts = std::getenv("DENA_BENCH_OPTIONS")) {
    std::string all = opts;
    for (size_t at = 0; c && at < all.size();) {
      size_t end = all.find(';', at);
      if (end == std::string::npos) end = all.size();
      std::string kv = all.substr(at, end - at);
      size_t eq = kv.find('=');
      if (eq != std::string::npos)
        dena_core_set_option(c, kv.substr(0, eq).c_str(), kv.substr(eq + 1).c_str());
      at = end + 1;
    }
  }
  if (!c || dena_core_load_game(c, g_rom.c_str(), err, sizeof err) != 0) {
    std::fprintf(stderr, "cannot load: %s\n", err);
    failures++;
    return;
  }
  dena_core_set_hashing(c, 0);
  for (int k = 0; k < 120; k++) dena_core_run_frame(c);
  std::vector<double> run, size, save, load;
  auto ms = [](int64_t a, int64_t b) { return double(b - a) / 1e6; };
  std::vector<uint8_t> buf;
  for (int k = 0; k < n; k++) {
    int64_t t0 = dena::now_ns();
    dena_core_run_frame(c);
    int64_t t1 = dena::now_ns();
    size_t sz = dena_core_state_size(c);
    int64_t t2 = dena::now_ns();
    buf.resize(sz);
    dena_core_save_state(c, buf.data(), sz);
    int64_t t3 = dena::now_ns();
    dena_core_load_state(c, buf.data(), sz);
    int64_t t4 = dena::now_ns();
    run.push_back(ms(t0, t1));
    size.push_back(ms(t1, t2));
    save.push_back(ms(t2, t3));
    load.push_back(ms(t3, t4));
  }
  auto med = [](std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
  };
  std::printf("state %zu bytes; median ms: frame %.2f, state_size %.2f, save %.2f, load %.2f\n",
              buf.size(), med(run), med(size), med(save), med(load));
}

// desktop-shell.md, Latency, in software: plays a real core in real time
// (60 Hz vsyncs, no window, no sound device) while another thread flips A
// every ~250 ms at a random point between vsyncs, and appends the runner's
// metrics every second to <dir>/latency.jsonl for tools/rig/desktop_latency.py.
// Fails when frames post unevenly or an input waits over 1.5 periods.
void latency_bench(int mode, int frames, int seconds) {
  std::remove((g_dir + "/bench.state").c_str());
  std::remove((g_dir + "/bench.srm").c_str());
  Fixture fx;
  fx.runner.set_run_ahead(mode, frames);
  if (start(fx, "bench") != 0) {
    std::fprintf(stderr, "cannot start %s with %s\n", g_core.c_str(), g_rom.c_str());
    failures++;
    return;
  }
  std::FILE *log = std::fopen((g_dir + "/latency.jsonl").c_str(), "w");
  std::atomic<bool> done{false};
  std::thread input([&] {
    std::srand(1);
    int held = 0;
    while (!done) {
      std::this_thread::sleep_for(std::chrono::microseconds(240000 + std::rand() % 20000));
      fx.runner.set_buttons(0, held ^= kA, dena::now_ns());
    }
  });
  int64_t next = dena::now_ns();
  for (int k = 1; k <= seconds * 60; k++) {
    next += kPeriod;
    std::this_thread::sleep_for(std::chrono::nanoseconds(std::max<int64_t>(0, next - dena::now_ns())));
    int64_t t = next;
    int64_t c0 = dena::now_ns();
    fx.runner.run_on_emu([&] { fx.runner.on_vsync(t); });
    if (std::getenv("DENA_BENCH_TRACE"))
      std::fprintf(stderr, "vsync %d late %.2f ms, took %.2f ms\n", k, double(c0 - t) / 1e6,
                   double(dena::now_ns() - c0) / 1e6);
    if (k % 60 == 0 && log) {
      std::fprintf(log, "%s\n", fx.runner.metrics_json().c_str());
      std::fflush(log);
    }
  }
  done = true;
  input.join();
  if (log) std::fclose(log);
  // Frames post one period apart, and an input waits at most about a period
  // for its frame: before rewind captured after the post, DS frames posted
  // 8 and 24 ms apart and the p95 was 29 ms (rewind.md).
  std::string m = fx.runner.metrics_json();
  std::printf("%s\n", m.c_str());
  double interval = -1;
  size_t at = m.find("\"frame_interval_ms\":{\"p50\":");
  if (at != std::string::npos) std::sscanf(m.c_str() + at, "\"frame_interval_ms\":{\"p50\":%lf", &interval);
  const double period_ms = 1000.0 / fx.runner.fps(), p95 = fx.runner.input_p95_ms();
  CHECK(interval > 0.9 * period_ms && interval < 1.1 * period_ms);
  CHECK(p95 > 0 && p95 < 1.5 * period_ms);
  fx.runner.stop();
}

}  // namespace

// shaders.md, Upscale; desktop-resolution.md.
static void test_max_upscale() {
  CHECK(dena::Runner::max_upscale("/x/libmupen64plus_next_libretro.so") == 8);
  CHECK(dena::Runner::max_upscale("ppsspp_libretro.so") == 8);
  CHECK(dena::Runner::max_upscale("libpcsx_rearmed_libretro.so") == 2);
  CHECK(dena::Runner::max_upscale("mednafen_psx_hw_libretro.dll") == 8);
  CHECK(dena::Runner::max_upscale("libmgba_libretro.so") == 1);
  CHECK(dena::Runner::max_upscale("libmelonds_libretro.so") == 8);
  // ds.md, Internal resolution: 2x and up also turn the OpenGL renderer on;
  // Auto keeps the software renderer.
  using Opts = std::vector<std::pair<std::string, std::string>>;
  CHECK(dena::Runner::upscale_options("libmelonds_libretro.so", 0).empty());
  CHECK(dena::Runner::upscale_options("libmelonds_libretro.so", 3) ==
        (Opts{{"melonds_opengl_resolution", "3x native (768x576)"},
              {"melonds_opengl_renderer", "enabled"}}));
  CHECK(dena::Runner::upscale_options("libmelonds_libretro.so", 9) ==
        (Opts{{"melonds_opengl_resolution", "8x native (2048x1536)"},
              {"melonds_opengl_renderer", "enabled"}}));
  CHECK(dena::Runner::upscale_options("ppsspp_libretro.so", 2) ==
        (Opts{{"ppsspp_internal_resolution", "960x544"}}));
  CHECK(dena::Runner::upscale_options("ppsspp_libretro.dll", 8) ==
        (Opts{{"ppsspp_internal_resolution", "3840x2176"}}));
  CHECK(dena::Runner::upscale_options("libmgba_libretro.so", 2).empty());
  CHECK(dena::Runner::upscale_options("libpcsx_rearmed_libretro.so", 4) ==
        (Opts{{"pcsx_rearmed_neon_enhancement_enable", "enabled"}}));
  CHECK(dena::Runner::upscale_options("mupen64plus_next_libretro.so", 6) ==
        (Opts{{"mupen64plus-43screensize", "1920x1440"}}));

  // Beetle PSX HW: 1x, 2x, 4x, 8x; a factor in between uses the lower one,
  // and every factor above native turns PGXP on.
  const Opts pgxp{{"beetle_psx_hw_pgxp_mode", "memory only"},
                  {"beetle_psx_hw_pgxp_texture", "enabled"}};
  auto psx = [&](int f, const char *value) {
    Opts want{{"beetle_psx_hw_internal_resolution", value}};
    want.insert(want.end(), pgxp.begin(), pgxp.end());
    return dena::Runner::upscale_options("mednafen_psx_hw_libretro.so", f) == want;
  };
  CHECK(psx(2, "2x"));
  CHECK(psx(3, "2x"));
  CHECK(psx(6, "4x"));
  CHECK(psx(8, "8x"));
  CHECK(dena::Runner::upscale_options("mednafen_psx_hw_libretro.so", 0).empty());

  // Widescreen: N64 switches to its 16:9 sizes and the adjusted aspect;
  // Beetle PSX HW has its hack; cores without one get nothing.
  CHECK(dena::Runner::widescreen_options("mupen64plus_next_libretro.so", true) ==
        (Opts{{"mupen64plus-aspect", "16:9 adjusted"}}));
  CHECK(dena::Runner::widescreen_options("mupen64plus_next_libretro.so", false).empty());
  CHECK(dena::Runner::widescreen_options("mednafen_psx_hw_libretro.dll", true) ==
        (Opts{{"beetle_psx_hw_widescreen_hack", "enabled"},
              {"beetle_psx_hw_widescreen_hack_aspect_ratio", "16:9"}}));
  CHECK(dena::Runner::widescreen_options("ppsspp_libretro.so", true).empty());
  CHECK(dena::Runner::widescreen_options("libmelonds_libretro.so", true).empty());
  CHECK(dena::Runner::widescreen_options("libmgba_libretro.so", true).empty());

  // Texture packs (texture-packs.md): each desktop 3D core's replacement
  // switch; off, and cores without replacement, set nothing.
  CHECK(dena::Runner::texture_pack_options("mupen64plus_next_libretro.dll", true) ==
        (Opts{{"mupen64plus-txHiresEnable", "True"},
              {"mupen64plus-txHiresFullAlphaChannel", "True"}}));
  CHECK(dena::Runner::texture_pack_options("mednafen_psx_hw_libretro.so", true) ==
        (Opts{{"beetle_psx_hw_track_textures", "enabled"},
              {"beetle_psx_hw_replace_textures", "enabled"},
              {"beetle_psx_hw_texture_directory", "system"}}));
  CHECK(dena::Runner::texture_pack_options("ppsspp_libretro.so", true) ==
        (Opts{{"ppsspp_texture_replacement", "enabled"}}));
  CHECK(dena::Runner::texture_pack_options("flycast_libretro.dll", true) ==
        (Opts{{"reicast_custom_textures", "enabled"}}));
  CHECK(dena::Runner::texture_pack_options("ppsspp_libretro.so", false).empty());
  CHECK(dena::Runner::texture_pack_options("libmgba_libretro.so", true).empty());
  CHECK(dena::Runner::texture_pack_options("libmelonds_libretro.so", true).empty());
  CHECK(dena::Runner::upscale_options("mupen64plus_next_libretro.so", 4, true) ==
        (Opts{{"mupen64plus-169screensize", "1920x1080"}}));
  CHECK(dena::Runner::upscale_options("mupen64plus_next_libretro.so", 8, true) ==
        (Opts{{"mupen64plus-169screensize", "3840x2160"}}));
  CHECK(dena::Runner::upscale_options("mupen64plus_next_libretro.so", 5, true) ==
        (Opts{{"mupen64plus-169screensize", "1920x1080"}}));
  CHECK(dena::Runner::upscale_options("mupen64plus_next_libretro.so", 0, true).empty());
  // PSX keeps its resolution key when wide; PSP ignores wide.
  CHECK(psx(4, "4x"));
  CHECK(dena::Runner::upscale_options("mednafen_psx_hw_libretro.so", 4, true) ==
        dena::Runner::upscale_options("mednafen_psx_hw_libretro.so", 4));
  CHECK(dena::Runner::upscale_options("ppsspp_libretro.so", 2, true) ==
        (Opts{{"ppsspp_internal_resolution", "960x544"}}));

  // dreamcast-saturn.md: Flycast 1x-8x on its 4:3 sizes, also when wide;
  // widescreen turns on the per-game cheats and the generic hack. Beetle
  // Saturn draws native only and has no hack.
  CHECK(dena::Runner::max_upscale("flycast_libretro.dll") == 8);
  CHECK(dena::Runner::upscale_options("flycast_libretro.so", 2) ==
        (Opts{{"reicast_internal_resolution", "1280x960"}}));
  CHECK(dena::Runner::upscale_options("flycast_libretro.dll", 6) ==
        (Opts{{"reicast_internal_resolution", "3840x2880"}}));
  CHECK(dena::Runner::upscale_options("flycast_libretro.so", 8, true) ==
        (Opts{{"reicast_internal_resolution", "5120x3840"}}));
  CHECK(dena::Runner::upscale_options("flycast_libretro.so", 0).empty());
  CHECK(dena::Runner::widescreen_options("flycast_libretro.so", true) ==
        (Opts{{"reicast_widescreen_cheats", "enabled"},
              {"reicast_widescreen_hack", "enabled"}}));
  CHECK(dena::Runner::max_upscale("mednafen_saturn_libretro.dll") == 1);
  CHECK(dena::Runner::upscale_options("mednafen_saturn_libretro.so", 4).empty());
  CHECK(dena::Runner::widescreen_options("mednafen_saturn_libretro.so", true).empty());

  // ps2.md: LRPS2 1x, 2x, 4x, 8x (a factor in between uses the lower one),
  // also when wide; widescreen turns on its patches.
  CHECK(dena::Runner::max_upscale("pcsx2_libretro.dll") == 8);
  CHECK(dena::Runner::upscale_options("pcsx2_libretro.so", 3) ==
        (Opts{{"pcsx2_upscale_multiplier", "2x"}}));
  CHECK(dena::Runner::upscale_options("pcsx2_libretro.so", 8, true) ==
        (Opts{{"pcsx2_upscale_multiplier", "8x"}}));
  CHECK(dena::Runner::upscale_options("pcsx2_libretro.so", 0).empty());
  CHECK(dena::Runner::widescreen_options("pcsx2_libretro.dll", true) ==
        (Opts{{"pcsx2_widescreen_hint", "enabled (16:9)"}}));
  CHECK(dena::Runner::widescreen_options("pcsx2_libretro.dll", false).empty());
  // gamecube-wii.md: Dolphin 1x-8x by its frame buffer scale, the same
  // when wide; widescreen turns on the Wii's 16:9 setting and the hack.
  CHECK(dena::Runner::max_upscale("dolphin_libretro.dll") == 8);
  CHECK(dena::Runner::upscale_options("dolphin_libretro.so", 3) ==
        (Opts{{"dolphin_efb_scale", "3"}}));
  CHECK(dena::Runner::upscale_options("dolphin_libretro.so", 8, true) ==
        (Opts{{"dolphin_efb_scale", "8"}}));
  CHECK(dena::Runner::upscale_options("dolphin_libretro.so", 0).empty());
  CHECK(dena::Runner::widescreen_options("dolphin_libretro.dll", true) ==
        (Opts{{"dolphin_widescreen", "enabled"}, {"dolphin_widescreen_hack", "enabled"}}));
  CHECK(dena::Runner::widescreen_options("dolphin_libretro.dll", false).empty());
}

// gamecube-wii.md, Wii Remote: the pointer or the right stick aims.
static void test_pointer_aim_options() {
  using Opts = std::vector<std::pair<std::string, std::string>>;
  CHECK(dena::Runner::pointer_aim_options("dolphin_libretro.so", true) ==
        (Opts{{"dolphin_ir_mode", "2"}}));
  CHECK(dena::Runner::pointer_aim_options("dolphin_libretro.dll", false) ==
        (Opts{{"dolphin_ir_mode", "1"}}));
  CHECK(dena::Runner::pointer_aim_options("libmelonds_libretro.so", true).empty());
  // gamecube-wii.md, Saves: memory cards and NAND beside the battery saves.
  CHECK(dena::Runner::save_dir("dolphin_libretro.so", "/d/saves/abc.srm") == "/d/saves");
  CHECK(dena::Runner::save_dir("dolphin_libretro.dll", "C:\\d\\saves\\abc.srm") == "C:\\d\\saves");
  CHECK(dena::Runner::save_dir("ppsspp_libretro.so", "/d/saves/abc.srm").empty());
}

// Options Dena sets ahead of the factor ones (ds.md, dreamcast-saturn.md).
static void test_default_options() {
  using Opts = std::vector<std::pair<std::string, std::string>>;
  // Auto on the desktop's Dreamcast is 2x; a memory card per game.
  CHECK(dena::Runner::default_options("flycast_libretro.dll") ==
        (Opts{{"reicast_internal_resolution", "1280x960"},
              {"reicast_per_content_vmus", "VMU A1"}}));
  CHECK(dena::Runner::default_options("mednafen_saturn_libretro.so") ==
        (Opts{{"beetle_saturn_save_method", "libretro"}}));
  CHECK(dena::Runner::default_options("libmelonds_libretro.so").size() == 3);
  CHECK(dena::Runner::default_options("libmgba_libretro.so").empty());
  // PlayStation's Beetle core is not caught by the Saturn entries.
  CHECK(dena::Runner::default_options("mednafen_psx_hw_libretro.so").empty());
  // GameCube and Wii: Auto is 2x, the Wii starts 4:3.
  CHECK(dena::Runner::default_options("dolphin_libretro.dll") ==
        (Opts{{"dolphin_efb_scale", "2"}, {"dolphin_widescreen", "disabled"}}));
  // ps2.md: Auto is 2x, the host's GL context, a memory card per game.
  CHECK(dena::Runner::default_options("pcsx2_libretro.dll") ==
        (Opts{{"pcsx2_upscale_multiplier", "2x"},
              {"pcsx2_renderer", "OpenGL"},
              {"pcsx2_shared_memory_cards", "disabled"}}));
  // ...kept in <saves>/ps2; every other core keeps the system folder.
  CHECK(dena::Runner::save_dir("pcsx2_libretro.so", "/d/saves/Game.srm") == "/d/saves/ps2");
  CHECK(dena::Runner::save_dir("C:\\x\\pcsx2_libretro.dll", "C:\\d\\saves\\G.srm") ==
        "C:\\d\\saves\\ps2");
  CHECK(dena::Runner::save_dir("flycast_libretro.so", "/d/saves/Game.srm").empty());
  CHECK(dena::Runner::save_dir("pcsx2_libretro.so", "").empty());
}

int main(int argc, char **argv) {
  if (argc == 6 && std::strcmp(argv[1], "--audio") == 0) {
    g_core = argv[2];
    g_rom = argv[3];
    g_dir = argv[4];
    test_core_audio(std::atoi(argv[5]));
    if (failures) std::fprintf(stderr, "%d failure(s)\n", failures);
    return failures ? 1 : 0;
  }
  if (argc == 5 && std::strcmp(argv[1], "--costs") == 0) {
    g_core = argv[2];
    g_rom = argv[3];
    frame_costs(std::atoi(argv[4]));
    return failures ? 1 : 0;
  }
  if (argc == 8 && std::strcmp(argv[1], "--latency") == 0) {
    g_core = argv[2];
    g_rom = argv[3];
    g_dir = argv[4];
    latency_bench(std::atoi(argv[5]), std::atoi(argv[6]), std::atoi(argv[7]));
    return failures ? 1 : 0;
  }
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: runner_tests <testcore> <tmpdir>\n"
                 "       runner_tests --audio <core> <rom> <tmpdir> <run-ahead method>\n"
                 "       runner_tests --latency <core> <rom> <tmpdir> <run-ahead mode> <frames> <seconds>\n");
    return 2;
  }
  g_core = argv[1];
  g_dir = argv[2];
  test_max_upscale();
  test_default_options();
  test_pointer_aim_options();
  g_rom = g_dir + "/test.rom";
  write_file(g_rom, "dena");
  test_lifecycle();
  test_pacing();
  test_pause();
  test_rewind();
  test_scrub();
  test_states_and_cheats();
  test_ram_mailbox();
  test_heavy_state();
  test_capture_after_post();
  test_late_state();
  test_audio();
  test_run_ahead();
  test_run_ahead_audio();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("runner: all passed\n");
  return 0;
}
