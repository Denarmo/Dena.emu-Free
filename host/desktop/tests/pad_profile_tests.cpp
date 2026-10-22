// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro, eight players)
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "desktop_map.h"
#include "pad_profile.h"

static int g_failed = 0;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      g_failed++;                                                 \
    }                                                             \
  } while (0)

using namespace dena;

static constexpr uint32_t bit(int b) { return 1u << b; }

static void test_remap() {
  PadProfile p;
  CHECK(p.identity());
  CHECK(remap_buttons(0xffffu | kMenuGuideBit, p) == (0xffffu | kMenuGuideBit));
  // Swap A (8) and B (0); unbind Select (2).
  p.map[0] = 8;
  p.map[8] = 0;
  p.map[2] = -1;
  CHECK(!p.identity());
  CHECK(remap_buttons(bit(0), p) == bit(8));
  CHECK(remap_buttons(bit(8) | bit(3), p) == (bit(0) | bit(3)));
  CHECK(remap_buttons(bit(2), p) == 0);
  CHECK(remap_buttons(kMenuGuideBit, p) == kMenuGuideBit);  // passes through
  // Two sources on one target.
  p.map[1] = 8;
  CHECK(remap_buttons(bit(1), p) == bit(8));
  CHECK(remap_buttons(bit(0) | bit(1), p) == bit(8));
}

static void test_parse() {
  PadProfiles set;
  const std::string text =
      "# profiles\n"
      "030000005e040000e002000000000000 map=8,1,2,3,4,5,6,7,0,9,10,11,12,13,14,15 gyro=0\n"
      "* gyro=1 sens=150 dz=200 inv=1\r\n"
      "0300000028de00000512000000000000 gyro=3 area=0 newkey=7\n"
      "bad map=1,2,3\n"         // too few entries
      "bad2 gyro=9\n"           // no such mode
      "bad3 sens=0\n"           // out of range
      "bad4 junk\n"             // not key=value
      "\n";
  CHECK(set.parse(text) == 3);
  CHECK(set.size() == 2);
  const PadProfile &xbox = set.for_guid("030000005e040000e002000000000000");
  CHECK(xbox.map[0] == 8 && xbox.map[8] == 0 && xbox.gyro == kGyroOff);
  const PadProfile &deck = set.for_guid("0300000028de00000512000000000000");
  CHECK(deck.gyro == kGyroPointer && !deck.pointer_bottom && deck.identity());
  // Any other pad: the "*" line.
  const PadProfile &other = set.for_guid("ffff");
  CHECK(other.gyro == kGyroLeftStick && other.sensitivity == 1.5f &&
        other.deadzone_dps == 2.0f && other.invert_y);
  CHECK(set.for_guid("bad").identity());  // skipped lines don't count
  // A new set replaces the old one.
  CHECK(set.parse("") == 0);
  CHECK(set.size() == 0 && set.for_guid("ffff").gyro == kGyroOff);
}

static void test_deadzone() {
  CHECK(gyro_after_deadzone(1.0f, 1.5f) == 0.0f);
  CHECK(gyro_after_deadzone(-1.5f, 1.5f) == 0.0f);
  CHECK(gyro_after_deadzone(3.5f, 1.5f) == 2.0f);
  CHECK(gyro_after_deadzone(-3.5f, 1.5f) == -2.0f);
  CHECK(gyro_after_deadzone(0.2f, 0.0f) == 0.2f);
}

static void test_gyro_stick() {
  PadProfile p;
  p.gyro = kGyroLeftStick;
  p.deadzone_dps = 0.0f;
  int x = 1, y = 1;
  gyro_stick(0, 0, p, &x, &y);
  CHECK(x == 0 && y == 0);
  // Turning left (positive yaw) pushes left; full tilt at 120 deg/s.
  gyro_stick(0, kGyroStickFullDps, p, &x, &y);
  CHECK(x == -32767 && y == 0);
  gyro_stick(0, -kGyroStickFullDps / 2, p, &x, &y);
  CHECK(x > 16000 && x < 16800);
  // Tilting the top up (positive pitch) pushes up (-y); invert flips it.
  gyro_stick(60.0f, 0, p, &x, &y);
  CHECK(y < -16000);
  p.invert_y = true;
  gyro_stick(60.0f, 0, p, &x, &y);
  CHECK(y > 16000);
  // Sensitivity 2 reaches full tilt at half the speed; clamped past it.
  p.sensitivity = 2.0f;
  gyro_stick(0, kGyroStickFullDps, p, &x, &y);
  CHECK(x == -32767);
  // Noise inside the dead zone stays still.
  p.deadzone_dps = 1.5f;
  gyro_stick(1.2f, -1.4f, p, &x, &y);
  CHECK(x == 0 && y == 0);
  CHECK(mix_axis(30000, 10000) == 32767);
  CHECK(mix_axis(-30000, -10000) == -32767);
  CHECK(mix_axis(1000, -400) == 600);
}

