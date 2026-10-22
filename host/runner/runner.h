// SPDX-License-Identifier: GPL-3.0-or-later
// The play loop shared by the platform shells: emulator thread, pause and
// auto-save, fast-forward, rewind, states, cheats, input, audio rate control
// and latency metrics. Platform APIs come through RunnerPlatform.
// Spec: docs/specs/shared-runner.md
#ifndef DENA_RUNNER_H
#define DENA_RUNNER_H

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include "dena/audio.h"
#include "dena/host.h"
#include "dena/rewind.h"
}
#include "netplay_session.h"
#include "run_ahead.h"

namespace dena {

class Runner;

// What a shell provides. Unless noted, hooks run on the emulator thread.
class RunnerPlatform {
 public:
  virtual ~RunnerPlatform() = default;

  // Emulator thread start (before the GPU starts) and end.
  virtual void thread_begin() {}
  virtual void thread_end() {}
  // After the GPU start: gpu_ok is false only for a GPU core that failed.
  virtual void video_begin(bool hw, bool gpu_ok) { (void)hw, (void)gpu_ok; }
  // Blocks until wake() or a vsync. With want_frames, a vsync calls
  // runner.on_vsync(ns) from inside this call.
  virtual void wait(bool want_frames) = 0;
  // Any thread: ends a wait() early.
  virtual void wake() = 0;
  // Any thread: there is somewhere to draw.
  virtual bool has_surface() = 0;

  // GPU cores (hw-render.md).
  virtual bool start_gpu(unsigned w, unsigned h, bool depth, bool stencil) = 0;
  virtual bool gpu_ready() = 0;
  virtual uintptr_t gpu_framebuffer() = 0;
  virtual void *gl_proc_address(const char *sym) = 0;
  virtual void stop_gpu() = 0;  // after the core destroyed its context

  // Puts a frame on the surface; false when nothing was shown.
  // direction is -1 while rewinding (shaders that animate), else 1.
  virtual bool draw_software(const dena_frame &frame, int direction) = 0;
  virtual bool draw_gpu(unsigned w, unsigned h, bool bottom_left, int direction) = 0;
  virtual bool read_pixels(unsigned w, unsigned h, bool flip_y, std::vector<uint32_t> &out) = 0;

  // Audio (any thread). open_audio returns the output rate, 0 for none;
  // the platform's audio thread calls runner.read_audio().
  virtual int open_audio() = 0;
  virtual bool start_audio() = 0;
  virtual void pause_audio() = 0;
  virtual void close_audio() = 0;
  virtual int audio_xruns() { return 0; }
};

// Fixed-size sample window with percentile queries (metrics only).
class Samples {
 public:
  explicit Samples(size_t cap) : cap_(cap) {}
  void add(double v);
  bool empty() const { return data_.empty(); }
  double pct(double p) const;
  double max() const;

 private:
  size_t cap_;
  size_t next_ = 0;
  std::vector<double> data_;
};

int64_t now_ns();

class Runner {
 public:
  // Result of start(): see game-session.md, Lifecycle.
  enum StartResult { kStartError = -1, kStartFresh = 0, kStartResumed = 1, kStartBadState = 2 };

  explicit Runner(RunnerPlatform *platform) : platform_(platform) {}
  ~Runner() { stop(); }
  Runner(const Runner &) = delete;
  Runner &operator=(const Runner &) = delete;

  int start(const std::string &core_path, const std::string &rom_path,
            const std::string &system_dir, const std::string &srm_path,
            const std::string &state_path);
  // Saves (battery and auto-save state), then unloads the core.
  void stop();
  bool running() const { return thread_.joinable(); }

