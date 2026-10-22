// SPDX-License-Identifier: GPL-3.0-or-later
// Tests for the launcher GameHostApi bridge (game_bridge.cpp).
// Spec: docs/specs/handheld-session.md
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <direct.h>
#define make_dir(p) _mkdir(p)
#else
#include <sys/stat.h>
#define make_dir(p) mkdir(p, 0755)
#endif

#include "dena/std_codec.h"
#include "game_bridge.h"

static int failures;
#define CHECK(c)                                                    \
  do {                                                              \
    if (!(c)) {                                                     \
      fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      failures++;                                                   \
    }                                                              \
  } while (0)

using Msg = std::vector<uint8_t>;

// The FakeHost records what the bridge forwarded and returns what the test
// configured.
class FakeHost : public dena::GameHost {
 public:
  int start_rc = 0;
  std::string error_text = "engine failed";
  int save_state_rc = 0;
  int load_state_rc = 0;
  int screenshot_rc = 0;

  int start_calls = 0;
  std::string core, rom, sysdir, srm, state;
  int error_calls = 0;
  int pause_calls = 0;
  int resume_calls = 0;
  int set_speed_calls = 0;
  int speed = -1;
  int rewind_calls = 0;
  bool rewind_enabled = false, rewind_l2 = false;
  int rewinding_calls = 0;
  bool rewinding = false;
  int save_now_calls = 0;
  int save_state_calls = 0;
  std::string save_state_path, save_png_path;
  int load_state_calls = 0;
  std::string load_state_path;
  int screenshot_calls = 0;
  std::string screenshot_path;
  int set_cheats_calls = 0;
  std::vector<std::string> cheats;
  int stop_calls = 0;

  int start(const std::string &c, const std::string &r, const std::string &sd,
            const std::string &s, const std::string &st) override {
    start_calls++;
    core = c;
    rom = r;
    sysdir = sd;
    srm = s;
    state = st;
    return start_rc;
  }
  std::string error() override {
    error_calls++;
    return error_text;
  }
  void pause() override { pause_calls++; }
  void resume() override { resume_calls++; }
  void set_speed(int n) override {
    set_speed_calls++;
    speed = n;
  }
  int latency_calls = 0, latency_ms = -1;
  void set_audio_latency_ms(int ms) override {
    latency_calls++;
    latency_ms = ms;
  }
  int upscale_calls = 0, upscale = -1;
  void set_upscale(int factor) override {
    upscale_calls++;
    upscale = factor;
  }
  int widescreen_calls = 0;
  bool widescreen = false;
  void set_widescreen(bool on) override {
    widescreen_calls++;
    widescreen = on;
  }
  void configure_rewind(bool enabled, bool l2_hold) override {
    rewind_calls++;
    rewind_enabled = enabled;
    rewind_l2 = l2_hold;
  }
  void set_rewinding(bool on) override {
    rewinding_calls++;
    rewinding = on;
  }
  void save_now() override { save_now_calls++; }
  int save_state(const std::string &s, const std::string &png) override {
    save_state_calls++;
    save_state_path = s;
    save_png_path = png;
    return save_state_rc;
  }
  int load_state(const std::string &s) override {
    load_state_calls++;
    load_state_path = s;
    return load_state_rc;
  }
  int screenshot(const std::string &png) override {
    screenshot_calls++;
    screenshot_path = png;
    return screenshot_rc;
  }
  int set_shader_calls = 0;
  std::string shader_set, shader_error;
  std::string set_shader(const std::string &path) override {
    set_shader_calls++;
    shader_set = path;
    return shader_error;
  }
  std::string shader_dir;  // set: answers shader_path like the desktop host
  std::string shader_path(const std::string &id) override {
    return shader_dir.empty() ? "" : shader_dir + "/" + id + ".slangp";
  }
  void set_cheats(std::vector<std::string> codes) override {
    set_cheats_calls++;
    cheats = std::move(codes);
  }
  void stop() override { stop_calls++; }
};

