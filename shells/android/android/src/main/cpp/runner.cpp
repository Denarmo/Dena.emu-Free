// Native emulator runner for Android: the shared play loop (host/runner,
// shared-runner.md) paced by AChoreographer, CPU blit into an ANativeWindow
// (or GLES when a GPU core or a shader needs it), Oboe audio.
// Spec: docs/specs/latency-spike.md, docs/specs/shaders.md
// SPDX-License-Identifier: GPL-3.0-or-later

#include <android/choreographer.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <jni.h>
#include <sys/resource.h>
#include <unistd.h>
#include <oboe/Oboe.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "achievements.h"
#include "dena/shader_preset.h"
#include "gl_presenter.h"
#include "runner.h"

#define LOG_TAG "Dena"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// Result of set_shader() (shaders.md).
enum ShaderResult { kShaderError = -1, kShaderOk = 0, kShaderNeedsSurface = 1 };

constexpr int kEmuThreadNice = -10;  // ANDROID_PRIORITY_URGENT_DISPLAY - 2

// Android Dynamic Performance Framework (API 33+, performance.md): tells the
// CPU governor how long each vsync's work takes against a 16.6 ms target, so
// it raises clocks before a frame is missed instead of after. Loaded with
// dlsym because minSdk is 26; does nothing on older devices.
class PerfHint {
 public:
  void begin(pid_t tid) {
    using GetManager = void *(*)();
    using Create = void *(*)(void *, const int32_t *, size_t, int64_t);
    void *lib = dlopen("libandroid.so", RTLD_NOW);
    if (!lib) return;
    auto get = reinterpret_cast<GetManager>(dlsym(lib, "APerformanceHint_getManager"));
    auto create = reinterpret_cast<Create>(dlsym(lib, "APerformanceHint_createSession"));
    report_ = reinterpret_cast<Report>(dlsym(lib, "APerformanceHint_reportActualWorkDuration"));
    close_ = reinterpret_cast<Close>(dlsym(lib, "APerformanceHint_closeSession"));
    if (!get || !create || !report_ || !close_) return;
    void *mgr = get();
    int32_t t = int32_t(tid);
    if (mgr) session_ = create(mgr, &t, 1, kTargetNs);
  }
  void report(int64_t work_ns) {
    if (session_ && work_ns > 0) report_(session_, work_ns);
  }
  void end() {
    if (session_) close_(session_);
    session_ = nullptr;
  }

 private:
  using Report = int (*)(void *, int64_t);
  using Close = void (*)(void *);
  static constexpr int64_t kTargetNs = 16666667;
  void *session_ = nullptr;
  Report report_ = nullptr;
  Close close_ = nullptr;
};

class AndroidRunner : public dena::RunnerPlatform, public oboe::AudioStreamDataCallback {
 public:
  dena::Runner runner{this};

  ~AndroidRunner() override { stop(); }

  int start(const std::string &core, const std::string &rom, const std::string &sysdir,
            const std::string &srm, const std::string &state) {
    // Achievements watch every played frame; hardcore follows the loaded game.
    runner.set_frame_hook([this](dena_core *c) {
      dena_ra_frame(c);
      runner.set_hardcore(dena_ra_hardcore_active() != 0);
    });
    runner.set_hardcore(false);
    // shaders.md, Upscale: a core with no resolution option is upscaled by
    // the filter instead (the app offers it for GB, GBC and DS only).
    prescale_ = upscale_ >= 2 && dena::Runner::max_upscale(core) < 2 && !upscale_path_.empty()
                    ? unsigned(upscale_)
                    : 0;
    int rc = runner.start(core, rom, sysdir, srm, state);
    if (rc >= 0) runner.run_on_emu([this] {
        unsigned w = 0, h = 0;
        runner.native_size(&w, &h);
        gl_.set_native_size(w, h);
      });
    return rc;
  }

  void stop() {
    runner.stop();
    set_window(nullptr);
    shader_path_.clear();
    gl_sw_ = gl_sw_pending_ = false;
  }

  // Internal resolution for the next start, and the filter preset used where
  // the core has no resolution option (shaders.md, Upscale).
  void set_upscale(int factor, const std::string &filter_path) {
    upscale_ = factor;
    upscale_path_ = filter_path;
    runner.set_upscale(factor);
  }

