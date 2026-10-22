// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop host library end to end through its C interface, headless:
// loaded the way the runners load it, a testcore game started by a Pigeon
// message, frames on the texture, keyboard input taken only while playing.
// Spec: docs/specs/desktop-shell.md
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "dena/desktop_loader.h"
#include "dena/std_codec.h"

static int g_failed = 0;
#define CHECK(c)                                                          \
  do {                                                                    \
    if (!(c)) {                                                           \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      g_failed++;                                                         \
    }                                                                     \
  } while (0)

static std::atomic<int> g_frames{0};
static std::atomic<int> g_sent{0};

// Frame times while g_record is set (the start-up check below).
static std::atomic<bool> g_record{false};
static std::atomic<int> g_times_n{0};
static int64_t g_times[4096];

static void on_frame(void *) {
  g_frames++;
  if (!g_record) return;
  const int i = g_times_n.fetch_add(1);
  if (i < 4096)
    g_times[i] = std::chrono::duration_cast<std::chrono::nanoseconds>(
                     std::chrono::steady_clock::now().time_since_epoch())
                     .count();
}
static void on_send(void *, const char *, const uint8_t *, size_t) { g_sent++; }

static void *open_lib(const char *path) {
#ifdef _WIN32
  return reinterpret_cast<void *>(LoadLibraryA(path));
#else
  return dlopen(path, RTLD_NOW | RTLD_GLOBAL);
#endif
}

static void *sym(void *lib, const char *name) {
#ifdef _WIN32
  return reinterpret_cast<void *>(GetProcAddress(static_cast<HMODULE>(lib), name));
#else
  return dlsym(lib, name);
#endif
}

template <typename Fn>
static std::vector<uint8_t> build(Fn fn) {
  std::vector<uint8_t> out(4096);
  struct dena_buf b = {out.data(), 0, out.size(), false};
  fn(&b);
  out.resize(b.len);
  return out;
}

static bool call(dena::DesktopHost &h, const std::string &method, const std::vector<uint8_t> &msg) {
  const std::string channel = "dev.flutter.pigeon.dena_android.GameHostApi." + method;
  uint8_t *reply = nullptr;
  size_t len = 0;
  const bool ok = h.message(channel.c_str(), msg.data(), msg.size(), &reply, &len);
  if (ok) h.free_reply(reply);
  return ok;
}

