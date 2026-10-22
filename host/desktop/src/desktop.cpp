// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop host library's C interface (dena/desktop.h) and the dart:ffi
// entry points the shared Dart code looks up (the same names as
// libdena_android.so and the handheld launcher).
// Spec: docs/specs/desktop-shell.md
#include "dena/desktop.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <timeapi.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

#include "achievements.h"
#include "desktop_map.h"
#include "desktop_platform.h"
#include "game_bridge.h"
#include "pad_profile.h"
#include "sdl_input.h"

namespace fs = std::filesystem;

namespace {

#ifdef _WIN32
constexpr bool kWindows = true;
#else
constexpr bool kWindows = false;
#endif

const char kMethods[] =
    "start\npause\nresume\nsetSpeed\nsetAudioLatency\nconfigureRewind\nsetDisplayAspect\n"
    "setAnalogMode\nsetRewinding\nsaveNow\nsaveState\nloadState\nsetCheats\nsetTouchMode\n"
    "setShader\nsetUpscale\nsetWidescreen\ncaptureScreenshot\nstop";

bool file_exists(const std::string &path) {
  std::error_code ec;
  return fs::is_regular_file(fs::u8path(path), ec);
}

// The folder this library was loaded from (cores/ sits next to it).
std::string library_dir() {
#ifdef _WIN32
  HMODULE self = nullptr;
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCSTR>(&library_dir), &self);
  // UTF-8 whatever the process code page (every path in the host is UTF-8).
  wchar_t wide[MAX_PATH * 4];
  const DWORD wn = GetModuleFileNameW(self, wide, MAX_PATH * 4);
  const int n = WideCharToMultiByte(CP_UTF8, 0, wide, int(wn), nullptr, 0, nullptr, nullptr);
  std::string p(size_t(n > 0 ? n : 0), '\0');
  if (n > 0) WideCharToMultiByte(CP_UTF8, 0, wide, int(wn), &p[0], n, nullptr, nullptr);
  for (char &c : p)
    if (c == '\\') c = '/';
#else
  Dl_info info{};
  std::string p = dladdr(reinterpret_cast<void *>(&library_dir), &info) && info.dli_fname
                      ? info.dli_fname
                      : "";
#endif
  const size_t slash = p.find_last_of('/');
  return slash == std::string::npos ? "." : p.substr(0, slash);
}

struct Session;

class RunnerHost : public dena::GameHost {
 public:
  explicit RunnerHost(Session &s);
  int start(const std::string &core, const std::string &rom, const std::string &sysdir,
            const std::string &srm, const std::string &state) override;
  std::string error() override { return r_.error(); }
  void pause() override;
  void resume() override;
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
  // Slang shader stacks (shader-stacks.md).
  std::string set_shader(const std::string &path) override;
  std::string shader_path(const std::string &id) override;
  void stop() override;

 private:
  std::string resolve_core(const std::string &name) const;

  Session &s_;
  dena::Runner &r_;

 public:
  std::string core_path, rom_path;  // of the running game (netplay)
};

struct Session {
  dena_desktop_config cfg{};
  std::string root = ".";
  std::string lib_dir;
  dena::SdlInput input;
  std::unique_ptr<dena::DesktopPlatform> platform;
  std::unique_ptr<RunnerHost> host;
  std::unique_ptr<dena::GameBridge> bridge;

  std::atomic<bool> active{false};   // a game is loaded
  std::atomic<bool> playing{false};  // ... and not paused
  bool slept_playing = false;        // main thread: suspend paused the game
  std::atomic<bool> touch_recent{false};