static std::string g_card;

// --- message building -------------------------------------------------------

template <typename Fn>
static Msg build(Fn fn) {
  Msg out(2048);
  struct dena_buf b = {out.data(), 0, out.size(), false};
  fn(&b);
  if (b.failed) {
    fprintf(stderr, "test message encoder overflow\n");
    failures++;
  }
  out.resize(b.len);
  return out;
}

static Msg msg_null() {
  return build([](struct dena_buf *b) { dena_put_null(b); });
}

static Msg msg_str1(const std::string &a) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_string(b, a.c_str());
  });
}

static Msg msg_str2(const std::string &a, const std::string &c) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 2);
    dena_put_string(b, a.c_str());
    dena_put_string(b, c.c_str());
  });
}

static Msg msg_str4(const std::string &a, const std::string &c,
                    const std::string &d, const std::string &e) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 4);
    dena_put_string(b, a.c_str());
    dena_put_string(b, c.c_str());
    dena_put_string(b, d.c_str());
    dena_put_string(b, e.c_str());
  });
}

static Msg msg_int1(int64_t v) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_int(b, v);
  });
}

// A small int forced into the int64 form: tag 4 then 8 little-endian bytes.
static Msg msg_int_tag4(int64_t v) {
  Msg m;
  m.push_back(12);  // list
  m.push_back(1);   // one item
  m.push_back(4);   // int64 tag
  uint64_t u = static_cast<uint64_t>(v);
  for (int i = 0; i < 8; i++) m.push_back(static_cast<uint8_t>(u >> (8 * i)));
  return m;
}

static Msg msg_bool1(bool v) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_bool(b, v);
  });
}

static Msg msg_bool2(bool a, bool c) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 2);
    dena_put_bool(b, a);
    dena_put_bool(b, c);
  });
}

static Msg msg_double1(double v) {
  return build([&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_double(b, v);
  });
}

// --- reply decoding ---------------------------------------------------------

static struct dena_val reply_vals[256];
static struct dena_val_arena reply_arena;

static bool decode_reply(const Msg &r, struct dena_val *out) {
  reply_arena.vals = reply_vals;
  reply_arena.cap = sizeof reply_vals / sizeof reply_vals[0];
  reply_arena.used = 0;
  return dena_decode(r.data(), r.size(), &reply_arena, out) == 0;
}

static bool is_null_result(const Msg &r) {
  struct dena_val v;
  if (!decode_reply(r, &v)) return false;
  if (v.type != DENA_VAL_LIST || v.size != 1) return false;
  const struct dena_val *e = dena_list_at(&v, 0);
  return e && e->type == DENA_VAL_NULL;
}

static bool is_string_result(const Msg &r, const char *expected) {
  struct dena_val v;
  if (!decode_reply(r, &v)) return false;
  if (v.type != DENA_VAL_LIST || v.size != 1) return false;
  const struct dena_val *e = dena_list_at(&v, 0);
  return e && dena_val_string_eq(e, expected);
}

// ["bad-args", message, null]; fills *out_message with the message.
static bool is_bad_args(const Msg &r, std::string *out_message = nullptr) {
  struct dena_val v;
  if (!decode_reply(r, &v)) return false;
  if (v.type != DENA_VAL_LIST || v.size != 3) return false;
  const struct dena_val *code = dena_list_at(&v, 0);
  const struct dena_val *m = dena_list_at(&v, 1);
  const struct dena_val *d = dena_list_at(&v, 2);
  if (!code || !m || !d) return false;
  if (!dena_val_string_eq(code, "bad-args")) return false;
  if (m->type != DENA_VAL_STRING || d->type != DENA_VAL_NULL) return false;
  if (out_message)
    out_message->assign(reinterpret_cast<const char *>(m->data), m->size);
  return true;
}

// --- invoking the bridge ----------------------------------------------------

