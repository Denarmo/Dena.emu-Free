// SPDX-License-Identifier: GPL-3.0-or-later
// The shared runner's desktop platform (Windows and Linux, x86_64): vsync
// from DXGI or the display's refresh rate, SDL3 audio reading the runner's
// ring, desktop GL for GPU cores, slang shader stacks, frames to Flutter's
// texture.
// Spec: docs/specs/desktop-shell.md, shader-stacks.md
#ifndef DENA_DESKTOP_PLATFORM_H
#define DENA_DESKTOP_PLATFORM_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "dena/frame_gen.h"
#include "dena/slang_chain.h"
#include "desktop_map.h"
#include "frame_gen_pacer.h"
#include "gl_desktop.h"
#include "runner.h"
#ifdef _WIN32
#include "d3d_frames.h"
#else
#include "frame_mailbox.h"
#endif

struct SDL_AudioStream;

namespace dena {

struct DesktopPlatformConfig {
  void *window = nullptr;  // HWND (Windows)
  int refresh_mhz = 60000;
  std::function<void()> frame_ready;  // any thread
};

class DesktopPlatform : public RunnerPlatform {
 public:
  explicit DesktopPlatform(DesktopPlatformConfig cfg);
  ~DesktopPlatform() override;

  Runner runner{this};

  void set_refresh(int mhz);
  // Frame generation (frame-generation.md). Any thread: 0 off, 1
  // interpolate, 2 pixel-art; applies from the next frame.
  void set_frame_generation(int mode) { fg_pacer_.set_want(mode); }
  const FrameGenPacer &frame_gen() const { return fg_pacer_; }
  // The passthrough preset frame generation shades through without a shader.
  void set_stock_shader(const std::string &path) { stock_path_ = path; }
  // The runner's metrics with the frame generation fields.
  std::string metrics_json();
  // Whether SDL audio is up (before the first game).
  void set_audio(bool on) { audio_ = on; }
  // Any thread: the unlock chime over the game's audio (achievements.md).
  void chime() { chime_pos_ = 0; }
  // Raster thread: the newest frame (desktop.h, dena_desktop_frame_*).
#ifdef _WIN32
  void *take_d3d(uint32_t *w, uint32_t *h) { return d3d_.take(w, h); }
#else
  const MailFrame *take_rgba(bool *fresh) { return mailbox_.take(fresh); }
#endif

  // Shader stacks (shader-stacks.md). Any thread: a .slangp path, "" for
  // Off; before a game it applies once the core loads. Returns an error
  // message, "" on success.
  std::string set_shader(const std::string &path);
  // Any thread: the game picture's size in physical pixels (0: unknown).
  void set_output_size(unsigned w, unsigned h) {
    out_w_ = w;
    out_h_ = h;
  }
  // The chain's output size for a w x h frame.
  static void output_size(unsigned frame_w, unsigned frame_h, unsigned want_w, unsigned want_h,
                          unsigned *w, unsigned *h);

  void thread_begin() override;
  void video_begin(bool hw, bool gpu_ok) override;
  void wait(bool want_frames) override;
  void wake() override;
  bool has_surface() override { return true; }

  bool start_gpu(unsigned w, unsigned h, bool depth, bool stencil) override;
  bool gpu_ready() override { return gl_.ready(); }
  uintptr_t gpu_framebuffer() override { return gl_.framebuffer(); }
  void *gl_proc_address(const char *sym) override { return DesktopGl::proc_address(sym); }
  void stop_gpu() override;

  bool draw_software(const dena_frame &frame, int direction) override;
  bool draw_gpu(unsigned w, unsigned h, bool bottom_left, int direction) override;
  bool read_pixels(unsigned w, unsigned h, bool bottom_left,
                   std::vector<uint32_t> &out) override {
    return gl_.read_pixels(w, h, bottom_left, out);
  }

  int open_audio() override;
  bool start_audio() override;
  void pause_audio() override;
  void close_audio() override;

 private:
  static void audio_callback(void *self, SDL_AudioStream *stream, int additional, int total);
  void wait_clock(int64_t *ns);
  bool put_frame(const uint32_t *xrgb, unsigned w, unsigned h);
  // Emulator thread: shader helpers.
  bool load_shader(const std::string &path, std::string *err);
  void shutdown_gl();
  bool draw_shaded(unsigned frame_w, unsigned frame_h);
  bool show_output(unsigned w, unsigned h);
  // Emulator thread: frame generation on or off as the pacer says.
  void apply_frame_gen(bool in_game = true);
  void set_up_frame_gen(int mode);
  void stop_frame_gen();
  void show_held();

  DesktopPlatformConfig cfg_;
  std::atomic<int> refresh_mhz_{60000};
  std::atomic<bool> audio_{false};
  DesktopGl gl_;  // emulator thread
  std::vector<uint32_t> readback_;
  slang::SlangChain chain_;  // emulator thread, in gl_'s context
  std::string shader_path_;  // the preset on (or to load), "" for Off
  std::atomic<unsigned> out_w_{0}, out_h_{0};
  FrameGenPacer fg_pacer_;
  slang::FrameGen fg_;       // emulator thread, the chain's source filter
  int fg_mode_ = 0;          // mode the filter is set up for
  bool stock_only_ = false;  // the chain runs the stock preset for fg_ alone
  std::string stock_path_;
  unsigned held_w_ = 0, held_h_ = 0, held_out_w_ = 0, held_out_h_ = 0;
  uint64_t draws_ = 0;       // pictures handed to Flutter (emulator thread)
#ifdef _WIN32
  D3dFrames d3d_;
  int fast_vblanks_ = 0;    // WaitForVBlank returning at once (display off)
  int clock_frames_ = 0;    // frames left on the clock after that
#else
  FrameMailbox mailbox_;
#endif
  int64_t next_tick_ns_ = 0;

  std::mutex wake_mtx_;
  std::condition_variable wake_cv_;
  bool woken_ = false;

  SDL_AudioStream *audio_stream_ = nullptr;
  std::vector<int16_t> audio_buf_;  // SDL's audio thread only
  std::atomic<uint32_t> chime_pos_{dena::kChimeFrames};  // idle at the end
};

}  // namespace dena

#endif
