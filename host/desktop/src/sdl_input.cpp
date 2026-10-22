// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md, gamepads.md (Desktop)
#include "sdl_input.h"

#include <SDL3/SDL.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>

#include "desktop_map.h"
#include "pad_profile.h"
#include "runner.h"

namespace dena {

namespace {

struct Pad {
  SDL_Gamepad *gp = nullptr;
  std::string name;
  std::string guid;
  bool has_gyro = false;
  bool gyro_on = false;  // sensor enabled
  PadProfile profile;
  int gyro_x = 0, gyro_y = 0;  // the gyro's stick (kGyro*Stick)
  GyroPointer pointer;
  uint64_t gyro_ns = 0;  // last sensor timestamp
  bool touching = false;
  uint32_t mask = 0;  // as pressed (RetroPad bits plus kMenuGuideBit)
  int axis[6] = {};
  int family = kFamilyGeneric;
  bool south_confirms = true;
  uint32_t stick = 0;    // left stick as D-pad bits (ui_stick)
  uint32_t ui_mask = 0;  // last sent to cb.ui
};

// What the game sees of a pad: remapped buttons, R3 kept for the gyro
// pointer's touch, and the menu chord as pressed (so a remap can't hide it).
uint32_t game_mask(const Pad &p) {
  uint32_t m = remap_buttons(p.mask, p.profile);
  if (p.profile.gyro == kGyroPointer && p.has_gyro) m &= ~(1u << kGyroTouchBit);
  if (is_menu_combo(p.mask)) m |= kMenuGuideBit;
  return m;
}

}  // namespace

void SdlInput::set_profiles(const std::string &text) {
  std::lock_guard<std::mutex> lk(info_mtx_);
  profiles_text_ = text;
  profiles_dirty_ = true;
}

std::string SdlInput::pads_info() const {
  std::lock_guard<std::mutex> lk(info_mtx_);
  return pads_info_;
}

bool SdlInput::start(SdlInputCallbacks cb) {
  if (thread_.joinable()) return true;
  cb_ = std::move(cb);
  quit_ = false;
  std::atomic<int> state{0};  // 0 starting, 1 up, -1 failed
  thread_ = std::thread(&SdlInput::thread_main, this, &state);
  while (state == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  if (state < 0) {
    thread_.join();
    return false;
  }
  return true;
}

void SdlInput::stop() {
  if (!thread_.joinable()) return;
  quit_ = true;
  thread_.join();
}

void SdlInput::thread_main(std::atomic<int> *state) {
  // There is no SDL window, so SDL never sees focus: keep pad events
  // flowing while the Flutter window is in front.
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  SDL_SetHint(SDL_HINT_JOYSTICK_THREAD, "1");  // Windows raw input on its own thread
  SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, "256");
  const bool pads = SDL_InitSubSystem(SDL_INIT_GAMEPAD);
  if (!pads) std::fprintf(stderr, "dena: SDL gamepads: %s\n", SDL_GetError());
  audio_ok_ = SDL_InitSubSystem(SDL_INIT_AUDIO);
  if (!audio_ok_) std::fprintf(stderr, "dena: SDL audio: %s\n", SDL_GetError());
  if (!pads && !audio_ok_) {
    SDL_Quit();
    *state = -1;
    return;
  }
  // SDL timestamps count from SDL's start; the runner's clock from boot.
  const int64_t offset = now_ns() - int64_t(SDL_GetTicksNS());
  *state = 1;  // `state` is gone after this

  PortTable ports;
  PadProfiles profiles;
  std::map<SDL_JoystickID, Pad> pads_by_id;
  auto send_buttons = [&](const Pad &p, SDL_JoystickID id, int64_t ns) {
    const int port = ports.port_of(id);
    if (port >= 0 && cb_.buttons) cb_.buttons(port, game_mask(p), ns);
  };
  auto send_analog = [&](const Pad &p, SDL_JoystickID id) {
    const int port = ports.port_of(id);
    if (port < 0 || !cb_.analog) return;
    int lx = p.axis[SDL_GAMEPAD_AXIS_LEFTX], ly = p.axis[SDL_GAMEPAD_AXIS_LEFTY];
    int rx = p.axis[SDL_GAMEPAD_AXIS_RIGHTX], ry = p.axis[SDL_GAMEPAD_AXIS_RIGHTY];
    if (p.profile.gyro == kGyroLeftStick) {
      lx = mix_axis(lx, p.gyro_x);
      ly = mix_axis(ly, p.gyro_y);
    } else if (p.profile.gyro == kGyroRightStick) {
      rx = mix_axis(rx, p.gyro_x);
      ry = mix_axis(ry, p.gyro_y);
    }
    cb_.analog(port, lx, ly, rx, ry);
  };
  auto publish_info = [&] {
    std::string info;
    for (const auto &[id, pad] : pads_by_id)
      info += std::to_string(ports.port_of(uint32_t(id))) + '\t' + pad.guid + '\t' +
              (pad.has_gyro ? "1" : "0") + '\t' + pad.name + '\n';
    std::lock_guard<std::mutex> lk(info_mtx_);
    pads_info_ = info;
  };
  // A pad's profile from the current set; the gyro sensor runs only while a
  // profile uses it.
  auto apply_profile = [&](Pad &p, SDL_JoystickID id) {
    const int old_gyro = p.profile.gyro;
    p.profile = profiles.for_guid(p.guid);
    const bool want = p.has_gyro && p.profile.gyro != kGyroOff;
    if (want != p.gyro_on)
      p.gyro_on = SDL_SetGamepadSensorEnabled(p.gp, SDL_SENSOR_GYRO, want) && want;
    p.gyro_x = p.gyro_y = 0;
    p.gyro_ns = 0;
    if (p.profile.gyro == kGyroPointer && old_gyro != kGyroPointer)
      p.pointer.reset(p.profile.pointer_bottom);
    if (p.touching && p.profile.gyro != kGyroPointer) {
      p.touching = false;
      if (cb_.pointer) cb_.pointer(p.pointer.x, p.pointer.y, false);
    }
    send_buttons(p, id, now_ns());
    send_analog(p, id);
  };

  auto send_ui = [&](Pad &p, SDL_JoystickID id) {
    const uint32_t ui = ui_buttons(p.mask & 0xffffu, p.south_confirms) | p.stick |
                        (p.mask & kMenuGuideBit);
    if (ui == p.ui_mask) return;
    p.ui_mask = ui;
    if (ui) family_ = p.family;
    if (cb_.ui) cb_.ui(uint32_t(id), ui, p.family);
  };

  while (!quit_) {
    {
      std::string text;
      bool dirty = false;
      {
        std::lock_guard<std::mutex> lk(info_mtx_);
        dirty = profiles_dirty_;
        profiles_dirty_ = false;
        if (dirty) text = profiles_text_;
      }
      if (dirty) {
        profiles.parse(text);
        for (auto &[id, pad] : pads_by_id) apply_profile(pad, id);
      }
    }
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
      switch (e.type) {
        case SDL_EVENT_GAMEPAD_ADDED: {
          const SDL_JoystickID id = e.gdevice.which;
          if (pads_by_id.count(id)) break;
          Pad p;
          p.gp = SDL_OpenGamepad(id);
          if (!p.gp) break;
          const char *name = SDL_GetGamepadName(p.gp);
          p.name = name ? name : "Controller";
          p.family = pad_family(int(SDL_GetGamepadType(p.gp)), SDL_GetGamepadVendor(p.gp),
                                SDL_GetGamepadProduct(p.gp));
          p.south_confirms = south_is_confirm(
              int(SDL_GetGamepadButtonLabel(p.gp, SDL_GAMEPAD_BUTTON_SOUTH)));
          char guid[64] = {};
          SDL_GUIDToString(SDL_GetGamepadGUIDForID(id), guid, int(sizeof guid));
          p.guid = guid;
          // Deck, DualSense, DualShock 4, Switch Pro and Joy-Cons; not
          // through Steam Input's virtual pad (Steam keeps the gyro).
          p.has_gyro = SDL_GamepadHasSensor(p.gp, SDL_SENSOR_GYRO);
          if (pads_by_id.empty()) family_ = p.family;
          ports.connect(uint32_t(id), p.name);
          Pad &added = pads_by_id[id] = p;
          apply_profile(added, id);
          gamepads_ = int(pads_by_id.size());
          publish_info();
          if (cb_.players) cb_.players(ports.names());
          break;
        }
        case SDL_EVENT_GAMEPAD_REMOVED: {
          const SDL_JoystickID id = e.gdevice.which;
          auto it = pads_by_id.find(id);
          if (it == pads_by_id.end()) break;
          const std::string name = it->second.name;
          if (it->second.ui_mask && cb_.ui) cb_.ui(uint32_t(id), 0, it->second.family);
          if (it->second.touching && cb_.pointer)
            cb_.pointer(it->second.pointer.x, it->second.pointer.y, false);
          SDL_CloseGamepad(it->second.gp);
          pads_by_id.erase(it);
          gamepads_ = int(pads_by_id.size());
          if (pads_by_id.empty()) family_ = -1;
          const int port = ports.disconnect(uint32_t(id));
          if (port >= 0) {
            if (cb_.buttons) cb_.buttons(port, 0, now_ns());
            if (cb_.analog) cb_.analog(port, 0, 0, 0, 0);
            if (cb_.disconnected) cb_.disconnected(port, name);
            // A waiting controller may have moved into the port.
            for (auto &[other, pad] : pads_by_id)
              if (ports.port_of(uint32_t(other)) == port) {
                send_buttons(pad, other, now_ns());
                send_analog(pad, other);
              }
          }
          publish_info();
          if (cb_.players) cb_.players(ports.names());
          break;
        }
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
        case SDL_EVENT_GAMEPAD_BUTTON_UP: {
          auto it = pads_by_id.find(e.gbutton.which);
          if (it == pads_by_id.end()) break;
          uint32_t bit = 0;
          if (e.gbutton.button == kSdlGuide) {
            bit = kMenuGuideBit;
          } else if (int b = pad_button_bit(e.gbutton.button); b >= 0) {
            bit = 1u << b;
          } else {
            break;
          }
          Pad &p = it->second;
          p.mask = e.gbutton.down ? (p.mask | bit) : (p.mask & ~bit);
          send_buttons(p, it->first, int64_t(e.gbutton.timestamp) + offset);
          if (p.profile.gyro == kGyroPointer && p.has_gyro &&
              bit == (1u << kGyroTouchBit) && cb_.pointer) {
            p.touching = e.gbutton.down;
            cb_.pointer(p.pointer.x, p.pointer.y, p.touching);
          }
          send_ui(p, it->first);
          break;
        }
        case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
          auto it = pads_by_id.find(e.gaxis.which);
          if (it == pads_by_id.end() || e.gaxis.axis >= 6) break;
          Pad &p = it->second;
          p.axis[e.gaxis.axis] = e.gaxis.value;
          if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER ||
              e.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
            const uint32_t bit = e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER ? 1u << 12 : 1u << 13;
            const uint32_t mask = e.gaxis.value > kTriggerThreshold ? (p.mask | bit) : (p.mask & ~bit);
            if (mask != p.mask) {
              p.mask = mask;
              send_buttons(p, it->first, int64_t(e.gaxis.timestamp) + offset);
            }
          } else {
            send_analog(p, it->first);
            p.stick = ui_stick(p.axis[SDL_GAMEPAD_AXIS_LEFTX], p.axis[SDL_GAMEPAD_AXIS_LEFTY],
                               p.stick);
          }
          send_ui(p, it->first);
          break;
        }
        case SDL_EVENT_GAMEPAD_SENSOR_UPDATE: {
          if (e.gsensor.sensor != SDL_SENSOR_GYRO) break;
          auto it = pads_by_id.find(e.gsensor.which);
          if (it == pads_by_id.end()) break;
          Pad &p = it->second;
          constexpr float kDeg = 180.0f / 3.14159265f;
          const float pitch = e.gsensor.data[0] * kDeg, yaw = e.gsensor.data[1] * kDeg;
          if (p.profile.gyro == kGyroPointer) {
            const uint64_t ts = e.gsensor.sensor_timestamp;
            const float dt = p.gyro_ns && ts > p.gyro_ns ? float(ts - p.gyro_ns) * 1e-9f : 0.0f;
            p.gyro_ns = ts;
            const int x = p.pointer.x, y = p.pointer.y;
            p.pointer.step(pitch, yaw, dt, p.profile);
            if ((x != p.pointer.x || y != p.pointer.y) && cb_.pointer)
              cb_.pointer(p.pointer.x, p.pointer.y, p.touching);
          } else if (p.profile.gyro != kGyroOff) {
            int x = 0, y = 0;
            gyro_stick(pitch, yaw, p.profile, &x, &y);
            if (x != p.gyro_x || y != p.gyro_y) {
              p.gyro_x = x;
              p.gyro_y = y;
              send_analog(p, it->first);
            }
          }
          break;
        }
        default:
          break;
      }
    }
    // XInput is polled: 1 ms keeps pad latency under a millisecond.
    SDL_DelayNS(1000000);
  }
  for (auto &[id, pad] : pads_by_id) SDL_CloseGamepad(pad.gp);
  gamepads_ = 0;
  family_ = -1;
  SDL_Quit();
}

}  // namespace dena