static void test_gyro_pointer() {
  PadProfile p;
  p.gyro = kGyroPointer;
  p.deadzone_dps = 0.0f;
  GyroPointer ptr;
  ptr.reset(true);
  CHECK(ptr.x == 0 && ptr.y == 0x3fff);  // middle of the bottom screen
  // A 30 degree turn to the right (negative yaw) at sensitivity 1 moves
  // half the width, in 1 ms steps.
  for (int i = 0; i < 1000; i++) ptr.step(0, -30.0f, 0.001f, p);
  CHECK(ptr.x > 0x7fff - 40);
  // Further right stops at the edge.
  for (int i = 0; i < 100; i++) ptr.step(0, -90.0f, 0.001f, p);
  CHECK(ptr.x == 0x7fff);
  // Slow turns still add up (0.2 deg/s over 5 s = 1 degree, ~1092 units).
  const int before = ptr.x;
  for (int i = 0; i < 5000; i++) ptr.step(0, 0.2f, 0.001f, p);
  CHECK(before - ptr.x > 1000 && before - ptr.x < 1200);
  // The bottom area stops at the screens' seam; the whole frame doesn't.
  for (int i = 0; i < 1000; i++) ptr.step(90.0f, 0, 0.001f, p);
  CHECK(ptr.y == 0);
  p.pointer_bottom = false;
  for (int i = 0; i < 1000; i++) ptr.step(90.0f, 0, 0.001f, p);
  CHECK(ptr.y == -0x7fff);
  // A first sample (dt 0) or a stall (dt > 0.25 s) doesn't jump.
  ptr.reset(false);
  ptr.step(0, 500.0f, 0.0f, p);
  ptr.step(0, 500.0f, 2.0f, p);
  CHECK(ptr.x == 0 && ptr.y == 0);
}

static void test_multitap() {
  CHECK(!wants_multitap({"Xbox", "DualSense", "", "", "", "", "", ""}));
  CHECK(wants_multitap({"Xbox", "", "Pad", "Pad", "", "", "", ""}));
  CHECK(!wants_multitap({}));
}

// gamecube-wii.md, Wii Remote: player 1's gyro pointer aims it.
static void test_player1_gyro_pointer() {
  const std::string pads = "1\tbbbb\t1\tDualSense\n0\taaaa\t1\tSwitch Pro\n";
  CHECK(player1_gyro_pointer("aaaa gyro=3\n", pads));
  CHECK(player1_gyro_pointer("* gyro=3\n", pads));
  // Another player's pointer, a stick mode, no profile: the right stick.
  CHECK(!player1_gyro_pointer("bbbb gyro=3\n", pads));
  CHECK(!player1_gyro_pointer("aaaa gyro=2\n", pads));
  CHECK(!player1_gyro_pointer("", pads));
  // Player 1's pad has no gyro, or nobody is player 1.
  CHECK(!player1_gyro_pointer("* gyro=3\n", "0\taaaa\t0\tXbox\n"));
  CHECK(!player1_gyro_pointer("* gyro=3\n", "-1\taaaa\t1\tDualSense\n"));
  CHECK(!player1_gyro_pointer("* gyro=3\n", ""));
}

int main() {
  test_remap();
  test_parse();
  test_deadzone();
  test_gyro_stick();
  test_gyro_pointer();
  test_multitap();
  test_player1_gyro_pointer();
  if (g_failed) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failed);
    return EXIT_FAILURE;
  }
  std::printf("pad_profile_tests: all passed\n");
  return EXIT_SUCCESS;
}
