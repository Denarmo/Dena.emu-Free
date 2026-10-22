// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-session.md
#include "session.h"

#include <cstdlib>
#include <cstring>
#include <memory>

#include "achievements.h"
#include "dena/input.h"
#include "dena/platform.h"
#include "game_bridge.h"
#include "linux_platform.h"

namespace {

class RunnerHost : public dena::GameHost {
 public:
  explicit RunnerHost(dena::LinuxPlatform &p) : p_(p), r_(p.runner) {}
  int start(const std::string &core, const std::string &rom, const std::string &sysdir,
            const std::string &srm, const std::string &state) override {
    // Achievements watch every played frame; hardcore follows the loaded game
    // (achievements.md), as on Android.
    r_.set_frame_hook([this](dena_core *c) {
      dena_ra_frame(c);
      r_.set_hardcore(dena_ra_hardcore_active() != 0);
    });
    r_.set_hardcore(false);
    return r_.start(core, rom, sysdir, srm, state);
  }
  std::string error() override { return r_.error(); }
  void pause() override { r_.pause(); }
  void resume() override { r_.resume(); }
  void set_speed(int n) override { r_.set_speed(n); }
  void set_audio_latency_ms(int ms) override { r_.set_audio_latency_ms(ms); }
  void set_upscale(int factor) override { r_.set_upscale(factor); }
  void set_widescreen(bool on) override { r_.set_widescreen(on); }
  void configure_rewind(bool enabled, bool l2) override { r_.configure_rewind(enabled, l2); }
  void set_rewinding(bool on) override { r_.set_rewinding(on); }
  void save_now() override { r_.save_now(); }
  int save_state(const std::string &s, const std::string &png) override {
    return r_.save_state(s, png);
  }
  int load_state(const std::string &s) override { return r_.load_state(s); }
  int screenshot(const std::string &png) override { return r_.screenshot(png); }
  void set_cheats(std::vector<std::string> codes) override { r_.set_cheats(std::move(codes)); }
  std::string set_shader(const std::string &path) override { return p_.set_shader(path); }
  void stop() override { p_.stop_session(); }

 private:
  dena::LinuxPlatform &p_;
  dena::Runner &r_;
};

struct Session {
  dena_session_config cfg;
  std::unique_ptr<dena::LinuxPlatform> platform;
  std::unique_ptr<RunnerHost> host;
  std::unique_ptr<dena::GameBridge> bridge;
  struct dena_game_input keys = {};  // buttons held, presses the game took
};

Session *g_session;

void menu_requested(Session &s) {
  s.platform->runner.set_buttons(0, 0, dena::now_ns());
  std::vector<uint8_t> msg = dena::encode_menu_requested();
  std::string channel = std::string(dena::kGameEventsChannel) + "onMenuRequested";
  if (s.cfg.send) s.cfg.send(s.cfg.user, channel.c_str(), msg.data(), msg.size());
}

}  // namespace

extern "C" void dena_session_init(const dena_session_config *cfg) {
  auto *s = new Session();
  s->cfg = *cfg;
  dena::LinuxPlatformConfig pc;
  pc.drm_fd = cfg->drm_fd;
  pc.crtc_index = cfg->crtc_index;
  pc.refresh_mhz = cfg->refresh_mhz;
  pc.screen_w = unsigned(cfg->screen_width);
  pc.screen_h = unsigned(cfg->screen_height);
  if (cfg->audio_card && *cfg->audio_card) pc.audio_card = cfg->audio_card;
  if (cfg->egl_display) {
    pc.gl_share.display = static_cast<EGLDisplay>(cfg->egl_display);
    pc.gl_share.context = static_cast<EGLContext>(cfg->egl_share_context);
  }
  pc.frame_ready = [s] {
    if (s->cfg.frame_ready) s->cfg.frame_ready(s->cfg.user);
  };
  s->platform = std::make_unique<dena::LinuxPlatform>(pc);
  s->host = std::make_unique<RunnerHost>(*s->platform);
  s->bridge = std::make_unique<dena::GameBridge>(s->host.get(), cfg->card ? cfg->card : ".");
  g_session = s;
}

