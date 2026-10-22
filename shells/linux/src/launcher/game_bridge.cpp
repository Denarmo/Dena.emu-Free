// SPDX-License-Identifier: GPL-3.0-or-later
// Launcher GameHostApi bridge: answers the Dart session's Pigeon calls.
// Spec: docs/specs/handheld-session.md
#include "game_bridge.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "dena/std_codec.h"

#ifdef _WIN32
#include <direct.h>
#else
#include <sys/stat.h>
#endif

namespace dena {

const char kGameHostChannel[] = "dev.flutter.pigeon.dena_android.GameHostApi.";
const char kGameEventsChannel[] = "dev.flutter.pigeon.dena_android.GameEventsApi.";

namespace {

// Encodes a Pigeon envelope into reply, growing the vector until the encoder
// fits (the codec reports overflow through dena_buf.failed).
template <typename Fn>
void fill_reply(std::vector<uint8_t> &reply, Fn fn) {
  size_t cap = 64;
  for (;;) {
    reply.resize(cap);
    struct dena_buf b = {reply.data(), 0, reply.size(), false};
    fn(&b);
    if (!b.failed) {
      reply.resize(b.len);
      return;
    }
    cap *= 2;
  }
}

// Error envelope: ["bad-args", message, null].
void reply_bad_args(std::vector<uint8_t> &reply, const std::string &method) {
  const std::string message = "bad arguments for " + method;
  fill_reply(reply, [&](struct dena_buf *b) {
    dena_put_list_start(b, 3);
    dena_put_string(b, "bad-args");
    dena_put_string(b, message.c_str());
    dena_put_null(b);
  });
}

// Success envelope holding a string result: [message].
void reply_string(std::vector<uint8_t> &reply, const char *message) {
  fill_reply(reply, [&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_string(b, message);
  });
}

// Success envelope for a void method: [null].
void reply_null(std::vector<uint8_t> &reply) {
  fill_reply(reply, [](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_null(b);
  });
}

// The i-th argument, or NULL when args is empty/not a list/out of range.
const struct dena_val *arg_at(const struct dena_val *args, size_t i) {
  return args ? dena_list_at(args, i) : nullptr;
}

bool arg_int(const struct dena_val *args, size_t i, int64_t *out) {
  const struct dena_val *v = arg_at(args, i);
  if (!v || v->type != DENA_VAL_INT) return false;
  *out = v->i;
  return true;
}

bool arg_double(const struct dena_val *args, size_t i, double *out) {
  const struct dena_val *v = arg_at(args, i);
  if (!v || v->type != DENA_VAL_DOUBLE) return false;
  *out = v->d;
  return true;
}

bool arg_bool(const struct dena_val *args, size_t i, bool *out) {
  const struct dena_val *v = arg_at(args, i);
  if (!v) return false;
  if (v->type == DENA_VAL_TRUE) {
    *out = true;
    return true;
  }
  if (v->type == DENA_VAL_FALSE) {
    *out = false;
    return true;
  }
  return false;
}

bool arg_string(const struct dena_val *args, size_t i, std::string *out) {
  const struct dena_val *v = arg_at(args, i);
  if (!v || v->type != DENA_VAL_STRING) return false;
  out->assign(reinterpret_cast<const char *>(v->data), v->size);
  return true;
}

void make_dir(const std::string &path) {
#ifdef _WIN32
  _mkdir(path.c_str());
#else
  mkdir(path.c_str(), 0755);
#endif
}

bool exists(const std::string &path) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (f) std::fclose(f);
  return f != nullptr;
}

}  // namespace

// The app names Android's packaged libraries ("libmgba_libretro.so"); the
// card keeps cores in Dena/lib, built without the "lib" prefix.
std::string GameBridge::core_path(const std::string &name) const {
  if (name.find('/') != std::string::npos) return name;
  std::string dir = card_ + "/Dena/lib/";
  if (exists(dir + name)) return dir + name;
  if (name.compare(0, 3, "lib") == 0 && exists(dir + name.substr(3))) return dir + name.substr(3);
  return name;  // left to the library search path
}

