// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop host's pure parts, tested without SDL, GL or a window:
// controller and keyboard bindings, port assignment, core file names,
// storage paths and the session events sent to Dart.
// Spec: docs/specs/desktop-shell.md
#ifndef DENA_DESKTOP_MAP_H
#define DENA_DESKTOP_MAP_H

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace dena {

constexpr int kDesktopPorts = 8;  // DENA_MAX_PORTS (gamepads.md, Desktop: eight players)

// RetroPad joypad bit (RETRO_DEVICE_ID_JOYPAD_*) for an SDL3 gamepad button
// (SDL_GamepadButton value), -1 when unbound. Positional: the bottom face
// button is RetroPad B, the right one A (Nintendo layout), as on Android.
int pad_button_bit(int sdl_button);
// SDL_GamepadButton values the bindings use (stable SDL3 ABI).
enum : int {
  kSdlSouth = 0, kSdlEast = 1, kSdlWest = 2, kSdlNorth = 3, kSdlBack = 4,
  kSdlGuide = 5, kSdlStart = 6, kSdlLeftStick = 7, kSdlRightStick = 8,
  kSdlLeftShoulder = 9, kSdlRightShoulder = 10, kSdlDpadUp = 11,
  kSdlDpadDown = 12, kSdlDpadLeft = 13, kSdlDpadRight = 14,
};
// Trigger travel (0..32767) past which L2/R2 count as pressed.
constexpr int kTriggerThreshold = 12000;

// RetroPad bit for a keyboard key (DENA_DESKTOP_KEY_* or ASCII), -1 when
// unbound. Escape (kKeyMenu) and R (kKeyRewind) are not RetroPad buttons.
int key_bit(int key);
constexpr int kKeyMenu = -2;
// R rewinds while held (rewind.md, Long rewind; RetroArch's default too).
constexpr int kKeyRewind = -3;
int key_action(int key);  // key_bit, kKeyMenu for Escape or kKeyRewind for R

// Start + Select, or Guide, opens the pause menu (gamepads.md).
bool is_menu_combo(uint32_t mask);
constexpr uint32_t kMenuGuideBit = 1u << 16;  // outside the 16 RetroPad bits

// ---- Controller navigation of the UI (controller-mode.md) ----

// Controller families for the hint bar's button glyphs (desktop.h,
// DENA_DESKTOP_FAMILY_*).
enum : int {
  kFamilyGeneric = 0, kFamilyXbox = 1, kFamilyPlayStation = 2,
  kFamilyNintendo = 3, kFamilySteamDeck = 4,
};
// The family of a pad from SDL_GetGamepadType (stable SDL3 ABI values) and
// its USB ids. The Deck's built-in controls are Valve 0x28de:0x1205.
int pad_family(int sdl_type, uint16_t vendor, uint16_t product);
// Whether the pad's bottom face button is labelled A or Cross (Xbox,
// PlayStation, Deck, most generic pads) rather than B (Nintendo layout).
// From SDL_GetGamepadButtonLabel of the south button.
bool south_is_confirm(int sdl_south_label);
// The UI's view of a pad's RetroPad mask: the games stay positional (right =
// A), but in menus the button printed A (or Cross) confirms and the one
// printed B (or Circle) goes back, so face buttons swap A/B and X/Y on pads
// whose bottom button confirms.
uint32_t ui_buttons(uint32_t mask, bool south_confirms);
// D-pad bits (RetroPad up/down/left/right) from the left stick, so menus
// also move with it: on past half travel, off again under a third.
uint32_t ui_stick(int lx, int ly, uint32_t prev);
// UI actions for one pad's mask change: RetroPad ids 0-15, or kUiMenu for
// Guide, each with whether it went down. Calls fn(action, down) per bit.
constexpr int kUiMenu = 16;
template <typename Fn>
void ui_changes(uint32_t before, uint32_t after, Fn fn) {
  const uint32_t changed = before ^ after;
  for (int bit = 0; bit <= 16; bit++)
    if (changed & (1u << bit)) fn(bit == 16 ? kUiMenu : bit, (after & (1u << bit)) != 0);
}

// Controllers to ports: the lowest free port, in connection order. A ninth
// controller waits without a port until one frees up.
class PortTable {
 public:
  // Returns the port given to device id, or -1 when all are taken.
  int connect(uint32_t id, const std::string &name);
  // Returns the port the device had, -1 when it had none. A waiting device
  // takes the freed port.
  int disconnect(uint32_t id);
  int port_of(uint32_t id) const;
  // Names per port, "" for a free one (GameEventsApi.onPlayersChanged).
  std::vector<std::string> names() const;
  int count() const { return int(devices_.size()); }

 private:
  struct Device {
    uint32_t id;
    std::string name;
    int port;
  };
  std::vector<Device> devices_;
};

// Android's core library name ("libmgba_libretro.so") as the desktop file
// name: "mgba_libretro.dll" on Windows, "mgba_libretro.so" elsewhere. PS1
// becomes Beetle PSX HW (mednafen_psx_hw), the x86_64 PS1 core.
std::string desktop_core_file(const std::string &android_name, bool windows);
// Where to look for that core, in order: <root>/cores, then <lib_dir>/cores.
std::vector<std::string> core_candidates(const std::string &android_name, const std::string &root,
                                         const std::string &lib_dir, bool windows);
// Support files a core reads from <sysdir>/<folder> (psp.md, Core): the
// package ships PPSSPP's fonts, PPGe atlas and tables in
// <lib_dir>/cores/PPSSPP with a dena-assets.txt stamp naming the version.
// Before that core starts they are copied to <sysdir>/PPSSPP unless the same
// stamp is there (as the Android shell does). Dolphin's Sys folder comes the
// same way, as <lib_dir>/cores/dolphin-emu (gamecube-wii.md, Core). False
// only when a copy failed.
bool install_core_assets(const std::string &core_path, const std::string &lib_dir,
                         const std::string &sysdir);

// Multitap (gamepads.md, Desktop: eight players): on while more than two
// ports have a controller, for games that read a third player through it.
bool wants_multitap(const std::vector<std::string> &names);

// Pigeon payloads for GameEventsApi calls the desktop host sends.
std::vector<uint8_t> encode_no_args();  // onMenuRequested, onGamepadUsed
std::vector<uint8_t> encode_players_changed(const std::vector<std::string> &names);

// The achievement unlock chime (achievements.md, Desktop overlay): two short
// rising tones, 0.3 s at 48 kHz, added to the game's S16 stereo audio.
constexpr uint32_t kChimeFrames = 14400;
// Mixes the chime from frame *pos into stereo[0..frames*2), clipping, and
// advances *pos (at most kChimeFrames, where it stops).
void mix_chime(int16_t *stereo, uint32_t frames, uint32_t *pos);

// One latency log line: {"t_ms":<unix ms>, <metrics fields>}.
std::string latency_line(int64_t unix_ms, const std::string &metrics_json);

}  // namespace dena

#endif