  // Buttons per port from the pads (SDL thread writes) and the keyboard
  // (main thread), combined into port 0.
  std::atomic<uint32_t> pad_mask[dena::kDesktopPorts] = {};
  std::atomic<uint32_t> key_mask{0};
  bool menu_latched[dena::kDesktopPorts] = {};  // SDL thread
  // Controller navigation (controller-mode.md): the Dart listener and each
  // pad's UI mask as last seen (SDL thread).
  std::atomic<dena_desktop_ui_fn> ui_fn{nullptr};
  std::map<uint32_t, uint32_t> ui_seen;
  std::set<int> held_keys;  // main thread: downs a game took

  std::mutex log_mtx;
  std::condition_variable log_cv;
  std::string log_path;
  bool log_quit = false;
  std::thread log_thread;

  void send(const char *method, const std::vector<uint8_t> &msg) {
    if (!cfg.send) return;
    const std::string channel = std::string(dena::kGameEventsChannel) + method;
    cfg.send(cfg.user, channel.c_str(), msg.data(), msg.size());
  }

  void push_port(int port, int64_t ns) {
    uint32_t mask = pad_mask[port] & 0xffffu;
    if (port == 0) mask |= key_mask;
    platform->runner.set_buttons(port, int(mask), ns);
  }

  void gamepad_used() {
    if (touch_recent.exchange(false)) send("onGamepadUsed", dena::encode_no_args());
  }

  // Start + Select or Guide (or Escape): the pause menu, with every button
  // let go so nothing stays held in the game.
  void menu() {
    const int64_t ns = dena::now_ns();
    key_mask = 0;
    for (int p = 0; p < dena::kDesktopPorts; p++) platform->runner.set_buttons(p, 0, ns);
    send("onMenuRequested", dena::encode_no_args());
  }

  void log_main() {
    std::unique_lock<std::mutex> lk(log_mtx);
    while (!log_quit) {
      log_cv.wait_for(lk, std::chrono::seconds(1));
      if (log_quit || log_path.empty() || !playing) continue;
      const int64_t unix_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::system_clock::now().time_since_epoch())
                                  .count();
      const std::string line = dena::latency_line(unix_ms, platform->metrics_json());
      if (FILE *f = std::fopen(log_path.c_str(), "ab")) {
        std::fprintf(f, "%s\n", line.c_str());
        std::fclose(f);
      }
    }
  }

  void set_log(const std::string &path) {
    if (!path.empty()) {
      std::error_code ec;
      fs::create_directories(fs::u8path(path).parent_path(), ec);
    }
    std::lock_guard<std::mutex> lk(log_mtx);
    log_path = path;
  }
};

Session *g_session;
// Run-ahead (run-ahead.md), kept for a session that starts later.
std::atomic<int32_t> g_run_ahead_mode{0}, g_run_ahead_frames{0};
// Controller profiles (gamepads.md, Desktop), kept the same way.
std::mutex g_profiles_mtx;
std::string g_profiles;
// The shader output size (shader-stacks.md), likewise.
std::atomic<int32_t> g_out_w{0}, g_out_h{0};
// Netplay (netplay.md): one session at a time, for the running game.
std::mutex g_netplay_mtx;
std::shared_ptr<dena::NetplaySession> g_netplay;
std::string g_netplay_info;

void stop_netplay(Session *s) {
  std::shared_ptr<dena::NetplaySession> n;
  {
    std::lock_guard<std::mutex> lk(g_netplay_mtx);
    n = std::move(g_netplay);
  }
  if (!n) return;
  if (s && s->platform) s->platform->runner.set_netplay(nullptr);
  n->stop();
}
std::atomic<int32_t> g_frame_gen{0};  // frame-generation.md
// Texture packs for the next game (texture-packs.md).
std::atomic<bool> g_texture_packs{false};

RunnerHost::RunnerHost(Session &s) : s_(s), r_(s.platform->runner) {}

std::string RunnerHost::resolve_core(const std::string &name) const {
  if (name.find_first_of("/\\") != std::string::npos && file_exists(name)) return name;
  for (const std::string &c : dena::core_candidates(name, s_.root, s_.lib_dir, kWindows))
    if (file_exists(c)) return c;
  return dena::desktop_core_file(name, kWindows);  // left to the library search path
}