static bool call(FakeHost &host, const std::string &method, const Msg &msg,
                 Msg &reply) {
  dena::GameBridge bridge(&host, g_card);
  const std::string channel = std::string(dena::kGameHostChannel) + method;
  return bridge.handle(channel, msg.data(), msg.size(), reply);
}

static bool call_channel(FakeHost &host, const std::string &channel, const Msg &msg,
                         Msg &reply) {
  dena::GameBridge bridge(&host, g_card);
  return bridge.handle(channel, msg.data(), msg.size(), reply);
}

// --- tests ------------------------------------------------------------------

static void test_channels() {
  CHECK(std::string(dena::kGameHostChannel) ==
        "dev.flutter.pigeon.dena_android.GameHostApi.");
  CHECK(std::string(dena::kGameEventsChannel) ==
        "dev.flutter.pigeon.dena_android.GameEventsApi.");
}

static void test_void_methods() {
  FakeHost host;
  Msg reply;

  CHECK(call(host, "pause", msg_null(), reply));
  CHECK(host.pause_calls == 1 && is_null_result(reply));

  // An empty buffer is the same as an empty argument list.
  Msg empty;
  CHECK(call(host, "resume", empty, reply));
  CHECK(host.resume_calls == 1 && is_null_result(reply));

  CHECK(call(host, "saveNow", msg_null(), reply));
  CHECK(host.save_now_calls == 1 && is_null_result(reply));

  CHECK(call(host, "stop", msg_null(), reply));
  CHECK(host.stop_calls == 1 && is_null_result(reply));
}

static void test_forwarded_scalars() {
  FakeHost host;
  Msg reply;

  CHECK(call(host, "setSpeed", msg_int1(4), reply));
  CHECK(host.set_speed_calls == 1 && host.speed == 4);
  CHECK(is_null_result(reply));

  // The same value sent as tag 4 (int64) is accepted.
  CHECK(call(host, "setSpeed", msg_int_tag4(6), reply));
  CHECK(host.set_speed_calls == 2 && host.speed == 6);
  CHECK(is_null_result(reply));

  // Set before start (performance.md, shaders.md).
  CHECK(call(host, "setAudioLatency", msg_int1(20), reply));
  CHECK(host.latency_calls == 1 && host.latency_ms == 20);
  CHECK(is_null_result(reply));
  CHECK(call(host, "setUpscale", msg_int1(3), reply));
  CHECK(host.upscale_calls == 1 && host.upscale == 3);
  CHECK(is_null_result(reply));
  CHECK(call(host, "setWidescreen", msg_bool1(true), reply));
  CHECK(host.widescreen_calls == 1 && host.widescreen);
  CHECK(is_null_result(reply));
  CHECK(call(host, "setWidescreen", msg_int1(1), reply));
  CHECK(is_bad_args(reply));
  CHECK(host.widescreen_calls == 1);

  CHECK(call(host, "configureRewind", msg_bool2(true, false), reply));
  CHECK(host.rewind_calls == 1 && host.rewind_enabled && !host.rewind_l2);
  CHECK(is_null_result(reply));

  CHECK(call(host, "setRewinding", msg_bool1(true), reply));
  CHECK(host.rewinding_calls == 1 && host.rewinding);
  CHECK(is_null_result(reply));

  // Accepted but without effect.
  CHECK(call(host, "setDisplayAspect", msg_double1(1.25), reply));
  CHECK(is_null_result(reply));
  CHECK(call(host, "setAnalogMode", msg_bool1(true), reply));
  CHECK(is_null_result(reply));
  CHECK(call(host, "setTouchMode", msg_bool1(false), reply));
  CHECK(is_null_result(reply));
  // Sent before every start by the session screen; an error here would end
  // the start with an exception.
  CHECK(call(host, "setAudioLatency", msg_int1(60), reply));
  CHECK(is_null_result(reply));
  CHECK(call(host, "setUpscale", msg_int1(2), reply));
  CHECK(is_null_result(reply));
  CHECK(call(host, "setUpscale", msg_bool1(true), reply));
  CHECK(is_bad_args(reply));
}

