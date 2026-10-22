// SPDX-License-Identifier: GPL-3.0-or-later
// Answers the Dart session's GameHostApi Pigeon messages in the launcher.
// Spec: docs/specs/handheld-session.md
#ifndef DENA_GAME_BRIDGE_H
#define DENA_GAME_BRIDGE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace dena {

// What the bridge drives: the runner in the launcher, a fake in tests.
class GameHost {
 public:
  virtual ~GameHost() = default;
  // Runner::StartResult values: -1 error (see error()), 0 fresh, 1 resumed,
  // 2 bad state.
  virtual int start(const std::string &core, const std::string &rom, const std::string &sysdir,
                    const std::string &srm, const std::string &state) = 0;
  virtual std::string error() = 0;
  virtual void pause() = 0;
  virtual void resume() = 0;
  virtual void set_speed(int n) = 0;
  // Audio buffer target in ms (performance.md); applies at the next start.
  virtual void set_audio_latency_ms(int ms) = 0;
  // Internal resolution factor (shaders.md); applies at the next start.
  virtual void set_upscale(int factor) = 0;
  // 16:9 widescreen hack (desktop-resolution.md); applies at the next start.
  virtual void set_widescreen(bool on) = 0;
  virtual void configure_rewind(bool enabled, bool l2_hold) = 0;
  virtual void set_rewinding(bool on) = 0;
  virtual void save_now() = 0;
  virtual int save_state(const std::string &state, const std::string &png) = 0;  // 0 ok
  virtual int load_state(const std::string &state) = 0;                          // 0 ok
  virtual int screenshot(const std::string &png) = 0;                            // 0 ok
  virtual void set_cheats(std::vector<std::string> codes) = 0;
  // Shader preset path, "" for Off. Returns an error message, "" on success.
  virtual std::string set_shader(const std::string &path) = 0;
  // The preset file of a shader id (already checked to be a plain name), or
  // "" to use the card's bundled .glslp (the handheld). The desktop answers
  // with its slang presets (shader-stacks.md).
  virtual std::string shader_path(const std::string &id) {
    (void)id;
    return "";
  }
  virtual void stop() = 0;
};

// Channel prefix of the session API (game_api.dart).
extern const char kGameHostChannel[];  // "dev.flutter.pigeon.dena_android.GameHostApi."

class GameBridge {
 public:
  // card: the SD card root ($DENA_CARD): Bios and Screenshots live there.
  GameBridge(GameHost *host, std::string card) : host_(host), card_(std::move(card)) {}

  // Handles one message on `channel`. Returns false when the channel is not
  // a GameHostApi method (the launcher then sends an empty reply); otherwise
  // `reply` holds the encoded Pigeon envelope.
  bool handle(const std::string &channel, const uint8_t *msg, size_t len,
              std::vector<uint8_t> &reply);

  // Where the core `name` from the app lives on the card (handheld-session.md).
  std::string core_path(const std::string &name) const;

 private:
  GameHost *host_;
  std::string card_;
};

// Encodes a GameEventsApi call: the argument list for the channel
// "dev.flutter.pigeon.dena_android.GameEventsApi.<method>".
std::vector<uint8_t> encode_menu_requested();
std::vector<uint8_t> encode_controller_disconnected(int port, const std::string &name);
extern const char kGameEventsChannel[];  // "dev.flutter.pigeon.dena_android.GameEventsApi."

}  // namespace dena

#endif