int RunnerHost::start(const std::string &core, const std::string &rom, const std::string &sysdir,
                      const std::string &srm, const std::string &state) {
  // Achievements watch every played frame; hardcore follows the loaded game
  // (achievements.md), as on Android and the handheld.
  r_.set_frame_hook([this](dena_core *c) {
    dena_ra_frame(c);
    r_.set_hardcore(dena_ra_hardcore_active() != 0);
  });
  r_.set_hardcore(false);
  s_.key_mask = 0;
  s_.held_keys.clear();
  stop_netplay(&s_);
  core_path = resolve_core(core);
  rom_path = rom;
  dena::install_core_assets(core_path, s_.lib_dir, sysdir);
  {
    // gamecube-wii.md, Wii Remote: player 1's gyro pointer aims it.
    std::lock_guard<std::mutex> lk(g_profiles_mtx);
    r_.set_pointer_aim(dena::player1_gyro_pointer(g_profiles, s_.input.pads_info()));
  }
  r_.set_texture_packs(g_texture_packs);
  const int rc = r_.start(core_path, rom, sysdir, srm, state);
  s_.active = rc != dena::Runner::kStartError;
  s_.playing = s_.active.load();
  if (s_.active)
    for (int p = 0; p < dena::kDesktopPorts; p++) s_.push_port(p, dena::now_ns());
  return rc;
}

std::string RunnerHost::set_shader(const std::string &path) {
  return s_.platform->set_shader(path);
}

// Bundled presets beside the library (shader-stacks.md).
std::string RunnerHost::shader_path(const std::string &id) {
  return s_.lib_dir + "/shaders/" + id + ".slangp";
}

void RunnerHost::pause() {
  s_.playing = false;
  s_.slept_playing = false;  // Dart's pause wins over a pending wake
  r_.pause();
}

void RunnerHost::resume() {
  s_.slept_playing = false;
  r_.resume();
  s_.playing = s_.active.load();
}

void RunnerHost::stop() {
  stop_netplay(&s_);
  s_.playing = false;
  s_.active = false;
  s_.slept_playing = false;
  r_.stop();
}

// Every pad change; reaches Dart only while no game plays, so a press that
// started in the game never leaks into the menu (its release may: Dart
// ignores releases without a press).
void on_ui(uint32_t id, uint32_t ui_mask, int family) {
  Session *s = g_session;
  if (!s) return;
  uint32_t &seen = s->ui_seen[id];
  const uint32_t before = seen;
  seen = ui_mask;
  if (!ui_mask) s->ui_seen.erase(id);
  dena_desktop_ui_fn fn = s->ui_fn;
  if (!fn || s->playing) return;
  dena::ui_changes(before, ui_mask, [&](int action, bool down) {
    fn(int32_t(action), down ? 1 : 0, int32_t(family));
  });
}

void on_pad(int port, uint32_t mask, int64_t ns) {
  Session *s = g_session;
  if (!s || port < 0 || port >= dena::kDesktopPorts) return;
  s->pad_mask[port] = mask;
  const bool combo = dena::is_menu_combo(mask);
  if (!combo) s->menu_latched[port] = false;
  if (!s->playing) return;  // menus: the pad drives the UI instead (on_ui)
  if (combo) {
    if (!s->menu_latched[port]) {
      s->menu_latched[port] = true;
      s->menu();
    }
    return;
  }
  s->push_port(port, ns);
  if (mask) s->gamepad_used();
}

}  // namespace