static void test_save_load_state() {
  FakeHost host;
  Msg reply;

  host.save_state_rc = 0;
  CHECK(call(host, "saveState", msg_str2("s.dat", "frame.png"), reply));
  CHECK(host.save_state_calls == 1 && host.save_state_path == "s.dat" &&
        host.save_png_path == "frame.png");
  CHECK(is_null_result(reply));

  host.save_state_rc = 3;
  CHECK(call(host, "saveState", msg_str2("s.dat", "frame.png"), reply));
  CHECK(is_string_result(reply, "Could not write the save state"));

  host.load_state_rc = 0;
  CHECK(call(host, "loadState", msg_str1("s.dat"), reply));
  CHECK(host.load_state_calls == 1 && host.load_state_path == "s.dat");
  CHECK(is_null_result(reply));

  host.load_state_rc = -1;
  CHECK(call(host, "loadState", msg_str1("s.dat"), reply));
  CHECK(is_string_result(reply, "Could not load the save state"));
}

static void test_set_cheats() {
  FakeHost host;
  Msg reply;

  Msg codes = build([](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_list_start(b, 2);
    dena_put_string(b, "AAAA-BBBB");
    dena_put_string(b, "CCCC-DDDD");
  });
  CHECK(call(host, "setCheats", codes, reply));
  CHECK(host.set_cheats_calls == 1 && host.cheats.size() == 2 &&
        host.cheats[0] == "AAAA-BBBB" && host.cheats[1] == "CCCC-DDDD");
  CHECK(is_null_result(reply));

  // A non-string entry is rejected before set_cheats is called.
  Msg bad = build([](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_list_start(b, 1);
    dena_put_int(b, 5);
  });
  CHECK(call(host, "setCheats", bad, reply));
  CHECK(is_bad_args(reply));
  CHECK(host.set_cheats_calls == 1);

  // Long lists decode too (more values than a small fixed arena).
  Msg many(1 << 16);
  struct dena_buf mb = {many.data(), 0, many.size(), false};
  dena_put_list_start(&mb, 1);
  dena_put_list_start(&mb, 200);
  for (int i = 0; i < 200; i++) dena_put_string(&mb, "ABCD-1234");
  many.resize(mb.len);
  CHECK(call(host, "setCheats", many, reply));
  CHECK(host.set_cheats_calls == 2 && host.cheats.size() == 200);
}

static void touch(const std::string &path);

static void test_set_shader() {
  FakeHost host;
  Msg reply;

  std::string preset = g_card + "/Dena/data/shaders/crt/crt.glslp";
  std::remove(preset.c_str());  // left by an earlier run

  CHECK(call(host, "setShader", msg_str1(""), reply));
  CHECK(is_null_result(reply));
  CHECK(host.set_shader_calls == 1 && host.shader_set.empty());

  // Not on the card, or not a plain id: refused before the host.
  CHECK(call(host, "setShader", msg_str1("crt"), reply));
  CHECK(is_string_result(reply, "Unknown shader"));
  CHECK(call(host, "setShader", msg_str1("../crt"), reply));
  CHECK(is_string_result(reply, "Unknown shader"));
  CHECK(host.set_shader_calls == 1);

  for (const char *d : {"/Dena", "/Dena/data", "/Dena/data/shaders", "/Dena/data/shaders/crt"})
    make_dir((g_card + d).c_str());
  touch(preset);
  CHECK(call(host, "setShader", msg_str1("crt"), reply));
  CHECK(is_null_result(reply));
  CHECK(host.set_shader_calls == 2 && host.shader_set == preset);

  host.shader_error = "bad pass 2";
  CHECK(call(host, "setShader", msg_str1("crt"), reply));
  CHECK(is_string_result(reply, "bad pass 2"));

  // The desktop host names its own preset files (shader-stacks.md).
  host.shader_error.clear();
  host.shader_dir = g_card + "/Dena/data/shaders";
  CHECK(call(host, "setShader", msg_str1("crt"), reply));
  CHECK(is_string_result(reply, "Unknown shader"));  // no crt.slangp there
  touch(host.shader_dir + "/crt.slangp");
  CHECK(call(host, "setShader", msg_str1("crt"), reply));
  CHECK(is_null_result(reply));
  CHECK(host.shader_set == host.shader_dir + "/crt.slangp");
  CHECK(call(host, "setShader", msg_str1("../crt"), reply));
  CHECK(is_string_result(reply, "Unknown shader"));
  std::remove((host.shader_dir + "/crt.slangp").c_str());
}

