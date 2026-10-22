// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro)
#include "pad_profile.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <sstream>

namespace dena {

bool PadProfile::identity() const {
  for (int i = 0; i < 16; i++)
    if (map[i] != i) return false;
  return true;
}

uint32_t remap_buttons(uint32_t mask, const PadProfile &p) {
  uint32_t out = mask & ~0xffffu;
  for (int i = 0; i < 16; i++)
    if ((mask & (1u << i)) && p.map[i] >= 0 && p.map[i] < 16) out |= 1u << p.map[i];
  return out;
}

namespace {

bool parse_int(const std::string &s, long lo, long hi, long *out) {
  if (s.empty()) return false;
  char *end = nullptr;
  const long v = std::strtol(s.c_str(), &end, 10);
  if (*end != '\0' || v < lo || v > hi) return false;
  *out = v;
  return true;
}

bool parse_line(const std::string &line, std::string *guid, PadProfile *p) {
  std::istringstream in(line);
  if (!(in >> *guid)) return false;
  std::string field;
  while (in >> field) {
    const size_t eq = field.find('=');
    if (eq == std::string::npos) return false;
    const std::string key = field.substr(0, eq), value = field.substr(eq + 1);
    long v = 0;
    if (key == "map") {
      std::istringstream items(value);
      std::string item;
      int i = 0;
      while (std::getline(items, item, ',')) {
        if (i >= 16 || !parse_int(item, -1, 15, &v)) return false;
        p->map[i++] = int8_t(v);
      }
      if (i != 16) return false;
    } else if (key == "gyro") {
      if (!parse_int(value, kGyroOff, kGyroPointer, &v)) return false;
      p->gyro = int(v);
    } else if (key == "sens") {
      if (!parse_int(value, 10, 500, &v)) return false;
      p->sensitivity = float(v) / 100.0f;
    } else if (key == "dz") {
      if (!parse_int(value, 0, 1000, &v)) return false;
      p->deadzone_dps = float(v) / 100.0f;
    } else if (key == "inv") {
      if (!parse_int(value, 0, 1, &v)) return false;
      p->invert_y = v != 0;
    } else if (key == "area") {
      if (!parse_int(value, 0, 1, &v)) return false;
      p->pointer_bottom = v != 0;
    }
    // Unknown keys are left for newer Dart code.
  }
  return true;
}

}  // namespace

int PadProfiles::parse(const std::string &text) {
  by_guid_.clear();
  default_ = PadProfile();
  std::istringstream in(text);
  std::string line;
  int taken = 0;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.find_first_not_of(" \t") == std::string::npos || line[0] == '#') continue;
    std::string guid;
    PadProfile p;
    if (!parse_line(line, &guid, &p)) continue;
    if (guid == "*")
      default_ = p;
    else
      by_guid_[guid] = p;
    taken++;
  }
  return taken;
}

const PadProfile &PadProfiles::for_guid(const std::string &guid) const {
  auto it = by_guid_.find(guid);
  return it == by_guid_.end() ? default_ : it->second;
}

bool player1_gyro_pointer(const std::string &profiles_text, const std::string &pads_info) {
  std::istringstream in(pads_info);
  std::string line;
  while (std::getline(in, line)) {
    std::istringstream cols(line);
    std::string port, guid, gyro;
    if (!std::getline(cols, port, '\t') || !std::getline(cols, guid, '\t') ||
        !std::getline(cols, gyro, '\t'))
      continue;
    if (port != "0") continue;
    if (gyro != "1") return false;
    PadProfiles profiles;
    profiles.parse(profiles_text);
    return profiles.for_guid(guid).gyro == kGyroPointer;
  }
  return false;
}

float gyro_after_deadzone(float dps, float deadzone_dps) {
  const float mag = std::fabs(dps);
  if (mag <= deadzone_dps) return 0.0f;
  return std::copysign(mag - deadzone_dps, dps);
}

void gyro_stick(float pitch_dps, float yaw_dps, const PadProfile &p, int *x, int *y) {
  const float scale = 32767.0f * p.sensitivity / kGyroStickFullDps;
  const float fx = -gyro_after_deadzone(yaw_dps, p.deadzone_dps) * scale;
  float fy = -gyro_after_deadzone(pitch_dps, p.deadzone_dps) * scale;
  if (p.invert_y) fy = -fy;
  *x = int(std::lround(std::clamp(fx, -32767.0f, 32767.0f)));
  *y = int(std::lround(std::clamp(fy, -32767.0f, 32767.0f)));
}

int mix_axis(int stick, int gyro) { return std::clamp(stick + gyro, -32767, 32767); }

void GyroPointer::reset(bool bottom) {
  fx = 0.0f;
  fy = bottom ? float(0x3fff) : 0.0f;
  x = 0;
  y = int(fy);
}

void GyroPointer::step(float pitch_dps, float yaw_dps, float dt_s, const PadProfile &p) {
  if (dt_s <= 0.0f || dt_s > 0.25f) return;  // first sample or a stall
  // Full width (2 * 0x7fff) per kGyroPointerSweepDeg at sensitivity 1.
  const float per_deg = 2.0f * 0x7fff * p.sensitivity / kGyroPointerSweepDeg;
  const float dx = -gyro_after_deadzone(yaw_dps, p.deadzone_dps) * dt_s * per_deg;
  float dy = -gyro_after_deadzone(pitch_dps, p.deadzone_dps) * dt_s * per_deg;
  if (p.invert_y) dy = -dy;
  fx = std::clamp(fx + dx, -float(0x7fff), float(0x7fff));
  fy = std::clamp(fy + dy, p.pointer_bottom ? 0.0f : -float(0x7fff), float(0x7fff));
  x = int(std::lround(fx));
  y = int(std::lround(fy));
}

}  // namespace dena