extern "C" {

int dena_desktop_init(const struct dena_desktop_config *cfg) {
  if (g_session) return DENA_DESKTOP_API_VERSION;
  if (!cfg || cfg->struct_size < sizeof(dena_desktop_config)) return 0;
#ifdef _WIN32
  timeBeginPeriod(1);  // 1 ms sleeps for clock pacing
#endif
  dena_set_desktop_gl(1);  // cores built for desktop GL (hw-render.md)
  auto *s = new Session();
  s->cfg = *cfg;
  s->lib_dir = library_dir();
  g_session = s;
  dena::SdlInputCallbacks cb;
  cb.buttons = on_pad;
  cb.ui = on_ui;
  cb.analog = [](int port, int lx, int ly, int rx, int ry) {
    if (Session *s = g_session) s->platform->runner.set_analog(port, lx, ly, rx, ry);
  };
  cb.players = [](const std::vector<std::string> &names) {
    if (Session *s = g_session) {
      s->platform->runner.set_multitap(dena::wants_multitap(names));
      s->send("onPlayersChanged", dena::encode_players_changed(names));
    }
  };
  // The gyro as the touch pointer (gamepads.md, Desktop: profiles and gyro).
  cb.pointer = [](int x, int y, bool pressed) {
    if (Session *s = g_session) s->platform->runner.set_pointer(x, y, pressed);
  };
  cb.disconnected = [](int port, const std::string &name) {
    if (Session *s = g_session; s && s->active)
      s->send("onControllerDisconnected", dena::encode_controller_disconnected(port, name));
  };
  // The platform must exist before SDL reports the pads already plugged in.
  dena::DesktopPlatformConfig pc;
  pc.window = cfg->window;
  pc.refresh_mhz = cfg->refresh_mhz;
  pc.frame_ready = [s] {
    if (s->cfg.frame_ready) s->cfg.frame_ready(s->cfg.user);
  };
  s->platform = std::make_unique<dena::DesktopPlatform>(pc);
  s->platform->runner.set_run_ahead(g_run_ahead_mode, g_run_ahead_frames);
  s->platform->set_output_size(unsigned(g_out_w.load()), unsigned(g_out_h.load()));
  s->platform->set_stock_shader(s->lib_dir + "/shaders/dena/stock.slangp");
  s->platform->set_frame_generation(g_frame_gen);
  s->host = std::make_unique<RunnerHost>(*s);
  s->bridge = std::make_unique<dena::GameBridge>(s->host.get(), s->root);
  // No sound without SDL audio, but games still run (the runner sees no
  // audio device).
  {
    std::lock_guard<std::mutex> lk(g_profiles_mtx);
    s->input.set_profiles(g_profiles);
  }
  s->platform->set_audio(s->input.start(cb) && s->input.audio_ok());
  s->log_thread = std::thread([s] { s->log_main(); });
  return DENA_DESKTOP_API_VERSION;
}

void dena_desktop_shutdown(void) {
  Session *s = g_session;
  if (!s) return;
  {
    std::lock_guard<std::mutex> lk(s->log_mtx);
    s->log_quit = true;
  }
  s->log_cv.notify_all();
  s->log_thread.join();
  s->input.stop();  // no more pad callbacks
  g_session = nullptr;
  s->bridge.reset();
  s->host.reset();
  s->platform.reset();  // stops the runner, which saves
  delete s;
#ifdef _WIN32
  timeEndPeriod(1);
#endif
}

const char *dena_desktop_channels(void) {
  static const std::string list = [] {
    std::string out;
    std::string methods = kMethods;
    size_t start = 0;
    while (start <= methods.size()) {
      size_t end = methods.find('\n', start);
      if (end == std::string::npos) end = methods.size();
      if (!out.empty()) out += '\n';
      out += std::string(dena::kGameHostChannel) + methods.substr(start, end - start);
      start = end + 1;
    }
    return out;
  }();
  return list.c_str();
}

bool dena_desktop_message(const char *channel, const uint8_t *msg, size_t len, uint8_t **reply,
                          size_t *reply_len) {
  Session *s = g_session;
  if (!s || !s->bridge) return false;
  std::vector<uint8_t> out;
  if (!s->bridge->handle(channel, msg, len, out)) return false;
  *reply_len = out.size();
  *reply = static_cast<uint8_t *>(std::malloc(out.empty() ? 1 : out.size()));
  if (*reply && !out.empty()) std::memcpy(*reply, out.data(), out.size());
  return *reply != nullptr;
}

void dena_desktop_free(void *p) { std::free(p); }

bool dena_desktop_key(int key, bool down) {
  Session *s = g_session;
  if (!s) return false;
  if (!down) {
    // Only the releases of presses a game took: Flutter must see every
    // release of a press it saw.
    if (!s->held_keys.erase(key)) return false;
    if (dena::key_action(key) == dena::kKeyRewind) {
      s->platform->runner.set_rewinding(false);
      return true;
    }
    const int bit = dena::key_bit(key);
    if (bit >= 0 && s->playing) {
      s->key_mask &= ~(1u << bit);
      s->push_port(0, dena::now_ns());
    }
    return true;
  }
  const int action = dena::key_action(key);
  if (action == -1 || !s->playing) return false;
  s->held_keys.insert(key);
  if (action == dena::kKeyMenu) {
    s->menu();
    return true;
  }
  if (action == dena::kKeyRewind) {
    s->platform->runner.set_rewinding(true);
    return true;
  }
  s->key_mask |= 1u << action;
  s->push_port(0, dena::now_ns());
  s->gamepad_used();
  return true;
}

static std::atomic<int64_t> g_texture{-1};

void dena_desktop_set_texture(int64_t id) { g_texture = id; }

int64_t dena_desktop_texture(void) { return g_texture; }

void dena_desktop_set_refresh(int refresh_mhz) {
  if (g_session) g_session->platform->set_refresh(refresh_mhz);
}

bool dena_desktop_frame_rgba(const uint8_t **rgba, uint32_t *width, uint32_t *height) {
#ifdef _WIN32
  (void)rgba, (void)width, (void)height;
  return false;
#else
  Session *s = g_session;
  if (!s) return false;
  const dena::MailFrame *f = s->platform->take_rgba(nullptr);
  if (!f) return false;
  *rgba = f->rgba.data();
  *width = f->width;
  *height = f->height;
  return true;
#endif
}

void *dena_desktop_frame_d3d(uint32_t *width, uint32_t *height) {
#ifdef _WIN32
  Session *s = g_session;
  return s ? s->platform->take_d3d(width, height) : nullptr;
#else
  (void)width, (void)height;
  return nullptr;
#endif
}

void dena_desktop_set_root(const char *path) {
  Session *s = g_session;
  if (!s || !path || !*path || s->active) return;
  s->root = path;
  s->bridge = std::make_unique<dena::GameBridge>(s->host.get(), s->root);
  // Latency log (desktop-shell.md): an empty `latency` file in the root,
  // or DENA_LATENCY_LOG=1, turns it on.
  const char *env = std::getenv("DENA_LATENCY_LOG");
  if ((env && *env && std::strcmp(env, "0") != 0) || file_exists(s->root + "/latency"))
    s->set_log(s->root + "/logs/latency.jsonl");
}

int32_t dena_desktop_gamepads(void) { return g_session ? g_session->input.gamepads() : 0; }

void dena_desktop_set_ui_input(dena_desktop_ui_fn fn) {
  if (g_session) g_session->ui_fn = fn;
}

void dena_desktop_chime(void) {
  if (g_session) g_session->platform->chime();
}

int32_t dena_desktop_gamepad_family(void) {
  return g_session ? g_session->input.family() : -1;
}

const char *dena_desktop_metrics(void) {
  static std::string json;
  json = g_session ? g_session->platform->metrics_json() : "{}";
  return json.c_str();
}

void dena_desktop_latency_log(const char *path) {
  if (g_session) g_session->set_log(path ? path : "");
}

void dena_desktop_set_profiles(const char *text) {
  std::lock_guard<std::mutex> lk(g_profiles_mtx);
  g_profiles = text ? text : "";
  if (Session *s = g_session) s->input.set_profiles(g_profiles);
}

const char *dena_desktop_pads_info(void) {
  static std::string info;
  info = g_session ? g_session->input.pads_info() : std::string();
  return info.c_str();
}

void dena_desktop_set_run_ahead(int32_t mode, int32_t frames) {
  g_run_ahead_mode = mode;
  g_run_ahead_frames = frames;
  if (Session *s = g_session; s && s->platform) s->platform->runner.set_run_ahead(mode, frames);
}

// Sleep and wake (deck-presets.md, Suspend and resume): pause() writes the
// battery save and the auto-save state before it returns.
int32_t dena_desktop_suspend(void) {
  Session *s = g_session;
  if (!s || !s->host || !s->active) return 0;
  if (s->playing) {
    s->host->pause();
    s->slept_playing = true;
  } else {
    s->host->save_now();  // already paused (menu open): saved, write again
  }
  return 1;
}

void dena_desktop_resume(void) {
  Session *s = g_session;
  if (!s || !s->host || !s->slept_playing) return;
  s->slept_playing = false;
  if (s->active) s->host->resume();
}

void dena_desktop_set_frame_generation(int32_t mode) {
  g_frame_gen = mode == 1 || mode == 2 ? mode : 0;
  if (Session *s = g_session; s && s->platform) s->platform->set_frame_generation(g_frame_gen);
}

const char *dena_desktop_frame_generation_status(void) {
  static std::string status;
  Session *s = g_session;
  status = s && s->platform ? s->platform->frame_gen().status() : "0 - 0.0 0.0";
  return status.c_str();
}

void dena_desktop_set_output_size(int32_t width, int32_t height) {
  const bool ok = width > 0 && height > 0;
  g_out_w = ok ? width : 0;
  g_out_h = ok ? height : 0;
  if (Session *s = g_session; s && s->platform)
    s->platform->set_output_size(unsigned(g_out_w.load()), unsigned(g_out_h.load()));
}

void dena_desktop_set_texture_packs(int32_t on) { g_texture_packs = on != 0; }

// ---- dart:ffi entry points shared with libdena_android.so ----

// Touch controls (skins.md): the mouse drives the skin on desktop.
void dena_touch_buttons(int32_t mask) {
  if (Session *s = g_session) {
    s->touch_recent = true;
    s->platform->runner.set_touch(mask, dena::now_ns());
  }
}

void dena_touch_analog(int32_t stick, int32_t x, int32_t y) {
  if (Session *s = g_session) s->platform->runner.set_touch_analog(stick, x, y);
}

// The DS touch screen and PSP pointer (ds.md): the mouse.
void dena_touch_pointer(int32_t x, int32_t y, int32_t pressed) {
  if (Session *s = g_session) s->platform->runner.set_pointer(x, y, pressed != 0);
}

void dena_set_turbo(int32_t mask, int32_t half_frames) {
  if (Session *s = g_session) s->platform->runner.set_turbo(mask, half_frames);
}

void dena_rewind_hold(int32_t on) {
  if (Session *s = g_session) s->platform->runner.set_rewinding(on != 0);
}

// Long rewind (rewind.md): the buffer budget and the pause menu's scrub bar.
// info gets {count, position, bytes, budget, fps * 1000}.
static void put_rewind_info(const dena::Runner::RewindInfo &i, int64_t *info) {
  info[0] = int64_t(i.count);
  info[1] = int64_t(i.position);
  info[2] = int64_t(i.bytes);
  info[3] = int64_t(i.budget);
  info[4] = int64_t(i.fps * 1000);
}

void dena_rewind_budget(int64_t bytes) {
  if (Session *s = g_session; s && bytes > 0) s->platform->runner.set_rewind_budget(size_t(bytes));
}

int32_t dena_rewind_info(int64_t *info) {
  Session *s = g_session;
  if (!s || !info) return -1;
  put_rewind_info(s->platform->runner.rewind_info(), info);
  return 0;
}

int32_t dena_rewind_scrub_begin(int64_t *info) {
  Session *s = g_session;
  dena::Runner::RewindInfo i;
  if (!s || !info || !s->platform->runner.begin_scrub(&i)) return -1;
  put_rewind_info(i, info);
  return 0;
}

void dena_rewind_scrub(int64_t position) {
  if (Session *s = g_session; s && position >= 0) s->platform->runner.scrub_to(size_t(position));
}

void dena_rewind_scrub_end(int32_t keep) {
  if (Session *s = g_session) s->platform->runner.end_scrub(keep != 0);
}

// The host mailbox in system RAM (pico8-launcher-cart.md).
static uint8_t g_ram_buffer[256];

uint8_t *dena_ram_buffer(void) { return g_ram_buffer; }

void dena_ram_watch(int32_t offset, int32_t len) {
  if (Session *s = g_session; s && offset >= 0 && len >= 0)
    s->platform->runner.watch_ram(size_t(offset), size_t(len));
}

int32_t dena_ram_read(int32_t len) {
  Session *s = g_session;
  return s && len >= 0 && len <= int32_t(sizeof g_ram_buffer) &&
                 s->platform->runner.read_ram(g_ram_buffer, size_t(len))
             ? 1
             : 0;
}

void dena_ram_write(int32_t offset, int32_t len) {
  if (Session *s = g_session; s && offset >= 0 && len >= 0 && len <= int32_t(sizeof g_ram_buffer))
    s->platform->runner.write_ram(size_t(offset), g_ram_buffer, size_t(len));
}

}  // extern "C"

