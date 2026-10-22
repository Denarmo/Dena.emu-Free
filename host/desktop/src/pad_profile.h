// SPDX-License-Identifier: GPL-3.0-or-later
// Controller profiles and gyro aiming for the desktop host, without SDL:
// a profile remaps a pad's RetroPad buttons and turns its gyro into a stick
// or the touch pointer. Dart picks the profile for each controller (per game,
// per controller, precedence in the spec) and sends them as text.
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro)
#ifndef DENA_PAD_PROFILE_H
#define DENA_PAD_PROFILE_H

#include <cstdint>
#include <map>
#include <string>

namespace dena {

enum GyroMode : int {
  kGyroOff = 0,
  kGyroLeftStick = 1,   // N64 aiming (the N64 stick), GameCube main stick
  kGyroRightStick = 2,  // camera sticks, N64 C-buttons
  kGyroPointer = 3,     // DS touch screen, PSP pointer: R3 touches
};

// The RetroPad bit that touches the screen while the gyro is the pointer
// (R3, as the right-stick pointer in ds.md). Games don't see it then.
constexpr int kGyroTouchBit = 15;

// Gyro speed (degrees a second) that tilts a stick fully at sensitivity 1.
constexpr float kGyroStickFullDps = 120.0f;
// Degrees of turn that sweep the pointer across its whole width at
// sensitivity 1.
constexpr float kGyroPointerSweepDeg = 60.0f;

struct PadProfile {
  // Target RetroPad bit per source bit (RETRO_DEVICE_ID_JOYPAD_*), -1 for
  // unbound. Identity by default.
  int8_t map[16];
  int gyro = kGyroOff;
  float sensitivity = 1.0f;   // 0.1 .. 5
  float deadzone_dps = 1.5f;  // gyro noise floor, 0 .. 10
  bool invert_y = false;
  // Pointer area: the bottom half of the frame (DS stacked screens) or all
  // of it (PSP, side-by-side DS).
  bool pointer_bottom = true;

  PadProfile() {
    for (int i = 0; i < 16; i++) map[i] = int8_t(i);
  }
  bool identity() const;
};

// The pad's mask with its 16 RetroPad bits remapped (two sources may share
// a target); bits above 15 (kMenuGuideBit) pass through.
uint32_t remap_buttons(uint32_t mask, const PadProfile &p);

// Profiles by controller GUID (SDL_GUIDToString), "*" for every other pad.
class PadProfiles {
 public:
  // Parses dena_desktop_set_profiles text: one line per controller,
  //   <guid|*> map=<16 ints> gyro=<mode> sens=<x100> dz=<x100> inv=<0|1> area=<0|1>
  // Keys may be left out (defaults). Bad lines are skipped; returns how
  // many were taken.
  int parse(const std::string &text);
  const PadProfile &for_guid(const std::string &guid) const;
  size_t size() const { return by_guid_.size(); }

 private:
  std::map<std::string, PadProfile> by_guid_;
  PadProfile default_;
};

// Whether player 1 aims with the gyro pointer: the pad on port 0 in
// pads_info (SdlInput::pads_info lines: port, GUID, gyro 0/1, name) has a
// gyro and its profile in profiles_text puts it on the pointer. The Wii
// Remote then reads the pointer instead of the right stick
// (gamecube-wii.md, Wii Remote).
bool player1_gyro_pointer(const std::string &profiles_text, const std::string &pads_info);

// A gyro rate with the dead zone taken off softly: 0 inside it, and the
// rest scaled from 0 so motion just past it stays fine.
float gyro_after_deadzone(float dps, float deadzone_dps);

// Gyro rates (degrees a second, SDL's axes: pitch = rotation about X, yaw =
// about Y) to a stick, -32767..32767 with +y down: turning left pushes left,
// tilting the top up pushes up (unless invert_y).
void gyro_stick(float pitch_dps, float yaw_dps, const PadProfile &p, int *x, int *y);
// A physical stick axis plus the gyro's, clamped.
int mix_axis(int stick, int gyro);

// The gyro as the libretro pointer (-0x7fff..0x7fff over the frame): turns
// move it, it stops at the area's edges (turn back to bring it in).
struct GyroPointer {
  int x = 0, y = 0;
  float fx = 0.0f, fy = 0.0f;  // unrounded, so slow turns add up
  // Centre of the area.
  void reset(bool bottom);
  void step(float pitch_dps, float yaw_dps, float dt_s, const PadProfile &p);
};

}  // namespace dena

#endif
