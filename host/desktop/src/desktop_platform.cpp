// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md
#include "desktop_platform.h"

#include <SDL3/SDL.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "dena/slang_preset.h"

namespace dena {

namespace {

constexpr int kAudioRate = 48000;
constexpr uint32_t kAudioChunk = 256;  // frames per read from the ring

// Shader output (shader-stacks.md, Platform): the default and the cap.
constexpr unsigned kDefaultOutW = 3840, kDefaultOutH = 2160;
constexpr unsigned kMaxOutW = 7680, kMaxOutH = 4320;

void *chain_proc(const char *sym) { return DesktopGl::proc_address(sym); }

}  // namespace

DesktopPlatform::DesktopPlatform(DesktopPlatformConfig cfg) : cfg_(std::move(cfg)) {
  set_refresh(cfg_.refresh_mhz);
  // The latency gate's "without frame generation" (frame-generation.md).
  fg_pacer_.set_context([this](double *input_p95, int *run_ahead) {
    *input_p95 = runner.input_p95_ms();
    *run_ahead = runner.run_ahead_frames();
  });
}

void DesktopPlatform::set_refresh(int mhz) {
  refresh_mhz_ = mhz > 0 ? mhz : 60000;
  fg_pacer_.configure(refresh_mhz_ / 1000.0, 0);
}

std::string DesktopPlatform::metrics_json() {
  std::string json = runner.metrics_json();
  const size_t end = json.rfind('}');
  if (end == std::string::npos) return json;
  return json.substr(0, end) + "," + fg_pacer_.metrics_fields() + "}";
}

DesktopPlatform::~DesktopPlatform() {
  runner.stop();
  close_audio();
}

void DesktopPlatform::thread_begin() {
  next_tick_ns_ = 0;
#ifdef _WIN32
  d3d_.init();
  d3d_.clear();
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
#else
  mailbox_.clear();
#endif
}

void DesktopPlatform::wait_clock(int64_t *ns) {
  const int64_t period = 1000000000000LL / refresh_mhz_;
  const int64_t now = now_ns();
  if (next_tick_ns_ == 0 || now - next_tick_ns_ > 100000000LL) next_tick_ns_ = now;
  next_tick_ns_ += period;
  const int64_t left = next_tick_ns_ - now_ns();
  if (left > 0) std::this_thread::sleep_for(std::chrono::nanoseconds(left));
  *ns = next_tick_ns_;
}

void DesktopPlatform::wait(bool want_frames) {
  // Paused with a real frame held back: it goes up first (frame-generation.md).
  if (!want_frames && fg_pacer_.holding()) show_held();
  if (!want_frames) {
    std::unique_lock<std::mutex> lk(wake_mtx_);
    wake_cv_.wait_for(lk, std::chrono::milliseconds(250), [this] { return woken_; });
    woken_ = false;
    return;
  }
  // Commands queued meanwhile run when this returns (at most one frame late).
  int64_t ns = 0;
#ifdef _WIN32
  bool vblank = false;
  if (clock_frames_ > 0) {
    clock_frames_--;
  } else {
    const int64_t before = now_ns();
    vblank = d3d_.wait_vblank(static_cast<HWND>(cfg_.window));
    ns = now_ns();
    // A sleeping display answers at once: pace by the clock for a while.
    if (vblank && ns - before < 500000) {
      if (++fast_vblanks_ > 5) {
        fast_vblanks_ = 0;
        clock_frames_ = 120;
      }
    } else {
      fast_vblanks_ = 0;
    }
  }
  if (!vblank) wait_clock(&ns);
#else
  // TODO(desktop): Wayland presentation feedback; until then the monitor's
  // refresh rate drives a clock (desktop-shell.md, Vsync).
  wait_clock(&ns);
#endif
  {
    std::lock_guard<std::mutex> lk(wake_mtx_);
    woken_ = false;
  }
  const uint64_t before = draws_;
  runner.on_vsync(ns);
  // A vsync without a new frame shows the real frame held for frame generation.
  if (draws_ == before && fg_pacer_.holding()) show_held();
}

void DesktopPlatform::wake() {
  {
    std::lock_guard<std::mutex> lk(wake_mtx_);
    woken_ = true;
  }
  wake_cv_.notify_all();
}

void DesktopPlatform::output_size(unsigned fw, unsigned fh, unsigned want_w, unsigned want_h,
                                  unsigned *w, unsigned *h) {
  if (want_w && want_h) {
    *w = std::min(want_w, kMaxOutW);
    *h = std::min(want_h, kMaxOutH);
    return;
  }
  // 4x the frame, shrunk (keeping its shape) to fit 3840x2160.
  double ow = double(fw) * 4, oh = double(fh) * 4;
  const double fit = std::min({1.0, kDefaultOutW / ow, kDefaultOutH / oh});
  *w = std::max(1u, unsigned(ow * fit + 0.5));
  *h = std::max(1u, unsigned(oh * fit + 0.5));
}

void DesktopPlatform::video_begin(bool hw, bool gpu_ok) {
  fg_pacer_.reset();
  fg_pacer_.configure(refresh_mhz_ / 1000.0, runner.fps());
  std::string err;
  if (!shader_path_.empty() && ((hw && !gpu_ok) || !load_shader(shader_path_, &err))) {
    std::fprintf(stderr, "dena: shader off: %s\n", err.empty() ? "no GL" : err.c_str());
    shader_path_.clear();
    if (!hw) shutdown_gl();
  }
  // Frame generation's GL set-up compiles shaders (tens of ms, ~100 ms on
  // some drivers): here, before the first frame reads input, not inside it
  // (frame-generation.md, Start-up).
  if (!hw || gpu_ok) apply_frame_gen(false);
}

// Emulator thread. Software cores get gl_ (a 16x16 framebuffer they never
// use) only while a shader is on; GPU cores already have it.
bool DesktopPlatform::load_shader(const std::string &path, std::string *err) {
  if (!gl_.ready()) {
    if (!gl_.init(16, 16, false, false)) {
      *err = "Shader stacks need OpenGL 4.2";
      return false;
    }
#ifdef _WIN32
    d3d_.attach_gl(&gl_);
#endif
  }
  if (!chain_.ready() && !chain_.init(chain_proc, err)) return false;
  return chain_.load(path, err);
}

void DesktopPlatform::shutdown_gl() {
  chain_.set_source_filter(nullptr);
  if (fg_.ready()) fg_.release(chain_.gl());
  fg_mode_ = 0;
  stock_only_ = false;
  fg_pacer_.drop_held();
#ifdef _WIN32
  d3d_.detach_gl();
#endif
  chain_.release();
  gl_.shutdown();
}

std::string DesktopPlatform::set_shader(const std::string &path) {
  std::string err;
  if (!path.empty()) {
    slang::Preset preset;  // catch unreadable presets before touching GL
    if (!slang::load_preset(path, &preset, &err)) return err;
  }
  if (!runner.running()) {
    shader_path_ = path;
    return "";
  }
  runner.run_on_emu([&] {
    if (path.empty()) {
      std::string stock_err;
      if (fg_mode_ && !stock_path_.empty() && chain_.load(stock_path_, &stock_err)) {
        stock_only_ = true;  // frame generation keeps the chain
      } else if (!runner.hw()) {
        shutdown_gl();  // a software core goes back to plain frames
      } else {
        chain_.unload();
      }
      shader_path_.clear();
      runner.repaint();
    } else if (load_shader(path, &err)) {
      shader_path_ = path;
      stock_only_ = false;
      runner.repaint();  // a paused game previews it
    } else if (!runner.hw() && !chain_.loaded()) {
      shutdown_gl();  // the first shader failed: stay on plain frames
    }
  });
  return err;
}

bool DesktopPlatform::start_gpu(unsigned w, unsigned h, bool depth, bool stencil) {
  if (!gl_.init(w, h, depth, stencil)) return false;
#ifdef _WIN32
  d3d_.attach_gl(&gl_);  // false: frames are read back instead
#endif
  return true;
}

void DesktopPlatform::stop_gpu() { shutdown_gl(); }

bool DesktopPlatform::put_frame(const uint32_t *xrgb, unsigned w, unsigned h) {
#ifdef _WIN32
  if (!d3d_.put_pixels(xrgb, w, h)) return false;
#else
  mailbox_.put(xrgb, w, h);
#endif
  draws_++;
  if (cfg_.frame_ready) cfg_.frame_ready();
  return true;
}

// Frame generation (frame-generation.md): the filter is set up when the
// pacer turns it on (the stock preset without a shader) and taken down when
// it goes off. in_game: a frame is being drawn, so the set-up time is a
// stall the player sees (frame_generation_setup_ms).
void DesktopPlatform::apply_frame_gen(bool in_game) {
  const int mode = fg_pacer_.mode();
  if (mode == fg_mode_) return;
  if (!mode) {
    stop_frame_gen();
    return;
  }
  const int64_t t0 = now_ns();
  set_up_frame_gen(mode);
  if (in_game) fg_pacer_.setup_ms(double(now_ns() - t0) / 1e6);
}

void DesktopPlatform::set_up_frame_gen(int mode) {
  std::string err;
  if (!chain_.loaded()) {
    if (runner.hw() && !gl_.ready()) err = "no GL";
    else if (stock_path_.empty()) err = "no stock preset";
    if (!err.empty() || !load_shader(stock_path_, &err)) {
      std::fprintf(stderr, "dena: frame generation off: %s\n", err.c_str());
      fg_pacer_.fail_gl();
      if (!runner.hw()) shutdown_gl();
      return;
    }
    stock_only_ = true;
  }
  if (!fg_.ready() && !fg_.init(chain_.gl(), &err)) {
    std::fprintf(stderr, "dena: frame generation off: %s\n", err.c_str());
    fg_pacer_.fail_gl();
    stop_frame_gen();
    return;
  }
  fg_.set_mode(mode);
  fg_.invalidate();
  chain_.set_source_filter(&fg_);
  fg_mode_ = mode;
}

void DesktopPlatform::stop_frame_gen() {
  chain_.set_source_filter(nullptr);
  fg_pacer_.drop_held();
  fg_mode_ = 0;
  if (!stock_only_) return;
  if (!runner.hw()) {
    shutdown_gl();
  } else {
    if (fg_.ready()) fg_.release(chain_.gl());
    chain_.unload();
    stock_only_ = false;
  }
}

// The real frame held back by frame generation, shaded again as it is.
void DesktopPlatform::show_held() {
  if (chain_.loaded() && chain_.render(held_out_w_, held_out_h_) &&
      show_output(held_out_w_, held_out_h_)) {
    fg_pacer_.held_shown(now_ns());
  } else {
    fg_pacer_.drop_held();
  }
}

// The chain's output to Flutter's texture (shader-stacks.md, Platform).
bool DesktopPlatform::draw_shaded(unsigned fw, unsigned fh) {
  unsigned nw = 0, nh = 0;
  runner.native_size(&nw, &nh);
  chain_.set_native_size(nw, nh);
  fg_.set_native_size(nw, nh);
  unsigned w, h;
  // The stock preset for frame generation alone: the frame's own size, as
  // without a shader (Flutter scales it).
  if (stock_only_) w = fw, h = fh;
  else output_size(fw, fh, out_w_, out_h_, &w, &h);
  bool generated = false;
  if (fg_mode_) {
    if (runner.fresh_draw()) {
      generated = fg_pacer_.on_real(now_ns(), fg_.has_previous(fw, fh)) ==
                  FrameGenPacer::kShowGenerated;
      fg_.next(generated ? slang::FrameGen::kGenerate : slang::FrameGen::kPush);
    } else {
      fg_pacer_.drop_held();  // a repaint, rewind or fast-forward replaces it
      fg_.invalidate();
    }
  }
  if (!chain_.render(w, h)) {
    if (generated) fg_pacer_.drop_held();
    return false;
  }
  if (fg_mode_) fg_pacer_.gpu_ms(fg_.take_gpu_ms(chain_.gl()));
  if (generated) held_out_w_ = w, held_out_h_ = h;
  return show_output(w, h);
}

bool DesktopPlatform::show_output(unsigned w, unsigned h) {
#ifdef _WIN32
  if (d3d_.gl_attached()) {
    if (!d3d_.put_gl(w, h, false, chain_.output_framebuffer())) return false;
    draws_++;
    if (cfg_.frame_ready) cfg_.frame_ready();
    return true;
  }
#endif
  if (!chain_.read_output(&readback_)) return false;
  for (uint32_t &p : readback_) p &= 0x00ffffffu;
  return put_frame(readback_.data(), w, h);
}

bool DesktopPlatform::draw_software(const dena_frame &f, int direction) {
  apply_frame_gen();
  if (chain_.loaded()) {
    chain_.set_direction(direction);
    if (chain_.upload(f.pixels, f.width, f.height) && draw_shaded(f.width, f.height)) return true;
  }
  return put_frame(f.pixels, f.width, f.height);
}

bool DesktopPlatform::draw_gpu(unsigned w, unsigned h, bool bottom_left, int direction) {
  apply_frame_gen();
  if (chain_.loaded()) {
    chain_.set_direction(direction);
    if (chain_.copy_from(GLuint(gl_.framebuffer()), w, h, bottom_left) && draw_shaded(w, h))
      return true;
  }
#ifdef _WIN32
  if (d3d_.gl_attached()) {
    if (!d3d_.put_gl(w, h, bottom_left)) return false;
    draws_++;
    if (cfg_.frame_ready) cfg_.frame_ready();
    return true;
  }
#endif
  if (!gl_.read_pixels(w, h, bottom_left, readback_)) return false;
  return put_frame(readback_.data(), w, h);
}

void DesktopPlatform::audio_callback(void *user, SDL_AudioStream *stream, int additional, int) {
  auto *self = static_cast<DesktopPlatform *>(user);
  uint32_t frames = uint32_t(additional > 0 ? additional : 0) / 4;  // S16 stereo
  self->audio_buf_.resize(kAudioChunk * 2);
  while (frames > 0) {
    const uint32_t n = frames < kAudioChunk ? frames : kAudioChunk;
    self->runner.read_audio(self->audio_buf_.data(), n);
    uint32_t start = self->chime_pos_.load();
    if (start < dena::kChimeFrames) {
      uint32_t pos = start;
      dena::mix_chime(self->audio_buf_.data(), n, &pos);
      // A chime() meanwhile restarts it; keep that.
      self->chime_pos_.compare_exchange_strong(start, pos);
    }
    SDL_PutAudioStreamData(stream, self->audio_buf_.data(), int(n * 4));
    frames -= n;
  }
}

int DesktopPlatform::open_audio() {
  if (!audio_ || audio_stream_) return audio_stream_ ? kAudioRate : 0;
  SDL_AudioSpec spec{SDL_AUDIO_S16, 2, kAudioRate};
  audio_stream_ = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_callback, this);
  if (!audio_stream_) {
    std::fprintf(stderr, "dena: audio: %s\n", SDL_GetError());
    return 0;
  }
  return kAudioRate;  // the stream converts to the device's own format
}

bool DesktopPlatform::start_audio() { return audio_stream_ && SDL_ResumeAudioStreamDevice(audio_stream_); }

void DesktopPlatform::pause_audio() {
  if (!audio_stream_) return;
  SDL_PauseAudioStreamDevice(audio_stream_);
  SDL_ClearAudioStream(audio_stream_);
}

void DesktopPlatform::close_audio() {
  if (!audio_stream_) return;
  SDL_DestroyAudioStream(audio_stream_);  // also closes the device
  audio_stream_ = nullptr;
}

}  // namespace dena