static bool wait_for(const std::atomic<int> &v, int at_least) {
  for (int i = 0; i < 300 && v < at_least; i++)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return v >= at_least;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: desktop_host_tests <library> <testcore> <root>\n");
    return 2;
  }
  const std::string root = argv[3];
  dena::DesktopHost h;
  if (!h.load(argv[1])) {
    std::fprintf(stderr, "cannot load %s\n", argv[1]);
    return 1;
  }
  void *lib = open_lib(argv[1]);  // the same module: Dart's view of it
  auto set_root = reinterpret_cast<void (*)(const char *)>(sym(lib, "dena_desktop_set_root"));
  auto texture = reinterpret_cast<int64_t (*)()>(sym(lib, "dena_desktop_texture"));
  auto metrics = reinterpret_cast<const char *(*)()>(sym(lib, "dena_desktop_metrics"));
  auto turbo = reinterpret_cast<void (*)(int32_t, int32_t)>(sym(lib, "dena_set_turbo"));
  auto ra_buffer = sym(lib, "dena_ra_buffer");
  auto link_state = sym(lib, "dena_link_state");
  CHECK(set_root && texture && metrics && turbo);
  CHECK(ra_buffer != nullptr);   // achievements are exported for dart:ffi
  CHECK(link_state != nullptr);  // and the link cable
  for (const char *name : {"dena_rewind_budget", "dena_rewind_info", "dena_rewind_scrub_begin",
                           "dena_rewind_scrub", "dena_rewind_scrub_end"})
    CHECK(sym(lib, name) != nullptr);  // long rewind (rewind.md)
  CHECK(sym(lib, "dena_desktop_set_run_ahead") != nullptr);  // run-ahead.md
  // Frame generation (frame-generation.md), set before the game starts.
  auto set_frame_gen = reinterpret_cast<void (*)(int32_t)>(sym(lib, "dena_desktop_set_frame_generation"));
  auto frame_gen_status = reinterpret_cast<const char *(*)()>(sym(lib, "dena_desktop_frame_generation_status"));
  auto set_refresh = reinterpret_cast<void (*)(int32_t)>(sym(lib, "dena_desktop_set_refresh"));
  CHECK(set_frame_gen && frame_gen_status && set_refresh);
  if (set_frame_gen) set_frame_gen(1);

  // Channels: one line per GameHostApi method.
  const std::string channels = h.channels();
  int lines = 1;
  for (char c : channels) lines += c == '\n';
  CHECK(lines == 19);
  CHECK(channels.find("GameHostApi.start\n") != std::string::npos);
  CHECK(channels.find("GameHostApi.stop") != std::string::npos);

  dena_desktop_config cfg{};
  cfg.struct_size = sizeof cfg;
  cfg.frame_ready = on_frame;
  cfg.send = on_send;
  cfg.refresh_mhz = 60000;
  CHECK(h.init(&cfg) == DENA_DESKTOP_API_VERSION);
  h.set_texture(7);
  CHECK(texture() == 7);
  set_root(root.c_str());
  turbo(0, 0);

  // Not playing: keys go to Flutter.
  CHECK(!h.key('X', true));
  CHECK(!h.key('X', false));
  // Sleep without a game: nothing to save (deck-presets.md).
  CHECK(h.suspend != nullptr && h.resume != nullptr);
  if (h.suspend) CHECK(h.suspend() == 0);
  if (h.resume) h.resume();

  const std::string rom = root + "/test.rom";
  if (FILE *f = std::fopen(rom.c_str(), "wb")) {
    std::fputs("dena", f);
    std::fclose(f);
  }
  auto str = [](struct dena_buf *b, const std::string &s) { dena_put_string(b, s.c_str()); };
  const std::vector<uint8_t> start = build([&](struct dena_buf *b) {
    dena_put_list_start(b, 4);
    str(b, argv[2]);
    str(b, rom);
    str(b, root + "/test.srm");
    str(b, root + "/test.state");
  });
  CHECK(call(h, "setAudioLatency", build([](struct dena_buf *b) {
          dena_put_list_start(b, 1);
          dena_put_int(b, 40);
        })));
  CHECK(call(h, "start", start));
  CHECK(wait_for(g_frames, 5));

#ifdef _WIN32
  uint32_t w = 0, hgt = 0;
  void *handle = h.frame_d3d(&w, &hgt);
  // No GPU on a headless runner: then there is no D3D device and no frame.
  if (handle) CHECK(w > 0 && hgt > 0);
#else
  const uint8_t *rgba = nullptr;
  uint32_t w = 0, hgt = 0;
  CHECK(h.frame_rgba(&rgba, &w, &hgt));
  CHECK(rgba != nullptr && w > 0 && hgt > 0);
  if (rgba) CHECK(rgba[3] == 255);  // opaque