  void set_window(ANativeWindow *w) {
    // GPU mode: the EGL surface must let go of the old window before it is
    // released (surfaceDestroyed must not return while it is still in use).
    if (runner.running()) runner.run_on_emu([this] {
        if (gl_.ready()) gl_.set_window(nullptr);
      });
    {
      std::lock_guard<std::mutex> lk(win_mtx_);
      if (window_) ANativeWindow_release(window_);
      window_ = w;
      configured_ = false;
      fresh_window_ = w != nullptr;
    }
    wake();
    // A new surface while paused (the pause sheet's shader preview, or the
    // surface recreated for a shader) shows the last frame at once.
    if (w && runner.running()) runner.run_on_emu([this] {
        if (gl_sw_pending_) switch_to_gl();
        if (runner.paused()) runner.repaint();
      });
  }

  // Shader preset path, "" for Off (shaders.md). Before start it only
  // remembers the path. A software core still on the CPU blit needs a window
  // the CPU has not used (kShaderNeedsSurface): the shell recreates the
  // surface and the switch happens when it arrives.
  int set_shader(const std::string &path, std::string *err) {
    if (!path.empty()) {
      dena::ShaderPreset preset;  // catch unreadable presets before the switch
      if (!dena::parse_preset(path, &preset, err)) return kShaderError;
    }
    if (!runner.running()) {
      shader_path_ = path;
      return kShaderOk;
    }
    int rc = kShaderOk;
    runner.run_on_emu([&] {
      if (gl_.ready()) {
        if (!gl_.set_shader(path, err)) {
          rc = kShaderError;
          return;
        }
        shader_path_ = path;
        runner.repaint();
      } else if (!path.empty()) {
        shader_path_ = path;
        gl_sw_pending_ = true;
        rc = kShaderNeedsSurface;
      } else {
        shader_path_.clear();
        gl_sw_pending_ = false;
      }
    });
    return rc;
  }

  // ---- RunnerPlatform: emulator thread ----

  void thread_begin() override {
    looper_ = ALooper_prepare(0);
    choreographer_ = AChoreographer_getInstance();
    callback_posted_ = false;  // a callback pending at the last stop() died with its looper
    // performance.md: the emulator thread runs at display priority (like the
    // UI thread) so background work cannot delay a frame.
    if (setpriority(PRIO_PROCESS, 0, kEmuThreadNice) != 0) LOGE("emulator thread priority not raised");
    hint_.begin(gettid());
  }

  void video_begin(bool hw, bool gpu_ok) override {
    // A shader or the filter upscale chosen before start draws software
    // cores through GLES from the first frame (shaders.md).
    gl_sw_ = !hw && (!shader_path_.empty() || prescale_);
    gl_sw_pending_ = false;
    if (gl_sw_ && !start_gl_sw()) {  // no GLES for the shader: the CPU blit still works
      gl_sw_ = false;
      shader_path_.clear();
      prescale_ = 0;
    } else if (hw && gpu_ok && !shader_path_.empty()) {
      load_start_shader();
    }
  }

  void thread_end() override {
    hint_.end();
    looper_ = nullptr;
  }

  void wait(bool want_frames) override {
    if (want_frames && !callback_posted_) {
      AChoreographer_postFrameCallback(choreographer_, &AndroidRunner::frame_cb, this);
      callback_posted_ = true;
    }
    // Woken by the frame callback, by commands and by surface changes.
    ALooper_pollOnce(want_frames ? 100 : 250, nullptr, nullptr, nullptr);
  }

  void wake() override {
    if (ALooper *l = looper_.load()) ALooper_wake(l);
  }

  bool has_surface() override {
    std::lock_guard<std::mutex> lk(win_mtx_);
    return window_ != nullptr;
  }

  bool start_gpu(unsigned w, unsigned h, bool depth, bool stencil) override {
    return gl_.init(w, h, depth, stencil);
  }
  bool gpu_ready() override { return gl_.ready(); }
  uintptr_t gpu_framebuffer() override { return gl_.framebuffer(); }
  void *gl_proc_address(const char *sym) override { return GlPresenter::proc_address(sym); }
  void stop_gpu() override { gl_.shutdown(); }

