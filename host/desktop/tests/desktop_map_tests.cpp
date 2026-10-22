// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/desktop-shell.md
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#include "dena/desktop.h"
#include "dena/std_codec.h"
#include "desktop_map.h"

static int g_failed = 0;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      g_failed++;                                                 \
    }                                                             \
  } while (0)

using namespace dena;

static void test_pad_buttons() {
  CHECK(pad_button_bit(kSdlSouth) == 0);   // B
  CHECK(pad_button_bit(kSdlEast) == 8);    // A
  CHECK(pad_button_bit(kSdlWest) == 1);    // Y
  CHECK(pad_button_bit(kSdlNorth) == 9);   // X
  CHECK(pad_button_bit(kSdlBack) == 2);    // Select
  CHECK(pad_button_bit(kSdlStart) == 3);
  CHECK(pad_button_bit(kSdlDpadUp) == 4);
  CHECK(pad_button_bit(kSdlDpadRight) == 7);
  CHECK(pad_button_bit(kSdlLeftShoulder) == 10);
  CHECK(pad_button_bit(kSdlRightStick) == 15);
  CHECK(pad_button_bit(kSdlGuide) == -1);  // the menu, not a RetroPad button
  CHECK(pad_button_bit(99) == -1);
}

static void test_keys() {
  CHECK(key_bit('X') == 8);
  CHECK(key_bit('Z') == 0);
  CHECK(key_bit(DENA_DESKTOP_KEY_ENTER) == 3);
  CHECK(key_bit(DENA_DESKTOP_KEY_RSHIFT) == 2);
  CHECK(key_bit(DENA_DESKTOP_KEY_LEFT) == 6);
  CHECK(key_bit('P') == -1);
  CHECK(key_action(DENA_DESKTOP_KEY_ESCAPE) == kKeyMenu);
  CHECK(key_action('Q') == 10);
  CHECK(key_action('R') == kKeyRewind && key_bit('R') == -1);
}

static void test_menu_combo() {
  CHECK(is_menu_combo(kMenuGuideBit));
  CHECK(is_menu_combo((1u << 2) | (1u << 3)));
  CHECK(is_menu_combo((1u << 2) | (1u << 3) | (1u << 8)));
  CHECK(!is_menu_combo(1u << 3));
  CHECK(!is_menu_combo(0));
}

static void test_ports() {
  PortTable t;
  CHECK(t.connect(10, "Xbox") == 0);
  CHECK(t.connect(11, "DualSense") == 1);
  CHECK(t.connect(10, "Xbox") == 0);  // already connected
  CHECK(t.connect(12, "8BitDo") == 2);
  CHECK(t.connect(13, "Switch Pro") == 3);
  // Eight ports on desktop (gamepads.md, Desktop: eight players).
  for (uint32_t id = 20; id < 24; id++) CHECK(t.connect(id, "Pad") == int(id - 16));
  CHECK(t.connect(14, "Ninth") == -1);  // waits
  CHECK(t.count() == 9);
  std::vector<std::string> n = t.names();
  CHECK(n.size() == 8 && n[0] == "Xbox" && n[3] == "Switch Pro" && n[7] == "Pad");
  CHECK(t.disconnect(11) == 1);
  CHECK(t.port_of(14) == 1);  // the waiting pad took the free port
  CHECK(t.names()[1] == "Ninth");
  CHECK(t.disconnect(10) == 0);
  CHECK(t.names()[0].empty());
  CHECK(t.connect(15, "New") == 0);  // lowest free port
  CHECK(t.disconnect(99) == -1);
}

static void test_core_names() {
  CHECK(desktop_core_file("libmgba_libretro.so", true) == "mgba_libretro.dll");
  CHECK(desktop_core_file("libmgba_libretro.so", false) == "mgba_libretro.so");
  CHECK(desktop_core_file("mupen64plus_libretro", true) == "mupen64plus_libretro.dll");
  CHECK(desktop_core_file("libpcsx_rearmed_libretro.so", true) == "mednafen_psx_hw_libretro.dll");
  std::vector<std::string> c = core_candidates("libfceumm_libretro.so", "/data", "/app/lib", false);
  CHECK(c.size() == 2 && c[0] == "/data/cores/fceumm_libretro.so" &&
        c[1] == "/app/lib/cores/fceumm_libretro.so");
  CHECK(core_candidates("libx.so", "", "/lib", true).size() == 1);
}

