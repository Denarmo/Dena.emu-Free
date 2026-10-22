// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md
#include "desktop_map.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "dena/desktop.h"
#include "dena/std_codec.h"

namespace dena {

namespace {

// RETRO_DEVICE_ID_JOYPAD_* (libretro.h).
enum : int {
  kB = 0, kY = 1, kSelect = 2, kStart = 3, kUp = 4, kDown = 5, kLeft = 6,
  kRight = 7, kA = 8, kX = 9, kL = 10, kR = 11, kL3 = 14, kR3 = 15,
};

template <typename Fn>
std::vector<uint8_t> encode(Fn fn) {
  std::vector<uint8_t> out(64);
  for (;;) {
    struct dena_buf b = {out.data(), 0, out.size(), false};
    fn(&b);
    if (!b.failed) {
      out.resize(b.len);
      return out;
    }
    out.resize(out.size() * 2);
  }
}

}  // namespace

int pad_button_bit(int sdl_button) {
  switch (sdl_button) {
    case kSdlSouth: return kB;
    case kSdlEast: return kA;
    case kSdlWest: return kY;
    case kSdlNorth: return kX;
    case kSdlBack: return kSelect;
    case kSdlStart: return kStart;
    case kSdlLeftStick: return kL3;
    case kSdlRightStick: return kR3;
    case kSdlLeftShoulder: return kL;
    case kSdlRightShoulder: return kR;
    case kSdlDpadUp: return kUp;
    case kSdlDpadDown: return kDown;
    case kSdlDpadLeft: return kLeft;
    case kSdlDpadRight: return kRight;
    default: return -1;
  }
}

// RetroArch's long-standing keyboard defaults, so players coming from it
// find the same keys: arrows, X = A, Z = B, S = X, A = Y, Q/W = L/R,
// Enter = Start, right Shift or Backspace = Select.
int key_bit(int key) {
  switch (key) {
    case DENA_DESKTOP_KEY_UP: return kUp;
    case DENA_DESKTOP_KEY_DOWN: return kDown;
    case DENA_DESKTOP_KEY_LEFT: return kLeft;
    case DENA_DESKTOP_KEY_RIGHT: return kRight;
    case 'X': return kA;
    case 'Z': return kB;
    case 'S': return kX;
    case 'A': return kY;
    case 'Q': return kL;
    case 'W': return kR;
    case DENA_DESKTOP_KEY_ENTER: return kStart;
    case DENA_DESKTOP_KEY_RSHIFT:
    case DENA_DESKTOP_KEY_BACKSPACE: return kSelect;
    default: return -1;
  }
}

int key_action(int key) {
  if (key == DENA_DESKTOP_KEY_ESCAPE) return kKeyMenu;
  if (key == 'R') return kKeyRewind;
  return key_bit(key);
}

bool wants_multitap(const std::vector<std::string> &names) {
  int used = 0;
  for (const std::string &n : names)
    if (!n.empty()) used++;
  return used > 2;
}

bool is_menu_combo(uint32_t mask) {
  const uint32_t start_select = (1u << kStart) | (1u << kSelect);
  return (mask & kMenuGuideBit) != 0 || (mask & start_select) == start_select;
}

int pad_family(int sdl_type, uint16_t vendor, uint16_t product) {
  if (vendor == 0x28de && product == 0x1205) return kFamilySteamDeck;
  // SDL_GamepadType: 2 XBOX360, 3 XBOXONE, 4 PS3, 5 PS4, 6 PS5,
  // 7 NINTENDO_SWITCH_PRO, 8-10 Joy-Cons.
  switch (sdl_type) {
    case 2:
    case 3: return kFamilyXbox;
    case 4:
    case 5:
    case 6: return kFamilyPlayStation;
    case 7:
    case 8:
    case 9:
    case 10: return kFamilyNintendo;
    default: return kFamilyGeneric;
  }
}

bool south_is_confirm(int sdl_south_label) {
  // SDL_GamepadButtonLabel: 1 A, 2 B, 5 CROSS. Unknown labels: the Xbox
  // layout, the common case for generic pads.
  return sdl_south_label != 2;
}

uint32_t ui_buttons(uint32_t mask, bool south_confirms) {
  if (!south_confirms) return mask;
  auto swap = [&mask](int a, int b) {
    const bool ba = (mask >> a) & 1u, bb = (mask >> b) & 1u;
    mask &= ~((1u << a) | (1u << b));
    mask |= (uint32_t(ba) << b) | (uint32_t(bb) << a);
  };
  swap(kA, kB);
  swap(kX, kY);
  return mask;
}

uint32_t ui_stick(int lx, int ly, uint32_t prev) {
  constexpr int kOn = 16384, kOff = 10923;  // half and a third of 32767
  auto axis = [prev](int v, int neg_bit, int pos_bit) {
    uint32_t out = 0;
    const bool had_neg = (prev >> neg_bit) & 1u, had_pos = (prev >> pos_bit) & 1u;
    if (v <= -kOn || (had_neg && v <= -kOff)) out |= 1u << neg_bit;
    if (v >= kOn || (had_pos && v >= kOff)) out |= 1u << pos_bit;
    return out;
  };
  return axis(lx, kLeft, kRight) | axis(ly, kUp, kDown);  // SDL: +y is down
}

int PortTable::connect(uint32_t id, const std::string &name) {
  if (int p = port_of(id); p >= 0) return p;
  bool used[kDesktopPorts] = {};
  for (const Device &d : devices_)
    if (d.port >= 0) used[d.port] = true;
  int port = -1;
  for (int i = 0; i < kDesktopPorts && port < 0; i++)
    if (!used[i]) port = i;
  devices_.push_back({id, name, port});
  return port;
}

int PortTable::disconnect(uint32_t id) {
  auto it = std::find_if(devices_.begin(), devices_.end(), [id](const Device &d) { return d.id == id; });
  if (it == devices_.end()) return -1;
  const int port = it->port;
  devices_.erase(it);
  if (port >= 0) {
    for (Device &d : devices_)
      if (d.port < 0) {
        d.port = port;  // the longest-waiting controller moves in
        break;
      }
  }
  return port;
}

int PortTable::port_of(uint32_t id) const {
  for (const Device &d : devices_)
    if (d.id == id) return d.port;
  return -1;
}

std::vector<std::string> PortTable::names() const {
  std::vector<std::string> out(kDesktopPorts);
  for (const Device &d : devices_)
    if (d.port >= 0) out[size_t(d.port)] = d.name;
  return out;
}

std::string desktop_core_file(const std::string &android_name, bool windows) {
  std::string base = android_name;
  if (base.compare(0, 3, "lib") == 0) base = base.substr(3);
  const std::string so = ".so";
  if (base.size() > so.size() && base.compare(base.size() - so.size(), so.size(), so) == 0)
    base.resize(base.size() - so.size());
  // PCSX ReARMed is ARM only; x86_64 builds ship Beetle PSX HW for PS1
  // (docs/dev/desktop-cores.md).
  if (base == "pcsx_rearmed_libretro") base = "mednafen_psx_hw_libretro";
  return base + (windows ? ".dll" : ".so");
}

std::vector<std::string> core_candidates(const std::string &android_name, const std::string &root,
                                         const std::string &lib_dir, bool windows) {
  const std::string file = desktop_core_file(android_name, windows);
  std::vector<std::string> out;
  if (!root.empty()) out.push_back(root + "/cores/" + file);
  if (!lib_dir.empty()) out.push_back(lib_dir + "/cores/" + file);
  return out;
}

namespace {

std::string read_file(const std::filesystem::path &p) {
  std::ifstream f(p, std::ios::binary);
  if (!f) return {};
  std::ostringstream out;
  out << f.rdbuf();
  return out.str();
}

bool install_core_assets_or_throw(const std::string &core_path, const std::string &lib_dir,
                                  const std::string &sysdir) {
  namespace fs = std::filesystem;
  static const char *const kStamp = "dena-assets.txt";
  // Core file name -> its folder under the system directory.
  const std::string file = fs::u8path(core_path).filename().u8string();
  // Dolphin reads <sysdir>/dolphin-emu/Sys (gamecube-wii.md, Core).
  const char *folder = file.rfind("ppsspp_libretro", 0) == 0    ? "PPSSPP"
                       : file.rfind("dolphin_libretro", 0) == 0 ? "dolphin-emu"
                                                                 : nullptr;
  if (!folder || lib_dir.empty() || sysdir.empty()) return true;
  const fs::path src = fs::u8path(lib_dir) / "cores" / folder;
  const std::string version = read_file(src / kStamp);
  if (version.empty()) return true;  // not packaged in this build
  const fs::path dest = fs::u8path(sysdir) / folder;
  if (read_file(dest / kStamp) == version) return true;
  std::error_code ec;
  fs::remove_all(dest, ec);  // drop files a newer version removed
  fs::create_directories(dest, ec);
  fs::copy(src, dest, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
  if (ec) {
    std::fprintf(stderr, "dena: cannot copy %s support files: %s\n", folder, ec.message().c_str());
    return false;
  }
  return true;  // the stamp came along with the copy
}

}  // namespace

bool install_core_assets(const std::string &core_path, const std::string &lib_dir,
                         const std::string &sysdir) {
  // Runs under the C API (a Pigeon message), so nothing may throw out of it:
  // fs::u8path throws on bytes that are not UTF-8, which a Windows process
  // without the UTF-8 code page (the app's manifest sets it) can pass.
  try {
    return install_core_assets_or_throw(core_path, lib_dir, sysdir);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "dena: core support files skipped: %s\n", e.what());
    return false;
  }
}

std::vector<uint8_t> encode_no_args() {
  // Pigeon sends a single null for a no-argument FlutterApi call.
  return encode([](struct dena_buf *b) { dena_put_null(b); });
}

std::vector<uint8_t> encode_players_changed(const std::vector<std::string> &names) {
  return encode([&](struct dena_buf *b) {
    dena_put_list_start(b, 1);
    dena_put_list_start(b, names.size());
    for (const std::string &n : names) dena_put_string(b, n.c_str());
  });
}

std::string latency_line(int64_t unix_ms, const std::string &metrics_json) {
  char head[48];
  std::snprintf(head, sizeof head, "{\"t_ms\":%lld", static_cast<long long>(unix_ms));
  std::string body = metrics_json;
  if (!body.empty() && body.front() == '{') body.erase(0, 1);
  if (body.empty() || body == "}") return std::string(head) + "}";
  return std::string(head) + "," + body;
}

void mix_chime(int16_t *stereo, uint32_t frames, uint32_t *pos) {
  constexpr double kRate = 48000, kPi = 3.14159265358979323846;
  constexpr uint32_t kNote = kChimeFrames / 2;
  for (uint32_t i = 0; i < frames && *pos < kChimeFrames; i++, (*pos)++) {
    const uint32_t n = *pos % kNote;  // frame within the note
    const double hz = *pos < kNote ? 1318.5 : 1975.5;  // E6, then B6
    // 2 ms attack against clicks, then an exponential fade.
    const double env = std::min(1.0, n / 96.0) * std::exp(-double(n) / 2400.0);
    const int v = int(std::sin(2 * kPi * hz * n / kRate) * env * 7000.0);
    for (int c = 0; c < 2; c++) {
      const int m = stereo[i * 2 + c] + v;
      stereo[i * 2 + c] = int16_t(std::clamp(m, -32768, 32767));
    }
  }
}

}  // namespace dena