  bool draw_software(const dena_frame &f, int direction) override {
    std::lock_guard<std::mutex> lk(win_mtx_);
    if (!window_) return false;
    if (gl_sw_pending_) switch_to_gl();
    if (gl_sw_) {
      gl_.set_window(window_);
      gl_.set_direction(direction);
      gl_.present_pixels(f.pixels, f.width, f.height);
      return true;
    }
    fresh_window_ = false;  // CPU-connected from here on
    if (!configured_ || cfg_w_ != f.width || cfg_h_ != f.height) {
      ANativeWindow_setBuffersGeometry(window_, int32_t(f.width), int32_t(f.height),
                                       WINDOW_FORMAT_RGBX_8888);
      cfg_w_ = f.width;
      cfg_h_ = f.height;
      configured_ = true;
    }
    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window_, &buf, nullptr) != 0) return false;
    uint32_t w = std::min<uint32_t>(f.width, uint32_t(buf.width));
    uint32_t h = std::min<uint32_t>(f.height, uint32_t(buf.height));
    for (uint32_t y = 0; y < h; y++) {
      const uint32_t *src = f.pixels + size_t(y) * f.width;
      uint32_t *dst = static_cast<uint32_t *>(buf.bits) + size_t(y) * size_t(buf.stride);
      for (uint32_t x = 0; x < w; x++) {
        uint32_t v = src[x];  // 0x00RRGGBB -> bytes R,G,B,X (little endian)
        dst[x] = ((v >> 16) & 0xff) | (v & 0xff00) | ((v & 0xff) << 16) | 0xff000000u;
      }
    }
    ANativeWindow_unlockAndPost(window_);
    return true;
  }

  bool draw_gpu(unsigned w, unsigned h, bool bottom_left, int direction) override {
    {
      std::lock_guard<std::mutex> lk(win_mtx_);
      gl_.set_window(window_);
    }
    gl_.set_direction(direction);
    gl_.present(w, h, bottom_left);
    return true;
  }

  bool read_pixels(unsigned w, unsigned h, bool flip_y, std::vector<uint32_t> &out) override {
    return gl_.read_pixels(w, h, flip_y, out);
  }

  // ---- RunnerPlatform: audio ----

  int open_audio() override {
    oboe::AudioStreamBuilder b;
    b.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setFormat(oboe::AudioFormat::I16)
        ->setChannelCount(oboe::ChannelCount::Stereo)
        ->setUsage(oboe::Usage::Game)
        ->setDataCallback(this);
    if (b.openStream(stream_) != oboe::Result::OK) {
      stream_.reset();
      return 0;
    }
    LOGI("audio: %d Hz, burst %d, exclusive=%d", stream_->getSampleRate(),
         stream_->getFramesPerBurst(), stream_->getSharingMode() == oboe::SharingMode::Exclusive);
    return stream_->getSampleRate();
  }

  bool start_audio() override {
    return stream_ && stream_->requestStart() == oboe::Result::OK;
  }

  void pause_audio() override {
    if (stream_) stream_->requestPause();
  }

  void close_audio() override {
    if (stream_) {
      stream_->stop();
      stream_->close();
      stream_.reset();
    }
  }

  int audio_xruns() override {
    if (!stream_) return 0;
    auto r = stream_->getXRunCount();
    return r ? r.value() : 0;
  }

  // Oboe callback: audio thread.
  oboe::DataCallbackResult onAudioReady(oboe::AudioStream *, void *data,
                                        int32_t frames) override {
    runner.read_audio(static_cast<int16_t *>(data), uint32_t(frames));
    return oboe::DataCallbackResult::Continue;
  }

 private:
  static void frame_cb(long frame_time_nanos, void *self) {
    auto *r = static_cast<AndroidRunner *>(self);
    r->callback_posted_ = false;
    int64_t t0 = dena::now_ns();
    r->runner.on_vsync(int64_t(frame_time_nanos));
    r->hint_.report(dena::now_ns() - t0);
  }

  // Software core drawn through GLES (shaders.md). Emulator thread.
  bool start_gl_sw() {
    if (!gl_.init_context()) {
      LOGE("GLES could not start; shaders are off");
      return false;
    }
    load_start_shader();
    load_prescale();
    return true;
  }

  void load_start_shader() {
    std::string err;
    if (!gl_.set_shader(shader_path_, &err)) LOGE("shader: %s", err.c_str());
  }

  // A filter that fails to load leaves the picture at native size.
  void load_prescale() {
    std::string err;
    if (!gl_.set_prescale(upscale_path_, prescale_, &err)) LOGE("upscale: %s", err.c_str());
  }

  // CPU blit to GLES on a window the CPU has not used yet. Emulator thread.
  void switch_to_gl() {
    if (!fresh_window_) return;
    if (!gl_.init_context()) {
      LOGE("GLES could not start; shaders are off");
      gl_sw_pending_ = false;
      return;
    }
    gl_sw_ = true;
    gl_sw_pending_ = false;
    load_start_shader();
    load_prescale();
  }

  std::atomic<ALooper *> looper_{nullptr};
  AChoreographer *choreographer_ = nullptr;
  PerfHint hint_;
  bool callback_posted_ = false;

  GlPresenter gl_;  // emulator thread only
  // Software core drawn through GLES (shaders.md); emulator thread after start.
  bool gl_sw_ = false;
  bool gl_sw_pending_ = false;  // switch once a window the CPU hasn't used arrives
  std::string shader_path_;
  int upscale_ = 0;
  std::string upscale_path_;
  unsigned prescale_ = 0;  // filter upscale factor of the running game (0: off)

  std::mutex win_mtx_;
  ANativeWindow *window_ = nullptr;
  bool configured_ = false;
  std::atomic<bool> fresh_window_{false};  // not yet locked by the CPU blit
  uint32_t cfg_w_ = 0, cfg_h_ = 0;

  std::shared_ptr<oboe::AudioStream> stream_;
};

