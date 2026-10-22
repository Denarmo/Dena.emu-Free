// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-session.md
#include "linux_platform.h"

#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>

#include <cerrno>
#include <cstdio>
#include <vector>

#include "dena/platform.h"
#include "dena/shader_preset.h"

namespace dena {

namespace {

constexpr int kAudioRate = 48000;
constexpr snd_pcm_uframes_t kPeriod = 256;  // 5.3 ms

// S16LE stereo, kPeriod-frame periods, `periods` of them in the hardware
// buffer; starts only once the buffer is full. Returns the rate, or <= 0.
int configure_pcm(snd_pcm_t *pcm, unsigned periods) {
  snd_pcm_hw_params_t *hw;
  snd_pcm_hw_params_alloca(&hw);
  unsigned rate = kAudioRate;
  snd_pcm_uframes_t period = kPeriod, buffer = kPeriod * periods;
  int rc;
  if ((rc = snd_pcm_hw_params_any(pcm, hw)) < 0 ||
      (rc = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
      (rc = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE)) < 0 ||
      (rc = snd_pcm_hw_params_set_channels(pcm, hw, 2)) < 0 ||
      (rc = snd_pcm_hw_params_set_rate_resample(pcm, hw, 1)) < 0 ||
      (rc = snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, nullptr)) < 0 ||
      (rc = snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, nullptr)) < 0 ||
      (rc = snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer)) < 0 ||
      (rc = snd_pcm_hw_params(pcm, hw)) < 0)
    return rc;
  snd_pcm_hw_params_get_period_size(hw, &period, nullptr);
  snd_pcm_hw_params_get_buffer_size(hw, &buffer);

  snd_pcm_sw_params_t *sw;
  snd_pcm_sw_params_alloca(&sw);
  if ((rc = snd_pcm_sw_params_current(pcm, sw)) < 0 ||
      (rc = snd_pcm_sw_params_set_start_threshold(pcm, sw, buffer)) < 0 ||
      (rc = snd_pcm_sw_params_set_avail_min(pcm, sw, period)) < 0 ||
      (rc = snd_pcm_sw_params(pcm, sw)) < 0)
    return rc;
  std::fprintf(stderr, "dena: audio %u Hz, period %lu, buffer %lu frames\n", rate,
               (unsigned long)period, (unsigned long)buffer);
  return int(rate);
}

// The audio thread must not wait behind the emulator and UI threads: a late
// period is a click. Real-time when allowed (the launcher runs as root on the
// image), else the highest nice level we may take.
void raise_audio_priority() {
  sched_param sp{};
  sp.sched_priority = 50;
  if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) == 0) return;
  if (setpriority(PRIO_PROCESS, 0, -10) != 0) {  // 0: this thread, on Linux
    // Not allowed either: keep the default priority.
  }
}

void drain(int fd) {
  uint64_t v;
  while (read(fd, &v, sizeof v) == sizeof v) {
  }
}

}  // namespace

LinuxPlatform::LinuxPlatform(LinuxPlatformConfig cfg) : cfg_(std::move(cfg)) {
  wake_fd_ = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  use_vblank_ = cfg_.drm_fd >= 0;
  if (cfg_.refresh_mhz <= 0) cfg_.refresh_mhz = 60000;
  gl_.set_output_limit(cfg_.screen_w, cfg_.screen_h);
}

LinuxPlatform::~LinuxPlatform() {
  runner.stop();
  close_audio();
  if (wake_fd_ >= 0) close(wake_fd_);
}

void LinuxPlatform::thread_begin() { next_tick_ns_ = 0; }

void LinuxPlatform::video_begin(bool hw, bool gpu_ok) {
  if (shader_path_.empty()) return;
  std::string err;
  bool gl = hw ? gpu_ok : gl_.init_context(cfg_.gl_share);
  if (!gl || !gl_.set_shader(shader_path_, &err)) {
    std::fprintf(stderr, "dena: shader off: %s\n", gl ? err.c_str() : "no GL");
    shader_path_.clear();
    if (!hw) gl_.shutdown();
  }
}

std::string LinuxPlatform::set_shader(const std::string &path) {
  std::string err;
  if (!path.empty()) {
    ShaderPreset preset;  // catch unreadable presets before touching GL
    if (!parse_preset(path, &preset, &err)) return err;
  }
  if (!runner.running()) {
    shader_path_ = path;
    return "";
  }
  runner.run_on_emu([&] {
    if (path.empty()) {
      // A software core goes back to the frame mailbox.
      if (!runner.hw()) gl_.shutdown();
      else gl_.set_shader("", &err);
      shader_path_.clear();
    } else if (!gl_.ready() && !gl_.init_context(cfg_.gl_share)) {
      err = "GL could not start; shaders are off";
    } else if (gl_.set_shader(path, &err)) {
      shader_path_ = path;
      runner.repaint();
    } else if (!runner.hw() && !gl_.has_shader()) {
      gl_.shutdown();  // the first shader failed: stay on the mailbox
    }
  });
  return err;
}

void LinuxPlatform::stop_session() {
  runner.stop();
  shader_path_.clear();
}

bool LinuxPlatform::wait_vblank(int64_t *ns) {
  drmVBlank vbl = {};
  unsigned type = DRM_VBLANK_RELATIVE;
  if (cfg_.crtc_index == 1)
    type |= DRM_VBLANK_SECONDARY;
  else if (cfg_.crtc_index > 1)
    type |= (unsigned(cfg_.crtc_index) << DRM_VBLANK_HIGH_CRTC_SHIFT) & DRM_VBLANK_HIGH_CRTC_MASK;
  vbl.request.type = drmVBlankSeqType(type);
  vbl.request.sequence = 1;
  if (drmWaitVBlank(cfg_.drm_fd, &vbl) != 0) return false;
  // Reply times are CLOCK_MONOTONIC (DRM_CAP_TIMESTAMP_MONOTONIC, every
  // kernel these devices run).
  *ns = int64_t(vbl.reply.tval_sec) * 1000000000LL + int64_t(vbl.reply.tval_usec) * 1000LL;
  return true;
}

