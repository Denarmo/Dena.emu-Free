// SPDX-License-Identifier: GPL-3.0-or-later
// SDL3 on a thread of its own: gamepads with hotplug (SDL's mapping
// database; works under Steam Input) and the audio subsystem the platform
// opens its stream on. No SDL window: Flutter owns the window.
// Spec: docs/specs/desktop-shell.md
#ifndef DENA_SDL_INPUT_H
#define DENA_SDL_INPUT_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace dena {

struct SdlInputCallbacks {
  // All on the SDL thread. mask: RetroPad bits plus kMenuGuideBit; ns on
  // the runner's clock (now_ns).
  std::function<void(int port, uint32_t mask, int64_t ns)> buttons;
  std::function<void(int port, int lx, int ly, int rx, int ry)> analog;
  std::function<void(const std::vector<std::string> &names)> players;
  std::function<void(int port, const std::string &name)> disconnected;
  // Any pad, with or without a port: its buttons as the UI sees them
  // (ui_buttons plus the left stick as a D-pad, kMenuGuideBit for Guide;
  // 0 when it goes) and its family (controller-mode.md).
  std::function<void(uint32_t id, uint32_t ui_mask, int family)> ui;
  // The gyro as the touch pointer (gamepads.md, Desktop: profiles and
  // gyro): libretro pointer units, pressed while R3 is held.
  std::function<void(int x, int y, bool pressed)> pointer;
};

class SdlInput {
 public:
  ~SdlInput() { stop(); }
  // Starts the thread and waits until SDL is up. False when SDL failed
  // (no gamepads and no audio; the UI still runs).
  bool start(SdlInputCallbacks cb);
  void stop();
  bool audio_ok() const { return audio_ok_; }
  int gamepads() const { return gamepads_; }
  // The family of the pad used last (or connected first), -1 without pads.
  int family() const { return family_; }
  // Controller profiles as dena_desktop_set_profiles text (pad_profile.h);
  // any thread, applied to every pad at once and to pads that connect later.
  void set_profiles(const std::string &text);
  // Connected pads, one line each: port (-1 waiting), GUID, gyro (0/1),
  // name, tab-separated. Any thread.
  std::string pads_info() const;

 private:
  void thread_main(std::atomic<int> *state);

  SdlInputCallbacks cb_;
  std::thread thread_;
  std::atomic<bool> quit_{false};
  std::atomic<bool> audio_ok_{false};
  std::atomic<int> gamepads_{0};
  std::atomic<int> family_{-1};
  mutable std::mutex info_mtx_;  // guards the two strings below
  std::string profiles_text_;
  bool profiles_dirty_ = false;
  std::string pads_info_;
};

}  // namespace dena

#endif