namespace {

int32_t start_netplay(bool host, const char *target, const char *relay, int32_t port, bool room,
                      int32_t delay) {
  Session *s = g_session;
  if (!s || !s->active || !s->host || !s->platform) return -1;
  stop_netplay(s);
  dena::NetplaySession::Options o;
  o.host = host;
  o.target = target ? target : "";
  o.relay = relay ? relay : "";
  o.port = port;
  o.room = room;
  o.delay = delay;
  const std::string &core = s->host->core_path;
  o.core = core.substr(core.find_last_of("/\\") + 1);
  o.rom_id = dena::netplay_rom_id(s->host->rom_path);
  o.method = dena::netplay_method(core);
  auto n = std::make_shared<dena::NetplaySession>();
  s->platform->runner.set_netplay(n);
  if (!n->start(o)) {
    s->platform->runner.set_netplay(nullptr);
    return -1;
  }
  std::lock_guard<std::mutex> lk(g_netplay_mtx);
  g_netplay = std::move(n);
  return 0;
}

}  // namespace

int32_t dena_netplay_host(int32_t port, const char *relay, int32_t room, int32_t delay) {
  return start_netplay(true, nullptr, relay, port, room != 0, delay);
}

int32_t dena_netplay_join(const char *target, const char *relay, int32_t delay) {
  if (!target || !*target) return -1;
  return start_netplay(false, target, relay, 0, false, delay);
}

void dena_netplay_stop(void) { stop_netplay(g_session); }

int32_t dena_netplay_state(void) {
  std::lock_guard<std::mutex> lk(g_netplay_mtx);
  return g_netplay ? g_netplay->state() : 0;
}

int32_t dena_netplay_method(void) {
  Session *s = g_session;
  if (!s || !s->active || !s->host) return 0;
  return dena::netplay_method(s->host->core_path);
}

const char *dena_netplay_info(void) {
  std::lock_guard<std::mutex> lk(g_netplay_mtx);
  g_netplay_info = g_netplay ? g_netplay->info_json() : std::string("{\"state\":0}");
  return g_netplay_info.c_str();
}