  // Internal resolution (shaders.md, Upscale; desktop-resolution.md): 0
  // keeps the core's default, 2-8 multiplies the native size on cores that
  // support it (capped at max_upscale, a missing factor uses the next lower
  // one). Takes effect at the next start().
  void set_upscale(int factor) { upscale_ = factor; }
  // The core's 16:9 widescreen hack (desktop-resolution.md); cores without
  // one ignore it. Takes effect at the next start().
  void set_widescreen(bool on) { widescreen_ = on; }
  // The Wii Remote aims with the libretro pointer (the gyro pointer of
  // player 1's profile) instead of the right stick (gamecube-wii.md, Wii
  // Remote). Takes effect at the next start().
  void set_pointer_aim(bool on) { pointer_aim_ = on; }
  // HD texture packs (texture-packs.md): turns on the core's texture
  // replacement; cores without one ignore it. Takes effect at the next
  // start().
  void set_texture_packs(bool on) { texture_packs_ = on; }
  // Highest factor the core at core_path renders at (1: no upscale).
  static int max_upscale(const std::string &core_path);
  // The core options start() sets for factor (key, value), in order; wide
  // picks the core's 16:9 sizes where it has them.
  static std::vector<std::pair<std::string, std::string>> upscale_options(
      const std::string &core_path, int factor, bool wide = false);
  // The core options start() sets before the factor and widescreen ones,
  // where Dena differs from the core's own defaults (ds.md,
  // dreamcast-saturn.md).
  static std::vector<std::pair<std::string, std::string>> default_options(
      const std::string &core_path);
  // The folder a core keeps its own save files in, when it isn't the system
  // folder: PS2 memory cards go to <folder of srm_path>/ps2 (ps2.md), Dolphin
  // gets the folder of srm_path itself (gamecube-wii.md, Saves). Empty for
  // every other core.
  static std::string save_dir(const std::string &core_path, const std::string &srm_path);
  // The core options start() sets for widescreen (none when off or when the
  // core has no hack).
  static std::vector<std::pair<std::string, std::string>> widescreen_options(
      const std::string &core_path, bool wide);
  // The core options start() sets for the Wii Remote's aim (none for cores
  // without one).
  static std::vector<std::pair<std::string, std::string>> pointer_aim_options(
      const std::string &core_path, bool pointer);
  // The core options start() sets for texture packs (none when off or when
  // the core cannot replace textures).
  static std::vector<std::pair<std::string, std::string>> texture_pack_options(
      const std::string &core_path, bool on);
  // The game's native picture size, for shaders (shaders.md, Native lines).
  // Valid after start().
  void native_size(unsigned *w, unsigned *h) const;

  // Runs fn on the emulator thread between frames and waits for it.
  void run_on_emu(std::function<void()> fn);

  // Pauses frames and audio and writes the battery save and auto-save state.
  void pause();
  void resume();
  bool paused() const { return paused_; }
  void save_now();
  void set_speed(int n);
  // performance.md: audio buffer target, 20..80 ms (default 40); takes
  // effect the next time audio opens (game start).
  void set_audio_latency_ms(int ms) { audio_target_ms_ = uint32_t(std::clamp(ms, 20, 80)); }
  int audio_latency_ms() const { return int(audio_target_ms_.load()); }

  // Rewind (rewind.md): enabled captures states; l2_hold makes a gamepad's
  // L2 rewind while held (for systems that don't use L2).
  void configure_rewind(bool enabled, bool l2_hold);
  void set_rewinding(bool on) { rewind_hold_ = on; }
  bool rewinding() const;
  // A capture every kRewindInterval frames; playing back steps as often.
  static constexpr int kRewindInterval = 2;
  // Long rewind (rewind.md; rewind_scrub.cpp). The buffer's memory budget
  // (32 MB unless set; the desktop raises it to minutes). A change starts a
  // new, empty buffer.
  void set_rewind_budget(size_t bytes);
  struct RewindInfo {
    size_t count = 0;     // captures behind the newest state
    size_t position = 0;  // where the scrub is (count = the newest)
    size_t bytes = 0, budget = 0;
    double fps = 0;
  };
  RewindInfo rewind_info();
  // Scrubbing while paused (the pause menu's scrub bar): begin stores the
  // live state as the newest capture (false: no rewind for this game);
  // scrub_to moves the picture there without blocking (the emulator thread
  // catches up); end keeps that point (later captures are dropped) or goes
  // back to the live state.
  bool begin_scrub(RewindInfo *info);
  void scrub_to(size_t position);
  void end_scrub(bool keep);

  // Run-ahead (run-ahead.md), any thread: mode is a RunAheadMode, frames
  // 1-3; applied from the next frame, on cores run_ahead_core_limit allows.
  void set_run_ahead(int mode, int frames) {
    run_ahead_mode_ = mode;
    run_ahead_want_ = frames;
  }
  // Frames of run-ahead in effect on the last frame (0: off).
  int run_ahead_frames() const { return run_ahead_frames_; }
  // The method in effect (0 off); run-ahead falls back to preemptive on a
  // core that holds sound across frames (run_ahead.h).
  int run_ahead_method() const { return run_ahead_method_; }