void LinuxPlatform::wait_clock(int64_t *ns) {
  int64_t period = 1000000000000LL / cfg_.refresh_mhz;
  int64_t now = now_ns();
  if (next_tick_ns_ == 0 || now - next_tick_ns_ > 100000000LL) next_tick_ns_ = now;
  next_tick_ns_ += period;
  timespec ts{time_t(next_tick_ns_ / 1000000000LL), long(next_tick_ns_ % 1000000000LL)};
  while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr) == EINTR) {
  }
  *ns = next_tick_ns_;
}

void LinuxPlatform::wait(bool want_frames) {
  if (!want_frames) {
    pollfd p{wake_fd_, POLLIN, 0};
    poll(&p, 1, 250);
    drain(wake_fd_);
    return;
  }
  // Commands queued meanwhile run when this returns (at most one frame late).
  int64_t ns = 0;
  if (use_vblank_ && !wait_vblank(&ns)) {
    std::fprintf(stderr, "dena: no vblank events (%d); pacing by the clock\n", errno);
    use_vblank_ = false;
  }
  if (!use_vblank_) wait_clock(&ns);
  drain(wake_fd_);
  runner.on_vsync(ns);
}

void LinuxPlatform::wake() {
  uint64_t one = 1;
  if (write(wake_fd_, &one, sizeof one) < 0) {
    // The counter is full: the emulator thread is already being woken.
  }
}

bool LinuxPlatform::draw_software(const dena_frame &f, int direction) {
  if (gl_.has_shader()) {
    gl_.set_direction(direction);
    if (!gl_.present_pixels(f.pixels, f.width, f.height)) return false;
  } else {
    mailbox.put(f.pixels, f.width, f.height);
  }
  if (cfg_.frame_ready) cfg_.frame_ready();
  return true;
}

bool LinuxPlatform::start_gpu(unsigned w, unsigned h, bool depth, bool stencil) {
  if (cfg_.gl_share.display == EGL_NO_DISPLAY) return false;
  return gl_.init(cfg_.gl_share, w, h, depth, stencil);
}

bool LinuxPlatform::draw_gpu(unsigned w, unsigned h, bool bottom_left, int direction) {
  gl_.set_direction(direction);
  if (!gl_.present(w, h, bottom_left)) return false;
  if (cfg_.frame_ready) cfg_.frame_ready();
  return true;
}

int LinuxPlatform::open_audio() {
  const char *card = cfg_.audio_card.empty() ? "default" : cfg_.audio_card.c_str();
  int rc = snd_pcm_open(&pcm_, card, SND_PCM_STREAM_PLAYBACK, 0);
  if (rc < 0) {
    std::fprintf(stderr, "dena: audio %s: %s\n", card, snd_strerror(rc));
    pcm_ = nullptr;
    return 0;
  }
  // performance.md: a hardware buffer of about half the latency setting.
  unsigned periods = unsigned(dena_audio_periods(runner.audio_latency_ms(), int(kPeriod), kAudioRate));
  rc = configure_pcm(pcm_, periods);
  if (rc <= 0) {
    std::fprintf(stderr, "dena: audio params: %s\n", snd_strerror(rc));
    snd_pcm_close(pcm_);
    pcm_ = nullptr;
    return 0;
  }
  const int rate = rc;
  xruns_ = 0;
  audio_paused_ = true;
  audio_quit_ = false;
  audio_thread_ = std::thread(&LinuxPlatform::audio_main, this);
  return rate;
}

bool LinuxPlatform::start_audio() {
  if (!pcm_) return false;
  {
    std::lock_guard<std::mutex> lk(audio_mtx_);
    audio_paused_ = false;
  }
  audio_cv_.notify_all();
  return true;
}

void LinuxPlatform::pause_audio() {
  std::lock_guard<std::mutex> lk(audio_mtx_);
  audio_paused_ = true;  // the audio thread drops the stream after this period
}

void LinuxPlatform::close_audio() {
  if (!audio_thread_.joinable()) return;
  {
    std::lock_guard<std::mutex> lk(audio_mtx_);
    audio_quit_ = true;
  }
  audio_cv_.notify_all();
  audio_thread_.join();
  snd_pcm_close(pcm_);
  pcm_ = nullptr;
}

// Only this thread touches pcm_ between open_audio and close_audio.
void LinuxPlatform::audio_main() {
  raise_audio_priority();
  std::vector<int16_t> buf(kPeriod * 2);
  bool running = false;
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(audio_mtx_);
      if (audio_paused_ && running) {
        snd_pcm_drop(pcm_);
        running = false;
      }
      audio_cv_.wait(lk, [this] { return audio_quit_ || !audio_paused_; });
      if (audio_quit_) break;
    }
    if (!running) {
      snd_pcm_prepare(pcm_);
      running = true;
    }
    runner.read_audio(buf.data(), uint32_t(kPeriod));
    snd_pcm_sframes_t n = snd_pcm_writei(pcm_, buf.data(), kPeriod);
    if (n < 0) {
      if (n == -EPIPE) xruns_++;
      if (snd_pcm_recover(pcm_, int(n), 1) < 0) {
        std::fprintf(stderr, "dena: audio: %s\n", snd_strerror(int(n)));
        running = false;
      }
    }
  }
  if (running) snd_pcm_drop(pcm_);
}

}  // namespace dena