AndroidRunner g_android;  // one core per process (libretro callbacks are global)
dena::Runner &g_runner = g_android.runner;

}  // namespace

// dart:ffi entry point for touch controls (skins.md): the hot path never
// crosses a method channel.
extern "C" __attribute__((visibility("default"))) void dena_touch_buttons(int32_t mask) {
  g_runner.set_touch(mask, dena::now_ns());
}

// dart:ffi entry point for turbo buttons (turbo.md); applies to touch and
// gamepads alike.
extern "C" __attribute__((visibility("default"))) void dena_set_turbo(int32_t mask,
                                                                      int32_t half_frames) {
  g_runner.set_turbo(mask, half_frames);
}

// dart:ffi entry point for a touch analog stick (n64.md).
extern "C" __attribute__((visibility("default"))) void dena_touch_analog(int32_t stick, int32_t x,
                                                                         int32_t y) {
  g_runner.set_touch_analog(stick, x, y);
}

// dart:ffi entry point for the touch screen (ds.md).
extern "C" __attribute__((visibility("default"))) void dena_touch_pointer(int32_t x, int32_t y,
                                                                          int32_t pressed) {
  g_runner.set_pointer(x, y, pressed != 0);
}

// dart:ffi entry point for a held Rewind control (rewind.md).
extern "C" __attribute__((visibility("default"))) void dena_rewind_hold(int32_t on) {
  g_runner.set_rewinding(on != 0);
}

// dart:ffi entry points for the host mailbox in system RAM: the PICO-8
// launcher cart's GPIO bytes (pico8-launcher-cart.md). Bytes pass through
// one buffer that Dart views (main isolate only).
static uint8_t g_ram_buffer[256];

extern "C" __attribute__((visibility("default"))) uint8_t *dena_ram_buffer() {
  return g_ram_buffer;
}

extern "C" __attribute__((visibility("default"))) void dena_ram_watch(int32_t offset, int32_t len) {
  if (offset >= 0 && len >= 0) g_runner.watch_ram(size_t(offset), size_t(len));
}

// Copies the latest snapshot into the buffer; 1 on success.
extern "C" __attribute__((visibility("default"))) int32_t dena_ram_read(int32_t len) {
  return len >= 0 && len <= int32_t(sizeof g_ram_buffer) &&
                 g_runner.read_ram(g_ram_buffer, size_t(len))
             ? 1
             : 0;
}

// Queues the buffer's first len bytes for system RAM at offset.
extern "C" __attribute__((visibility("default"))) void dena_ram_write(int32_t offset, int32_t len) {
  if (offset >= 0 && len >= 0 && len <= int32_t(sizeof g_ram_buffer))
    g_runner.write_ram(size_t(offset), g_ram_buffer, size_t(len));
}