#endif

  // Playing: bound keys are the game's, unbound ones Flutter's; a release
  // follows its press.
  CHECK(h.key('X', true));
  CHECK(h.key('X', false));
  CHECK(!h.key('P', true));
  CHECK(!h.key('P', false));
  // Escape opens the pause menu (an event to Dart).
  const int sent = g_sent;
  CHECK(h.key(DENA_DESKTOP_KEY_ESCAPE, true));
  CHECK(g_sent > sent);
  CHECK(call(h, "pause", build([](struct dena_buf *b) { dena_put_null(b); })));
  CHECK(h.key(DENA_DESKTOP_KEY_ESCAPE, false));  // its release, though paused
  CHECK(!h.key('X', true));                      // paused: the menu's
  CHECK(!h.key('X', false));
  CHECK(call(h, "resume", build([](struct dena_buf *b) { dena_put_null(b); })));

  // Sleep and wake (deck-presets.md): suspend pauses and writes the auto-save
  // state, resume continues once; a game paused by the menu stays paused.
  if (h.suspend && h.resume) {
    const std::string state = root + "/test.state";
    std::remove(state.c_str());
    CHECK(h.suspend() == 1);
    FILE *f = std::fopen(state.c_str(), "rb");
    CHECK(f != nullptr);
    if (f) std::fclose(f);
    CHECK(!h.key('X', true));  // asleep: paused
    CHECK(!h.key('X', false));
    h.resume();
    CHECK(h.key('X', true));  // playing again
    CHECK(h.key('X', false));
    h.resume();  // Windows sends two wake messages
    CHECK(h.key('X', true));
    CHECK(h.key('X', false));
    CHECK(call(h, "pause", build([](struct dena_buf *b) { dena_put_null(b); })));
    CHECK(h.suspend() == 1);
    h.resume();
    CHECK(!h.key('X', true));  // still the menu's
    CHECK(!h.key('X', false));
    CHECK(call(h, "resume", build([](struct dena_buf *b) { dena_put_null(b); })));
  }

  const std::string m = metrics();
  CHECK(m.find("\"frames\":") != std::string::npos);
  // At 60 Hz a 60 fps game gets no frame generation: the refresh rule.
  CHECK(m.find("\"frame_generation\":0,\"frame_generation_want\":1,\"frame_generation_off\":\"refresh\"") !=
        std::string::npos);
  CHECK(m.find("\"display_hz\":60.00") != std::string::npos);
  CHECK(m.find("\"generated_frames\":0") != std::string::npos);
  if (frame_gen_status && set_refresh && set_frame_gen) {
    CHECK(std::string(frame_gen_status()).rfind("0 refresh ", 0) == 0);
    // 120 Hz: on, or off with "gl" where this machine has no GL 4.2 (or no
    // shaders folder next to the test library); frames keep coming.
    set_refresh(120000);
    const int before = g_frames;
    CHECK(wait_for(g_frames, before + 20));
    const std::string st = frame_gen_status();
    std::printf("frame generation at 120 Hz: %s\n", st.c_str());
    CHECK(st.rfind("1 - ", 0) == 0 || st.rfind("0 gl ", 0) == 0);
    // Turned on mid-game: the set-up ran inside a frame and is reported.
    if (st.rfind("1 - ", 0) == 0)
      CHECK(std::string(metrics()).find("\"frame_generation_setup_ms\":0.0") == std::string::npos);
    set_frame_gen(0);
    CHECK(wait_for(g_frames, g_frames + 5));
    CHECK(std::string(frame_gen_status()).rfind("0 - ", 0) == 0);
    set_refresh(60000);
  }

  CHECK(call(h, "stop", build([](struct dena_buf *b) { dena_put_null(b); })));
  CHECK(!h.key('X', true));
  if (h.suspend) CHECK(h.suspend() == 0);  // stopped: nothing to save

  // A game started with frame generation on at 120 Hz: its GL set-up runs
  // before the first frame, so no frame (and no input) of the first second
  // waits for it (frame-generation.md, Start-up). Pass 3 measured ~110 ms
  // for one input while the set-up ran inside the first frame.
  if (set_frame_gen && set_refresh && frame_gen_status) {
    set_frame_gen(1);
    set_refresh(120000);
    g_times_n = 0;
    g_record = true;
    CHECK(call(h, "start", start));
    const auto started = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    g_record = false;
    const int n = std::min(g_times_n.load(), 4096);
    double worst_ms = 0;
    for (int i = 1; i < n; i++) worst_ms = std::max(worst_ms, double(g_times[i] - g_times[i - 1]) / 1e6);
    const double first_ms =
        n ? double(g_times[0] - std::chrono::duration_cast<std::chrono::nanoseconds>(
                                    started.time_since_epoch())
                                    .count()) /
                1e6
          : -1;
    const std::string st = frame_gen_status();
    const std::string fm = metrics();
    std::printf("start-up with frame generation: %s, %d frames in 1 s, first %.1f ms after start, "
                "worst gap %.1f ms\n",
                st.c_str(), n, first_ms, worst_ms);
    CHECK(n > 10);
    if (st.rfind("1 - ", 0) == 0) {
      CHECK(fm.find("\"frame_generation\":1,\"frame_generation_want\":1,\"frame_generation_off\":\"\"") !=
            std::string::npos);
      CHECK(fm.find("\"frame_generation_setup_ms\":0.0") != std::string::npos);
      CHECK(fm.find("\"generated_frames\":0,") == std::string::npos);
    } else {
      CHECK(st.rfind("0 gl ", 0) == 0);  // no GL 4.2 here
    }
    CHECK(call(h, "stop", build([](struct dena_buf *b) { dena_put_null(b); })));
    set_frame_gen(0);
    set_refresh(60000);
  }
  h.shutdown();

  if (g_failed) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failed);
    return 1;
  }
  std::printf("desktop_host: ok (%d frames)\n", g_frames.load());
  return 0;
}