static std::string slurp(const std::filesystem::path &p) {
  std::ifstream f(p);
  return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

static void test_core_assets() {
  namespace fs = std::filesystem;
  const fs::path tmp = fs::temp_directory_path() / "dena_core_assets_test";
  fs::remove_all(tmp);
  const fs::path lib = tmp / "lib", sys = tmp / "Bios";
  fs::create_directories(lib / "cores" / "PPSSPP" / "flash0" / "font");
  std::ofstream(lib / "cores" / "PPSSPP" / "dena-assets.txt") << "v1";
  std::ofstream(lib / "cores" / "PPSSPP" / "flash0" / "font" / "a.pgf") << "font";
  const std::string core = (lib / "cores" / "ppsspp_libretro.dll").u8string();
  // Other cores copy nothing.
  CHECK(install_core_assets((lib / "cores" / "mgba_libretro.dll").u8string(), lib.u8string(),
                            sys.u8string()));
  CHECK(!fs::exists(sys / "PPSSPP"));
  CHECK(install_core_assets(core, lib.u8string(), sys.u8string()));
  CHECK(slurp(sys / "PPSSPP" / "flash0" / "font" / "a.pgf") == "font");
  CHECK(slurp(sys / "PPSSPP" / "dena-assets.txt") == "v1");
  // Same stamp: left alone (a user's own fonts stay).
  std::ofstream(sys / "PPSSPP" / "mine.pgf") << "x";
  CHECK(install_core_assets(core, lib.u8string(), sys.u8string()));
  CHECK(fs::exists(sys / "PPSSPP" / "mine.pgf"));
  // New stamp: replaced.
  std::ofstream(lib / "cores" / "PPSSPP" / "dena-assets.txt") << "v2";
  CHECK(install_core_assets(core, lib.u8string(), sys.u8string()));
  CHECK(slurp(sys / "PPSSPP" / "dena-assets.txt") == "v2");
  CHECK(!fs::exists(sys / "PPSSPP" / "mine.pgf"));
  // Dolphin's Sys folder (gamecube-wii.md, Core).
  fs::create_directories(lib / "cores" / "dolphin-emu" / "Sys" / "GameSettings");
  std::ofstream(lib / "cores" / "dolphin-emu" / "dena-assets.txt") << "d1";
  std::ofstream(lib / "cores" / "dolphin-emu" / "Sys" / "GameSettings" / "GALE01.ini") << "ini";
  CHECK(install_core_assets((lib / "cores" / "dolphin_libretro.so").u8string(), lib.u8string(),
                            sys.u8string()));
  CHECK(slurp(sys / "dolphin-emu" / "Sys" / "GameSettings" / "GALE01.ini") == "ini");
  // Bytes that are not UTF-8 (an ANSI path on Windows) never throw.
  install_core_assets(core, "C:/Programs/D\xf1na", sys.u8string());
  fs::remove_all(tmp);
}

static void test_encoders() {
  std::vector<uint8_t> none = encode_no_args();
  CHECK(none.size() == 1 && none[0] == 0);  // a single null

  std::vector<uint8_t> m = encode_players_changed({"Xbox", "", "", ""});
  struct dena_val vals[16];
  struct dena_val_arena arena = {vals, 16, 0};
  struct dena_val root;
  CHECK(dena_decode(m.data(), m.size(), &arena, &root) == 0);
  const struct dena_val *names = dena_list_at(&root, 0);
  CHECK(names && dena_list_at(names, 0) && dena_val_string_eq(dena_list_at(names, 0), "Xbox"));
  CHECK(names && dena_list_at(names, 3) && dena_val_string_eq(dena_list_at(names, 3), ""));
}

static void test_latency_line() {
  CHECK(latency_line(5, "{\"frames\":3}") == "{\"t_ms\":5,\"frames\":3}");
  CHECK(latency_line(7, "{}") == "{\"t_ms\":7}");
  CHECK(latency_line(7, "") == "{\"t_ms\":7}");
}

static void test_ui_navigation() {
  CHECK(pad_family(3, 0x045e, 0x0b13) == kFamilyXbox);
  CHECK(pad_family(6, 0x054c, 0x0ce6) == kFamilyPlayStation);
  CHECK(pad_family(7, 0x057e, 0x2009) == kFamilyNintendo);
  CHECK(pad_family(2, 0x28de, 0x1205) == kFamilySteamDeck);
  CHECK(pad_family(1, 0x1234, 0x5678) == kFamilyGeneric);
  CHECK(south_is_confirm(1));   // A
  CHECK(south_is_confirm(5));   // Cross
  CHECK(!south_is_confirm(2));  // B: Nintendo layout
  // Xbox: the bottom button (RetroPad B) confirms in menus.
  CHECK(ui_buttons(1u << 0, true) == 1u << 8);
  CHECK(ui_buttons(1u << 8, true) == 1u << 0);
  CHECK(ui_buttons(1u << 1, true) == 1u << 9);
  CHECK(ui_buttons((1u << 4) | (1u << 3), true) == ((1u << 4) | (1u << 3)));
  CHECK(ui_buttons(1u << 0, false) == 1u << 0);
  // Stick: on past half, held until under a third.
  CHECK(ui_stick(0, 0, 0) == 0);
  CHECK(ui_stick(-20000, 0, 0) == 1u << 6);
  CHECK(ui_stick(-12000, 0, 0) == 0);
  CHECK(ui_stick(-12000, 0, 1u << 6) == 1u << 6);
  CHECK(ui_stick(-9000, 0, 1u << 6) == 0);
  CHECK(ui_stick(0, 30000, 0) == 1u << 5);
  CHECK(ui_stick(0, -30000, 0) == 1u << 4);
  std::vector<std::pair<int, bool>> seen;
  ui_changes(1u << 8, (1u << 4) | kMenuGuideBit,
             [&](int a, bool d) { seen.emplace_back(a, d); });
  CHECK(seen.size() == 3);
  CHECK(seen[0] == std::make_pair(4, true));
  CHECK(seen[1] == std::make_pair(8, false));
  CHECK(seen[2] == std::make_pair(kUiMenu, true));
}

static void test_chime() {
  std::vector<int16_t> buf(kChimeFrames * 2 + 200, 0);
  uint32_t pos = 0;
  mix_chime(buf.data(), 100, &pos);
  CHECK(pos == 100);
  CHECK(buf[0] == 0);  // starts from silence (attack, no click)
  mix_chime(buf.data() + 200, kChimeFrames, &pos);
  CHECK(pos == kChimeFrames);  // stops at the end, not past it
  int peak = 0;
  for (int16_t v : buf) peak = std::max(peak, std::abs(int(v)));
  CHECK(peak > 3000 && peak <= 7000);
  // Mixed into loud audio it clips instead of wrapping round.
  std::vector<int16_t> loud(400, 32000);
  pos = 300;
  mix_chime(loud.data(), 200, &pos);
  bool ok = true;
  for (int16_t v : loud) ok = ok && v >= 25000;
  CHECK(ok);
  // Finished: nothing more is added.
  std::vector<int16_t> quiet(20, 0);
  pos = kChimeFrames;
  mix_chime(quiet.data(), 10, &pos);
  CHECK(pos == kChimeFrames && quiet[0] == 0 && quiet[19] == 0);
}

int main() {
  test_chime();
  test_ui_navigation();
  test_pad_buttons();
  test_keys();
  test_menu_combo();
  test_ports();
  test_core_names();
  test_core_assets();
  test_encoders();
  test_latency_line();
  if (g_failed) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failed);
    return 1;
  }
  std::printf("desktop_map: ok\n");
  return 0;
}