static void test_screenshots() {
  FakeHost host;
  Msg reply;

  const char *bad[] = {"../x", "a/b", "", "a\\b", "x/../y"};
  for (const char *name : bad) {
    CHECK(call(host, "captureScreenshot", msg_str1(name), reply));
    CHECK(is_string_result(reply, "Invalid screenshot name"));
  }
  CHECK(host.screenshot_calls == 0);

  CHECK(call(host, "captureScreenshot", msg_str1("shot1"), reply));
  CHECK(host.screenshot_calls == 1);
  CHECK(host.screenshot_path == g_card + "/Screenshots/shot1.png");
  CHECK(is_null_result(reply));

  host.screenshot_rc = 1;
  CHECK(call(host, "captureScreenshot", msg_str1("shot1"), reply));
  CHECK(is_string_result(reply, "Could not save the screenshot"));
}

// Checks the StartResult encoding: tags 130/129, the enum index, the error,
// and the <card>/Bios sysdir.
static void check_start(FakeHost &host, int rc, const char *expected_error,
                        int expected_outcome) {
  host.start_rc = rc;
  Msg reply;
  CHECK(call(host, "start", msg_str4("core.so", "rom.gba", "save.srm", "state.st"),
             reply));
  CHECK(host.start_calls == 1);
  CHECK(host.core == "core.so" && host.rom == "rom.gba");
  CHECK(host.sysdir == g_card + "/Bios");
  CHECK(host.srm == "save.srm" && host.state == "state.st");

  struct dena_val v;
  CHECK(decode_reply(reply, &v));
  CHECK(v.type == DENA_VAL_LIST && v.size == 1);
  const struct dena_val *result = dena_list_at(&v, 0);
  CHECK(result && result->type == DENA_VAL_CUSTOM && result->custom == 130);
  const struct dena_val *pair = result ? result->items : nullptr;
  CHECK(pair && pair->type == DENA_VAL_LIST && pair->size == 2);
  const struct dena_val *outcome = dena_list_at(pair, 0);
  const struct dena_val *error = dena_list_at(pair, 1);

  if (expected_outcome >= 0) {
    CHECK(outcome && outcome->type == DENA_VAL_CUSTOM && outcome->custom == 129);
    const struct dena_val *index = outcome ? outcome->items : nullptr;
    CHECK(index && index->type == DENA_VAL_INT &&
          index->i == expected_outcome);
    CHECK(error && error->type == DENA_VAL_NULL);
  } else {
    CHECK(outcome && outcome->type == DENA_VAL_NULL);
    CHECK(error && dena_val_string_eq(error, expected_error));
  }
}

static void touch(const std::string &path) {
  FILE *f = fopen(path.c_str(), "wb");
  if (f) fclose(f);
}