  // Save-state slots (save-states.md). 0 ok, -1 error; load may return DENA_NO_DATA.
  int save_state(const std::string &state_path, const std::string &png_path);
  int load_state(const std::string &state_path);
  // Current frame as PNG (pause-menu.md, Capture). 0 ok, -1 error.
  int screenshot(const std::string &path);
  // Replaces the active cheats (cheats.md).
  void set_cheats(std::vector<std::string> codes);
  // Host mailbox in the core's system RAM (pico8-launcher-cart.md). Any
  // thread. watch_ram picks the window [offset, offset + len) that is copied
  // out after every frame (len 0 stops); read_ram copies the latest snapshot
  // (false before one exists or when the core has no such RAM); write_ram
  // queues bytes that go in before the next frame, in call order.
  void watch_ram(size_t offset, size_t len);
  bool read_ram(uint8_t *out, size_t len);
  void write_ram(size_t offset, const uint8_t *data, size_t len);

  // Netplay (netplay.md), any thread: the session plays through this runner
  // from the next frame (nullptr detaches it). While it is connected, speed
  // stays 1 and rewind, state loads, cheats, run-ahead and the frame hook
  // are off.
  void set_netplay(std::shared_ptr<NetplaySession> session);
  bool netplay_active() const { return netplay_on_; }

  // Achievements (achievements.md). fn runs on the emulator thread after every
  // played frame (not rewound ones) with the loaded core; set before start().
  void set_frame_hook(std::function<void(dena_core *)> fn) { frame_hook_ = std::move(fn); }
  // Hardcore mode (any thread): while on, state loads fail, rewind stops and
  // cheats are cleared and refused.
  void set_hardcore(bool on) { hardcore_ = on; }
  bool hardcore() const { return hardcore_; }

  // Input (any thread); applied on the next frame. event_ns is CLOCK_MONOTONIC.
  void set_buttons(int port, int mask, int64_t event_ns);
  void set_touch(int mask, int64_t event_ns);  // ORed into port 0
  void set_analog(int port, int lx, int ly, int rx, int ry);
  void set_touch_analog(int stick, int x, int y);  // overrides port 0's sticks while held
  void set_pointer(int x, int y, bool pressed);
  // Multitap (gamepads.md, Desktop: eight players): on, ports where the core
  // offers a multitap use it from the next frame; off, the plain RetroPad.
  void set_multitap(bool on) { multitap_want_ = on; }
  // Turbo (turbo.md): buttons in `mask` (libretro joypad bits, all ports)
  // alternate pressed/released every `half_frames` emulated frames while held.
  // mask 0 turns turbo off.
  void set_turbo(int mask, int half_frames);

  // Emulator thread: a vsync at vsync_ns (CLOCK_MONOTONIC).
  void on_vsync(int64_t vsync_ns);
  // Emulator thread: draws the last frame again (paused shader changes, new surfaces).
  void repaint();
  // Emulator thread: forget frame timing (a lost surface).
  void resync() { next_due_ns_ = 0; }
  // Emulator thread, inside draw_*: the frame is a new one at normal speed
  // (not a repaint, a rewound or a fast-forward frame) (frame-generation.md).
  bool fresh_draw() const { return fresh_draw_; }
  // The core's frame rate (60 before a game).
  double fps() const { return frame_period_ns_ > 0 ? 1e9 / double(frame_period_ns_) : 60.0; }
  // p95 input_to_post in ms, -1 without samples.
  double input_p95_ms();

  // Audio thread: fills out with n stereo frames.
  void read_audio(int16_t *out, uint32_t n) { dena_ring_read(&ring_, out, n); }
  // Stereo samples from the core that went to the output, at its own rate
  // (tests count them per presented frame).
  uint64_t audio_samples_played() const { return audio_in_; }

  std::string metrics_json();
  void reset_metrics();
  // Pixel of the last software frame as 0xRRGGBB, or -1 (instrumentation tests).
  int pixel(int x, int y);
  bool hw() const { return hw_; }
  const std::string &error() const { return error_; }
  void set_error(const std::string &e) { error_ = e; }

 private:
  static void audio_sink(void *user, const int16_t *frames, size_t n);
  static uintptr_t hw_framebuffer(void *self);
  static void *hw_proc_address(void *self, const char *sym);
  static uint64_t pack_analog(int lx, int ly, int rx, int ry);

  void push_audio(const int16_t *frames, size_t n);
  bool open_audio();
  void close_audio();
  void thread_main();
  bool start_gpu();
  const dena_frame *current_frame();
  void run_commands();
  void save_all();
  void reject_state();
  void retry_state_load();
  void reset_rewind();
  void capture_rewind();
  void rewind_one_frame();
  void show_rewind_state();
  void scrub_step();
  void run_one_frame(bool shown);
  void configure_run_ahead();
  class AheadDriver;
  class NetDriver;
  bool run_netplay_frame(const uint32_t *masks, bool shown);
  void present();
  bool draw_frame();