extern "C" void dena_session_shutdown(void) {
  delete g_session;  // the platform stops the runner, which saves
  g_session = nullptr;
}

extern "C" bool dena_session_message(const char *channel, const uint8_t *msg, size_t len,
                                     uint8_t **reply, size_t *reply_len) {
  if (!g_session) return false;
  std::vector<uint8_t> out;
  if (!g_session->bridge->handle(channel, msg, len, out)) return false;
  // A new game starts with no buttons held and a fresh picture.
  if (std::strcmp(channel, "dev.flutter.pigeon.dena_android.GameHostApi.start") == 0) {
    g_session->keys = {};
  }
  *reply_len = out.size();
  *reply = static_cast<uint8_t *>(std::malloc(out.empty() ? 1 : out.size()));
  if (*reply && !out.empty()) std::memcpy(*reply, out.data(), out.size());
  return *reply != nullptr;
}

// dart:ffi entry points for the host mailbox in system RAM: the PICO-8
// launcher cart's GPIO bytes (pico8-launcher-cart.md). Dart finds them in
// the launcher process (ENABLE_EXPORTS). Bytes pass through one buffer that
// Dart views (main isolate only).
static uint8_t g_ram_buffer[256];

extern "C" __attribute__((visibility("default"))) uint8_t *dena_ram_buffer() {
  return g_ram_buffer;
}

extern "C" __attribute__((visibility("default"))) void dena_ram_watch(int32_t offset, int32_t len) {
  if (g_session && offset >= 0 && len >= 0)
    g_session->platform->runner.watch_ram(size_t(offset), size_t(len));
}

// Copies the latest snapshot into the buffer; 1 on success.
extern "C" __attribute__((visibility("default"))) int32_t dena_ram_read(int32_t len) {
  return g_session && len >= 0 && len <= int32_t(sizeof g_ram_buffer) &&
                 g_session->platform->runner.read_ram(g_ram_buffer, size_t(len))
             ? 1
             : 0;
}

// Queues the buffer's first len bytes for system RAM at offset.
extern "C" __attribute__((visibility("default"))) void dena_ram_write(int32_t offset, int32_t len) {
  if (g_session && offset >= 0 && len >= 0 && len <= int32_t(sizeof g_ram_buffer))
    g_session->platform->runner.write_ram(size_t(offset), g_ram_buffer, size_t(len));
}

// dart:ffi entry point for turbo buttons (turbo.md): the same symbol as
// libdena_android.so, looked up in the launcher process.
extern "C" __attribute__((visibility("default"))) void dena_set_turbo(int32_t mask,
                                                                      int32_t half_frames) {
  if (g_session) g_session->platform->runner.set_turbo(mask, half_frames);
}

extern "C" bool dena_session_playing(void) {
  return g_session && g_session->platform->runner.running() && !g_session->platform->runner.paused();
}

extern "C" bool dena_session_input(int action, bool down, int64_t event_ns) {
  Session *s = g_session;
  if (!s) return false;
  switch (dena_game_input(&s->keys, action, down, dena_session_playing())) {
    case DENA_GAME_IGNORED:
      return false;
    case DENA_GAME_TAKEN:
      return true;
    case DENA_GAME_BUTTONS:
      s->platform->runner.set_buttons(0, int(s->keys.mask), event_ns);
      return true;
    case DENA_GAME_MENU:
      menu_requested(*s);
      return true;
  }
  return false;
}

extern "C" unsigned dena_session_gpu_frame(uint32_t *width, uint32_t *height) {
  return g_session ? g_session->platform->gpu_texture(width, height) : 0;
}

extern "C" bool dena_session_frame(const uint8_t **rgba, uint32_t *width, uint32_t *height,
                                   bool *fresh) {
  if (!g_session) return false;
  const dena::MailFrame *f = g_session->platform->mailbox.take(fresh);
  if (!f) return false;
  *rgba = f->rgba.data();
  *width = f->width;
  *height = f->height;
  return true;
}