static void test_core_path() {
  FakeHost host;
  dena::GameBridge bridge(&host, g_card);
  make_dir((g_card + "/Dena").c_str());
  make_dir((g_card + "/Dena/lib").c_str());
  std::string lib = g_card + "/Dena/lib/";
  touch(lib + "mgba_libretro.so");
  touch(lib + "libfoo_libretro.so");
  CHECK(bridge.core_path("libmgba_libretro.so") == lib + "mgba_libretro.so");
  CHECK(bridge.core_path("libfoo_libretro.so") == lib + "libfoo_libretro.so");
  CHECK(bridge.core_path("libnone_libretro.so") == "libnone_libretro.so");
  CHECK(bridge.core_path("/abs/core.so") == "/abs/core.so");
}

static void test_start() {
  {
    FakeHost host;
    check_start(host, 0, "", 0);  // fresh
  }
  {
    FakeHost host;
    check_start(host, 1, "", 1);  // resumed
  }
  {
    FakeHost host;
    check_start(host, 2, "", 2);  // bad state
  }
  {
    FakeHost host;
    host.error_text = "corrupt rom";
    check_start(host, -1, "corrupt rom", -1);  // failed
  }
}

static void test_bad_args() {
  FakeHost host;
  Msg reply;
  std::string message;

  // A string where an int is expected.
  CHECK(call(host, "setSpeed", msg_str1("fast"), reply));
  CHECK(is_bad_args(reply, &message));
  CHECK(message.find("setSpeed") != std::string::npos);
  CHECK(host.set_speed_calls == 0);

  // Missing the second boolean.
  CHECK(call(host, "configureRewind", msg_bool1(true), reply));
  CHECK(is_bad_args(reply));
  CHECK(host.rewind_calls == 0);

  // An int where a double is expected.
  CHECK(call(host, "setDisplayAspect", msg_int1(3), reply));
  CHECK(is_bad_args(reply));

  // start with too few arguments.
  CHECK(call(host, "start", msg_str2("a", "b"), reply));
  CHECK(is_bad_args(reply));
  CHECK(host.start_calls == 0);

  // A message that is not a list.
  Msg scalar = build([](struct dena_buf *b) { dena_put_int(b, 3); });
  CHECK(call(host, "pause", scalar, reply));
  CHECK(is_bad_args(reply));
  CHECK(host.pause_calls == 0);

  // Malformed bytes.
  Msg junk = {0x03, 0x00};
  CHECK(call(host, "pause", junk, reply));
  CHECK(is_bad_args(reply));

  // Unknown method.
  CHECK(call(host, "noSuchMethod", msg_null(), reply));
  CHECK(is_bad_args(reply, &message));
  CHECK(message.find("noSuchMethod") != std::string::npos);

  // A channel that is not GameHostApi -> not handled.
  CHECK(!call_channel(host, std::string(dena::kGameEventsChannel) + "onMenuRequested",
                      msg_null(), reply));
  CHECK(!call_channel(host, "dev.flutter.pigeon.dena_android.OtherApi.method",
                      msg_null(), reply));
}

static void test_encode_events() {
  struct dena_val v;

  Msg menu = dena::encode_menu_requested();
  CHECK(decode_reply(menu, &v));
  CHECK(v.type == DENA_VAL_NULL);

  Msg ev = dena::encode_controller_disconnected(2, "Pad X");
  CHECK(decode_reply(ev, &v));
  CHECK(v.type == DENA_VAL_LIST && v.size == 2);
  const struct dena_val *port = dena_list_at(&v, 0);
  const struct dena_val *name = dena_list_at(&v, 1);
  CHECK(port && port->type == DENA_VAL_INT && port->i == 2);
  CHECK(name && dena_val_string_eq(name, "Pad X"));
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <card-dir>\n", argv[0]);
    return 1;
  }
  g_card = argv[1];

  test_channels();
  test_void_methods();
  test_forwarded_scalars();
  test_save_load_state();
  test_set_cheats();
  test_set_shader();
  test_screenshots();
  test_start();
  test_core_path();
  test_bad_args();
  test_encode_events();

  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  puts("bridge: all passed");
  return 0;
}
