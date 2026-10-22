// SPDX-License-Identifier: GPL-3.0-or-later
// The shared runner's Linux handheld platform: DRM vblank pacing, ALSA
// audio, software frames through a mailbox to the engine's external texture.
// Spec: docs/specs/handheld-session.md
#ifndef DENA_LINUX_PLATFORM_H
#define DENA_LINUX_PLATFORM_H

#include <alsa/asoundlib.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include "frame_mailbox.h"
#include "gl_target.h"
#include "runner.h"

namespace dena {

struct LinuxPlatformConfig {
  int drm_fd = -1;          // for vblank waits; -1 sleeps by the clock
  int crtc_index = 0;       // the CRTC's index in the card's resources
  int refresh_mhz = 60000;  // the mode's refresh rate, for the clock fallback
  std::string audio_card = "default";
  GlShare gl_share;  // for GPU cores and shaders; no display means none
  unsigned screen_w = 0, screen_h = 0;  // the largest picture a shader draws
  std::function<void()> frame_ready;  // any thread: a new frame is in the mailbox
};

class LinuxPlatform : public RunnerPlatform {
 public:
  explicit LinuxPlatform(LinuxPlatformConfig cfg);
  ~LinuxPlatform() override;

  Runner runner{this};
  FrameMailbox mailbox;

  // Shader preset path, "" for Off (shaders.md). Before a game starts it is
  // remembered; a software core switches to GL while one is on. Returns an
  // error message, "" on success.
  std::string set_shader(const std::string &path);
  // Stops the game and forgets the shader.
  void stop_session();

  void thread_begin() override;
  void video_begin(bool hw, bool gpu_ok) override;
  void wait(bool want_frames) override;
  void wake() override;
  bool has_surface() override { return true; }

  // GPU cores (hw-render.md): rendered on the emulator thread into
  // textures the engine shows.
  bool start_gpu(unsigned w, unsigned h, bool depth, bool stencil) override;
  bool gpu_ready() override { return gl_.ready(); }
  uintptr_t gpu_framebuffer() override { return gl_.framebuffer(); }
  void *gl_proc_address(const char *sym) override { return GlTarget::proc_address(sym); }
  void stop_gpu() override { gl_.shutdown(); }
  // Raster thread: the newest GPU frame's texture, 0 when none.
  unsigned gpu_texture(uint32_t *w, uint32_t *h) { return gl_.take(w, h); }

  bool draw_software(const dena_frame &frame, int direction) override;
  bool draw_gpu(unsigned w, unsigned h, bool bottom_left, int) override;
  bool read_pixels(unsigned w, unsigned h, bool bottom_left,
                   std::vector<uint32_t> &out) override {
    return gl_.read_pixels(w, h, bottom_left, out);
  }

  int open_audio() override;
  bool start_audio() override;
  void pause_audio() override;
  void close_audio() override;
  int audio_xruns() override { return xruns_; }

 private:
  bool wait_vblank(int64_t *ns);
  void wait_clock(int64_t *ns);
  void audio_main();

  LinuxPlatformConfig cfg_;
  GlTarget gl_;  // emulator thread, except take()
  std::string shader_path_;  // emulator thread once a game runs
  int wake_fd_ = -1;
  bool use_vblank_ = true;
  int64_t next_tick_ns_ = 0;

  snd_pcm_t *pcm_ = nullptr;
  std::thread audio_thread_;
  std::mutex audio_mtx_;
  std::condition_variable audio_cv_;
  bool audio_paused_ = true;
  bool audio_quit_ = false;
  std::atomic<int> xruns_{0};
};

}  // namespace dena

#endif