bool GameBridge::handle(const std::string &channel, const uint8_t *msg, size_t len,
                        std::vector<uint8_t> &reply) {
  const std::string prefix(kGameHostChannel);
  if (channel.size() < prefix.size() ||
      channel.compare(0, prefix.size(), prefix) != 0)
    return false;
  const std::string method = channel.substr(prefix.size());

  // The message is the argument list. A no-arg call may send a null or an
  // empty buffer; both mean an empty list.
  // Every value takes at least one byte, so len + 1 nodes always fit.
  std::vector<struct dena_val> vals(len + 1);
  struct dena_val_arena arena = {vals.data(), vals.size(), 0};
  struct dena_val root;
  const struct dena_val *args = nullptr;
  if (msg != nullptr && len > 0) {
    if (dena_decode(msg, len, &arena, &root) != 0) {
      reply_bad_args(reply, method);
      return true;
    }
    if (root.type == DENA_VAL_LIST)
      args = &root;
    else if (root.type != DENA_VAL_NULL) {
      reply_bad_args(reply, method);
      return true;
    }
  }

  if (method == "start") {
    std::string core, rom, srm, state;
    if (!arg_string(args, 0, &core) || !arg_string(args, 1, &rom) ||
        !arg_string(args, 2, &srm) || !arg_string(args, 3, &state)) {
      reply_bad_args(reply, method);
      return true;
    }
    const int rc = host_->start(core_path(core), rom, card_ + "/Bios", srm, state);
    const std::string error = rc == -1 ? host_->error() : std::string();
    const int outcome = rc == 1 ? 1 : rc == 2 ? 2 : 0;
    // [StartResult(outcome, error)]: custom 130 wraps [outcome, error],
    // outcome is custom 129 wrapping the enum index.
    fill_reply(reply, [&](struct dena_buf *b) {
      dena_put_list_start(b, 1);
      dena_put_custom_start(b, 130);
      dena_put_list_start(b, 2);
      if (rc == -1) {
        dena_put_null(b);
        dena_put_string(b, error.c_str());
      } else {
        dena_put_custom_start(b, 129);
        dena_put_int(b, outcome);
        dena_put_null(b);
      }
    });
    return true;
  }

  if (method == "pause") {
    host_->pause();
    reply_null(reply);
    return true;
  }

  if (method == "resume") {
    host_->resume();
    reply_null(reply);
    return true;
  }

  if (method == "setSpeed") {
    int64_t n = 0;
    if (!arg_int(args, 0, &n)) {
      reply_bad_args(reply, method);
      return true;
    }
    host_->set_speed(static_cast<int>(n));
    reply_null(reply);
    return true;
  }

  if (method == "setAudioLatency" || method == "setUpscale") {
    int64_t n = 0;
    if (!arg_int(args, 0, &n)) {
      reply_bad_args(reply, method);
      return true;
    }
    if (method == "setAudioLatency")
      host_->set_audio_latency_ms(static_cast<int>(n));
    else
      host_->set_upscale(static_cast<int>(n));
    reply_null(reply);
    return true;
  }

  if (method == "setWidescreen") {
    bool on = false;
    if (!arg_bool(args, 0, &on)) {
      reply_bad_args(reply, method);
      return true;
    }
    host_->set_widescreen(on);
    reply_null(reply);
    return true;
  }

  if (method == "configureRewind") {
    bool enabled = false, l2_hold = false;
    if (!arg_bool(args, 0, &enabled) || !arg_bool(args, 1, &l2_hold)) {
      reply_bad_args(reply, method);
      return true;
    }
    host_->configure_rewind(enabled, l2_hold);
    reply_null(reply);
    return true;
  }

  if (method == "setDisplayAspect") {
    double aspect = 0;
    if (!arg_double(args, 0, &aspect)) {
      reply_bad_args(reply, method);
      return true;
    }
    (void)aspect;  // no external display on handhelds
    reply_null(reply);
    return true;
  }

  // Accepted without effect: ALSA keeps fixed periods (handheld-session.md)
  // and the 640x480-class screens gain nothing from a higher internal
  // resolution, so the Android-only knobs must not fail a game's start.
  if (method == "setAudioLatency" || method == "setUpscale") {
    int64_t n = 0;
    if (!arg_int(args, 0, &n)) {
      reply_bad_args(reply, method);
      return true;
    }
    reply_null(reply);
    return true;
  }

  if (method == "setAnalogMode") {
    bool on = false;
    if (!arg_bool(args, 0, &on)) {
      reply_bad_args(reply, method);
      return true;
    }
    (void)on;  // sticks follow the profile
    reply_null(reply);
    return true;
  }

  if (method == "setRewinding") {
    bool on = false;
    if (!arg_bool(args, 0, &on)) {
      reply_bad_args(reply, method);
      return true;
    }
    host_->set_rewinding(on);
    reply_null(reply);
    return true;
  }

  if (method == "saveNow") {
    host_->save_now();
    reply_null(reply);
    return true;
  }

  if (method == "saveState") {
    std::string state, png;
    if (!arg_string(args, 0, &state) || !arg_string(args, 1, &png)) {
      reply_bad_args(reply, method);
      return true;
    }
    if (host_->save_state(state, png) == 0)
      reply_null(reply);
    else
      reply_string(reply, "Could not write the save state");
    return true;
  }

  if (method == "loadState") {
    std::string state;
    if (!arg_string(args, 0, &state)) {
      reply_bad_args(reply, method);
      return true;
    }
    if (host_->load_state(state) == 0)
      reply_null(reply);
    else
      reply_string(reply, "Could not load the save state");
    return true;
  }

  if (method == "setCheats") {
    const struct dena_val *list = arg_at(args, 0);
    if (!list || list->type != DENA_VAL_LIST) {
      reply_bad_args(reply, method);
      return true;
    }
    std::vector<std::string> codes;
    codes.reserve(list->size);
    for (size_t i = 0; i < list->size; i++) {
      const struct dena_val *e = dena_list_at(list, i);
      if (!e || e->type != DENA_VAL_STRING) {
        reply_bad_args(reply, method);
        return true;
      }
      codes.emplace_back(reinterpret_cast<const char *>(e->data), e->size);
    }
    host_->set_cheats(std::move(codes));
    reply_null(reply);
    return true;
  }

  if (method == "setTouchMode") {
    bool on = false;
    if (!arg_bool(args, 0, &on)) {
      reply_bad_args(reply, method);
      return true;
    }
    (void)on;  // no touch skin on handhelds
    reply_null(reply);
    return true;
  }

  if (method == "setShader") {
    std::string id;
    if (!arg_string(args, 0, &id)) {
      reply_bad_args(reply, method);
      return true;
    }
    // Ids are folder names of the bundled shaders (shaders.md), never paths.
    std::string path;
    if (!id.empty()) {
      bool ok = true;
      for (char c : id)
        ok = ok && ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_');
      if (ok) path = host_->shader_path(id);
      if (path.empty()) path = card_ + "/Dena/data/shaders/" + id + "/" + id + ".glslp";
      if (!ok || !exists(path)) {
        reply_string(reply, "Unknown shader");
        return true;
      }
    }
    const std::string err = host_->set_shader(path);
    if (err.empty())
      reply_null(reply);
    else
      reply_string(reply, err.c_str());
    return true;
  }

  if (method == "captureScreenshot") {
    std::string name;
    if (!arg_string(args, 0, &name)) {
      reply_bad_args(reply, method);
      return true;
    }
    if (name.empty() || name.find('/') != std::string::npos ||
        name.find('\\') != std::string::npos ||
        name.find("..") != std::string::npos) {
      reply_string(reply, "Invalid screenshot name");
      return true;
    }
    const std::string dir = card_ + "/Screenshots";
    make_dir(dir);
    if (host_->screenshot(dir + "/" + name + ".png") == 0)
      reply_null(reply);
    else
      reply_string(reply, "Could not save the screenshot");
    return true;
  }

  if (method == "stop") {
    host_->stop();
    reply_null(reply);
    return true;
  }

  reply_bad_args(reply, method);
  return true;
}

std::vector<uint8_t> encode_menu_requested() {
  // Pigeon sends a single null for a no-argument FlutterApi call.
  std::vector<uint8_t> out(8);
  struct dena_buf b = {out.data(), 0, out.size(), false};
  dena_put_null(&b);
  out.resize(b.len);
  return out;
}

std::vector<uint8_t> encode_controller_disconnected(int port, const std::string &name) {
  std::vector<uint8_t> out(64);
  for (;;) {
    struct dena_buf b = {out.data(), 0, out.size(), false};
    dena_put_list_start(&b, 2);
    dena_put_int(&b, port);
    dena_put_string(&b, name.c_str());
    if (!b.failed) {
      out.resize(b.len);
      return out;
    }
    out.resize(out.size() * 2);
  }
}

}  // namespace dena