  RunnerPlatform *platform_;
  std::mutex life_mtx_;
  std::thread thread_;
  std::atomic<bool> running_{false};

  dena_core *core_ = nullptr;
  dena_av_info av_{};
  int upscale_ = 0;
  bool widescreen_ = false;
  bool pointer_aim_ = false;
  bool texture_packs_ = false;
  unsigned native_w_ = 0, native_h_ = 0;
  bool hw_ = false;  // the core renders with the GPU (hw-render.md)
  std::promise<bool> *gpu_ready_ = nullptr;
  dena_hw_info hw_info_{};
  std::vector<uint32_t> readback_;
  dena_frame readback_frame_{};
  std::string error_;

  std::mutex cmd_mtx_;
  std::deque<std::function<void()>> cmds_;
  std::atomic<bool> paused_{false};
  std::atomic<int> speed_{1};
  std::string srm_path_, state_path_;
  uint64_t last_battery_hash_ = 0;
  int state_retries_ = 0;  // frames left to retry a deferred state load
  int64_t last_battery_check_ns_ = 0;

  dena_rewind *rewind_ = nullptr;  // emulator thread
  std::vector<uint8_t> rewind_state_;
  unsigned rewind_tick_ = 0;
  bool rewind_enabled_ = true;
  bool muted_ = false;
  size_t step_samples_ = 0;  // emulator thread: samples from the core this frame
  std::atomic<uint64_t> audio_in_{0};
  std::atomic<bool> rewind_hold_{false};
  std::atomic<bool> l2_rewind_{false};
  std::atomic<size_t> rewind_budget_{32u << 20};  // rewind.md, phones
  std::atomic<size_t> scrub_target_{0};
  std::atomic<bool> scrub_queued_{false};
  bool scrubbing_ = false;  // emulator thread

  std::atomic<uint32_t> buttons_[DENA_MAX_PORTS] = {};
  std::atomic<uint32_t> touch_buttons_{0};
  std::atomic<uint32_t> turbo_mask_{0};
  std::atomic<int> turbo_half_{2};
  unsigned turbo_tick_ = 0;  // emulator thread
  std::atomic<uint64_t> analog_[DENA_MAX_PORTS] = {};  // lx, ly, rx, ry (int16)
  std::atomic<uint64_t> touch_analog_{0};
  std::atomic<uint32_t> pointer_{0};  // x << 16 | y, int16 each
  std::atomic<bool> pointer_down_{false};
  std::atomic<bool> multitap_want_{false};
  bool multitap_on_ = false;  // emulator thread
  std::atomic<int64_t> pending_input_ns_{0};
  int64_t frame_input_ns_ = 0;

  int64_t frame_period_ns_ = 16666667;
  bool fresh_draw_ = false;
  int64_t next_due_ns_ = 0;
  int64_t last_post_ns_ = 0;

  bool audio_open_ = false;
  int32_t out_rate_ = 0;
  std::atomic<uint32_t> audio_target_ms_{40};
  uint32_t target_frames_ = 0;
  dena_ring ring_{};
  dena_resampler resampler_{};
  dena_rate_ctl rate_ctl_{};
  std::vector<int16_t> resampled_;

  RunAhead run_ahead_;  // emulator thread
  int run_ahead_limit_ = 0;  // for the loaded core
  std::atomic<int> run_ahead_mode_{kRunAheadOff};
  std::atomic<int> run_ahead_want_{0};
  std::atomic<int> run_ahead_frames_{0};
  std::atomic<int> run_ahead_method_{0};

  std::shared_ptr<NetplaySession> netplay_;  // emulator thread
  std::atomic<bool> netplay_on_{false};

  std::function<void(dena_core *)> frame_hook_;
  std::atomic<bool> hardcore_{false};
  bool hardcore_applied_ = false;  // emulator thread
  void apply_hardcore();
  void apply_multitap();

  bool sync_ram_before();
  void sync_ram_after();
  std::mutex ram_mtx_;
  size_t ram_offset_ = 0, ram_len_ = 0;
  std::vector<uint8_t> ram_snapshot_;  // empty until a frame ran with a window
  std::vector<std::pair<size_t, std::vector<uint8_t>>> ram_writes_;

  std::mutex frame_mtx_;
  std::vector<uint32_t> last_frame_;
  uint32_t last_w_ = 0, last_h_ = 0;

  std::mutex metrics_mtx_;
  Samples input_to_post_{256};
  Samples frame_interval_{600};
  unsigned missed_ = 0;
  uint64_t frames_ = 0;
};

}  // namespace dena

#endif