namespace {

std::string jstr(JNIEnv *env, jstring s) {
  if (!s) return {};
  const char *c = env->GetStringUTFChars(s, nullptr);
  std::string out(c);
  env->ReleaseStringUTFChars(s, c);
  return out;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativeStart(
    JNIEnv *env, jobject, jstring core, jstring rom, jstring sysdir, jstring srm,
    jstring state) {
  return g_android.start(jstr(env, core), jstr(env, rom), jstr(env, sysdir), jstr(env, srm),
                         jstr(env, state));
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetUpscale(
    JNIEnv *env, jobject, jint factor, jstring filter_path) {
  g_android.set_upscale(factor, jstr(env, filter_path));
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativePause(JNIEnv *, jobject) {
  g_runner.pause();
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeResume(JNIEnv *, jobject) {
  g_runner.resume();
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetSpeed(JNIEnv *, jobject,
                                                                                jint n) {
  g_runner.set_speed(n);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetAudioLatency(
    JNIEnv *, jobject, jint ms) {
  g_runner.set_audio_latency_ms(ms);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeConfigureRewind(
    JNIEnv *, jobject, jboolean enabled, jboolean l2_hold) {
  g_runner.configure_rewind(enabled, l2_hold);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetRewinding(JNIEnv *, jobject,
                                                                                   jboolean on) {
  g_runner.set_rewinding(on);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSaveNow(JNIEnv *, jobject) {
  g_runner.save_now();
}

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSaveState(JNIEnv *env, jobject,
                                                                               jstring state,
                                                                               jstring png) {
  return g_runner.save_state(jstr(env, state), jstr(env, png));
}

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativeScreenshot(JNIEnv *env, jobject,
                                                                                jstring path) {
  return g_runner.screenshot(jstr(env, path));
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetCheats(JNIEnv *env, jobject,
                                                                               jobjectArray codes) {
  std::vector<std::string> v;
  jsize n = codes ? env->GetArrayLength(codes) : 0;
  for (jsize i = 0; i < n; i++) {
    auto s = static_cast<jstring>(env->GetObjectArrayElement(codes, i));
    v.push_back(jstr(env, s));
    env->DeleteLocalRef(s);
  }
  g_runner.set_cheats(std::move(v));
}

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativeLoadState(JNIEnv *env, jobject,
                                                                               jstring state) {
  return g_runner.load_state(jstr(env, state));
}

JNIEXPORT jstring JNICALL Java_app_dena_dena_1android_NativeRunner_nativeLastError(
    JNIEnv *env, jobject) {
  return env->NewStringUTF(g_runner.error().c_str());
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetSurface(
    JNIEnv *env, jobject, jobject surface) {
  g_android.set_window(surface ? ANativeWindow_fromSurface(env, surface) : nullptr);
}

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetShader(
    JNIEnv *env, jobject, jstring path) {
  std::string err;
  int rc = g_android.set_shader(jstr(env, path), &err);
  if (rc < 0) g_runner.set_error(err);
  return rc;
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetButtons(
    JNIEnv *, jobject, jint port, jint mask, jlong event_time_ms) {
  // KeyEvent times are SystemClock.uptimeMillis(), i.e. CLOCK_MONOTONIC.
  g_runner.set_buttons(port, mask, int64_t(event_time_ms) * 1000000LL);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeSetAnalog(
    JNIEnv *, jobject, jint port, jint lx, jint ly, jint rx, jint ry) {
  g_runner.set_analog(port, lx, ly, rx, ry);
}

JNIEXPORT jstring JNICALL Java_app_dena_dena_1android_NativeRunner_nativeMetrics(
    JNIEnv *env, jobject) {
  return env->NewStringUTF(g_runner.metrics_json().c_str());
}

JNIEXPORT jint JNICALL Java_app_dena_dena_1android_NativeRunner_nativePixel(
    JNIEnv *, jobject, jint x, jint y) {
  return g_runner.pixel(x, y);
}

JNIEXPORT void JNICALL Java_app_dena_dena_1android_NativeRunner_nativeStop(JNIEnv *,
                                                                            jobject) {
  g_android.stop();
}

}  // extern "C"
