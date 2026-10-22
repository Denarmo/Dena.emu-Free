/* Input router: doubled and orphan events, hats, resync after dropped
 * events, unplugging, D-pad repeat. Fake input nodes: events are fed as the
 * kernel would deliver them. Spec: docs/specs/handheld-input.md
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdio.h>
#include <string.h>

#include "dena/input.h"

static int failures;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      failures++;                                                        \
    }                                                                    \
  } while (0)

enum { B = 0, SELECT = 2, START = 3, UP = 4, DOWN = 5, LEFT = 6, RIGHT = 7, A = 8 };
// Linux codes (linux/input-event-codes.h).
enum {
  BTN_SOUTH = 304, BTN_EAST = 305, BTN_SELECT = 314, BTN_START = 315,
  BTN_DPAD_UP = 544, BTN_DPAD_DOWN = 545, KEY_VOLUMEDOWN = 114, KEY_VOLUMEUP = 115,
  KEY_POWER = 116, KEY_Q = 16, HAT0X = 0, HAT0Y = 1,
};
#define MS 1000ull

static struct dena_profile profile;
static struct dena_input_event ev[64];

static bool is(int i, int action, enum dena_input_kind kind) {
  return ev[i].action == action && ev[i].kind == kind;
}

static void load_h700(struct dena_input *in) {
  struct dena_profile list[8];
  int n = dena_builtin_profiles(list, 8);
  static const char compat[] = "anbernic,rg35xx-sp\0allwinner,sun50i-h700";
  const struct dena_profile *p = dena_profile_pick(list, n, compat, sizeof compat);
  CHECK(p && strcmp(p->id, "h700") == 0);
  if (p) profile = *p;
  dena_input_init(in, &profile, NULL);
}

static void press_release(void) {
  struct dena_input in;
  load_h700(&in);
  CHECK(dena_input_key(&in, 0, BTN_EAST, 1, 10 * MS, ev) == 1 && is(0, A, DENA_INPUT_DOWN));
  CHECK(ev[0].usec == 10 * MS);
  CHECK(dena_input_held(&in, A));
  // A second down with no up (bounce, or a resent event): dropped.
  CHECK(dena_input_key(&in, 0, BTN_EAST, 1, 11 * MS, ev) == 0);
  // Kernel auto-repeat of a face button: dropped.
  CHECK(dena_input_key(&in, 0, BTN_EAST, 2, 12 * MS, ev) == 0);
  CHECK(dena_input_key(&in, 0, BTN_EAST, 0, 20 * MS, ev) == 1 && is(0, A, DENA_INPUT_UP));
  CHECK(!dena_input_held(&in, A));
  // A release with no press: dropped.
  CHECK(dena_input_key(&in, 0, BTN_EAST, 0, 21 * MS, ev) == 0);
  // Unmapped keys: nothing.
  CHECK(dena_input_key(&in, 0, KEY_Q, 1, 22 * MS, ev) == 0);
  CHECK(dena_input_key(&in, 0, KEY_Q, 0, 23 * MS, ev) == 0);
  // Bad node numbers and codes are ignored.
  CHECK(dena_input_key(&in, -1, BTN_EAST, 1, 0, ev) == 0);
  CHECK(dena_input_key(&in, DENA_INPUT_DEVICES, BTN_EAST, 1, 0, ev) == 0);
  CHECK(dena_input_key(&in, 0, 0, 1, 0, ev) == 0);
}

static void h700_buttons(void) {
  // Every SP button the mainline device tree reports, through the profile.
  struct dena_input in;
  load_h700(&in);
  static const struct { int code, action; } map[] = {
      {304, 0},  {305, 8},  {307, 9},  {308, 1},  {310, 10}, {311, 11}, {312, 12},
      {313, 13}, {314, 2},  {315, 3},  {316, DENA_KEY_MENU},   {544, 4}, {545, 5},
      {546, 6},  {547, 7},  {115, DENA_KEY_VOLUME_UP}, {114, DENA_KEY_VOLUME_DOWN},
      {116, DENA_KEY_POWER},
  };
  for (size_t i = 0; i < sizeof map / sizeof *map; i++) {
    CHECK(dena_input_key(&in, 1, map[i].code, 1, 0, ev) == 1 && is(0, map[i].action, DENA_INPUT_DOWN));
    CHECK(dena_input_key(&in, 1, map[i].code, 0, 0, ev) == 1 && is(0, map[i].action, DENA_INPUT_UP));
  }
}

static void two_nodes(void) {
  struct dena_input in;
  load_h700(&in);
  // B on the built-in pad and on a USB pad: one press, one release.
  CHECK(dena_input_key(&in, 0, BTN_SOUTH, 1, 0, ev) == 1 && is(0, B, DENA_INPUT_DOWN));
  CHECK(dena_input_key(&in, 3, BTN_SOUTH, 1, 1 * MS, ev) == 0);
  CHECK(dena_input_key(&in, 0, BTN_SOUTH, 0, 2 * MS, ev) == 0);  // still held on node 3
  CHECK(dena_input_held(&in, B));
  CHECK(dena_input_key(&in, 3, BTN_SOUTH, 0, 3 * MS, ev) == 1 && is(0, B, DENA_INPUT_UP));
  // A D-pad key and a hat on one node (stock firmware reports both).
  CHECK(dena_input_key(&in, 0, BTN_DPAD_UP, 1, 0, ev) == 1 && is(0, UP, DENA_INPUT_DOWN));
  CHECK(dena_input_hat(&in, 0, HAT0Y, -1, 0, ev) == 0);
  CHECK(dena_input_hat(&in, 0, HAT0Y, 0, 0, ev) == 0);
  CHECK(dena_input_key(&in, 0, BTN_DPAD_UP, 0, 0, ev) == 1 && is(0, UP, DENA_INPUT_UP));
}

static void hats(void) {
  struct dena_input in;
  load_h700(&in);
  CHECK(dena_input_hat(&in, 0, HAT0X, -1, 0, ev) == 1 && is(0, LEFT, DENA_INPUT_DOWN));
  CHECK(dena_input_hat(&in, 0, HAT0X, -1, 0, ev) == 0);  // same value again
  // Left straight to right: release left, then press right.
  CHECK(dena_input_hat(&in, 0, HAT0X, 1, 0, ev) == 2 && is(0, LEFT, DENA_INPUT_UP) &&
        is(1, RIGHT, DENA_INPUT_DOWN));
  CHECK(dena_input_hat(&in, 0, HAT0X, 0, 0, ev) == 1 && is(0, RIGHT, DENA_INPUT_UP));
  CHECK(dena_input_hat(&in, 0, 8, 1, 0, ev) == 0);  // no such hat axis
}

static void resync_after_drop(void) {
  struct dena_input in;
  load_h700(&in);
  dena_input_key(&in, 0, BTN_SOUTH, 1, 0, ev);
  dena_input_key(&in, 0, BTN_START, 1, 0, ev);
  // SYN_DROPPED: B's release and A's press were lost; the node now reports
  // Start and A down and the hat pushed down.
  int keys[] = {BTN_START, BTN_EAST, KEY_Q};
  int hat[8] = {0, 1};
  int n = dena_input_sync(&in, 0, keys, 3, hat, 5 * MS, ev, 64);
  CHECK(n == 3);
  CHECK(is(0, B, DENA_INPUT_UP) && is(1, DOWN, DENA_INPUT_DOWN) && is(2, A, DENA_INPUT_DOWN));
  CHECK(dena_input_held(&in, START) && dena_input_held(&in, A) && !dena_input_held(&in, B));
  // Syncing to the same state again changes nothing.
  CHECK(dena_input_sync(&in, 0, keys, 3, hat, 6 * MS, ev, 64) == 0);
  // Everything released while events were lost.
  n = dena_input_sync(&in, 0, NULL, 0, NULL, 7 * MS, ev, 64);
  CHECK(n == 3 && !dena_input_held(&in, START) && !dena_input_held(&in, A) &&
        !dena_input_held(&in, DOWN));
}

static void unplug(void) {
  struct dena_input in;
  load_h700(&in);
  dena_input_key(&in, 2, BTN_EAST, 1, 0, ev);
  dena_input_hat(&in, 2, HAT0X, 1, 0, ev);
  dena_input_key(&in, 0, BTN_EAST, 1, 0, ev);  // A also held on the built-in pad
  int n = dena_input_remove(&in, 2, 9 * MS, ev, 64);
  CHECK(n == 1 && is(0, RIGHT, DENA_INPUT_UP));  // A stays down: node 0 holds it
  CHECK(dena_input_held(&in, A));
  // A node that comes back under the same number starts clean.
  CHECK(dena_input_hat(&in, 2, HAT0X, 1, 10 * MS, ev) == 1 && is(0, RIGHT, DENA_INPUT_DOWN));
}

static void dpad_repeat(void) {
  struct dena_input in;
  load_h700(&in);
  CHECK(dena_input_timeout_ms(&in, 0) == -1);
  CHECK(dena_input_key(&in, 0, BTN_DPAD_DOWN, 1, 1000 * MS, ev) == 1);
  CHECK(dena_input_timeout_ms(&in, 1000 * MS) == 400);
  CHECK(dena_input_tick(&in, 1399 * MS, ev) == 0);
  CHECK(dena_input_tick(&in, 1400 * MS, ev) == 1 && is(0, DOWN, DENA_INPUT_REPEAT));
  CHECK(dena_input_timeout_ms(&in, 1400 * MS) == 80);
  CHECK(dena_input_tick(&in, 1479 * MS, ev) == 0);
  CHECK(dena_input_tick(&in, 1480 * MS, ev) == 1);
  // A late tick fires once, not a burst.
  CHECK(dena_input_tick(&in, 1900 * MS, ev) == 1);
  CHECK(dena_input_tick(&in, 1900 * MS, ev) == 0);
  // Held 2 s: faster.
  CHECK(dena_input_tick(&in, 3000 * MS, ev) == 1);
  CHECK(dena_input_timeout_ms(&in, 3000 * MS) == 40);
  // Pressing another direction: that one repeats, from a fresh delay.
  CHECK(dena_input_hat(&in, 0, HAT0X, -1, 3010 * MS, ev) == 1);
  CHECK(dena_input_tick(&in, 3100 * MS, ev) == 0);
  CHECK(dena_input_tick(&in, 3410 * MS, ev) == 1 && is(0, LEFT, DENA_INPUT_REPEAT));
  // Releasing it stops the repeat.
  dena_input_hat(&in, 0, HAT0X, 0, 3420 * MS, ev);
  CHECK(dena_input_timeout_ms(&in, 3420 * MS) == -1);
  CHECK(dena_input_tick(&in, 9000 * MS, ev) == 0);
  dena_input_key(&in, 0, BTN_DPAD_DOWN, 0, 9000 * MS, ev);
  // Buttons other than the D-pad never repeat.
  dena_input_key(&in, 0, BTN_EAST, 1, 10000 * MS, ev);
  CHECK(dena_input_timeout_ms(&in, 10000 * MS) == -1);
  CHECK(dena_input_tick(&in, 20000 * MS, ev) == 0);
  // Custom rates.
  struct dena_input_repeat fast = {100, 20, 500, 10};
  dena_input_init(&in, &profile, &fast);
  dena_input_key(&in, 0, BTN_DPAD_UP, 1, 0, ev);
  CHECK(dena_input_timeout_ms(&in, 0) == 100);
}

static void volume_repeat(void) {
  struct dena_input in;
  load_h700(&in);
  // The volume node has kernel auto-repeat: each repeat steps the volume.
  CHECK(dena_input_key(&in, 5, KEY_VOLUMEUP, 1, 0, ev) == 1 &&
        is(0, DENA_KEY_VOLUME_UP, DENA_INPUT_DOWN));
  CHECK(dena_input_key(&in, 5, KEY_VOLUMEUP, 2, 250 * MS, ev) == 1 &&
        is(0, DENA_KEY_VOLUME_UP, DENA_INPUT_REPEAT));
  CHECK(dena_input_key(&in, 5, KEY_VOLUMEUP, 0, 300 * MS, ev) == 1);
  // A repeat with no press (the node was opened mid-hold): ignored.
  CHECK(dena_input_key(&in, 5, KEY_VOLUMEDOWN, 2, 400 * MS, ev) == 0);
  CHECK(dena_input_timeout_ms(&in, 400 * MS) == -1);  // volume is not the D-pad
  // Power is passed through (the launcher ignores it; dena-powerd owns it).
  CHECK(dena_input_key(&in, 4, KEY_POWER, 1, 0, ev) == 1 && is(0, DENA_KEY_POWER, DENA_INPUT_DOWN));
}

static void full_node(void) {
  struct dena_input in;
  load_h700(&in);
  // A node mashing more keys than it can track: no overflow, and the mapped
  // presses that fit still pair with their releases.
  for (int c = 1; c <= DENA_INPUT_HELD + 8; c++) dena_input_key(&in, 0, c, 1, 0, ev);
  CHECK(dena_input_key(&in, 0, BTN_SELECT, 1, 0, ev) == 0);  // no room: never pressed
  CHECK(dena_input_key(&in, 0, BTN_SELECT, 0, 0, ev) == 0);  // so never released
  CHECK(dena_input_remove(&in, 0, 0, ev, 64) == 0);           // codes 1-32: all unmapped
}

static void game_routing(void) {
  struct dena_game_input g = {0};
  // Not playing (library, pause menu): everything is the UI's.
  CHECK(dena_game_input(&g, A, true, false) == DENA_GAME_IGNORED);
  CHECK(dena_game_input(&g, A, false, false) == DENA_GAME_IGNORED);
  // Playing: buttons go to the core.
  CHECK(dena_game_input(&g, A, true, true) == DENA_GAME_BUTTONS && g.mask == 1u << A);
  CHECK(dena_game_input(&g, RIGHT, true, true) == DENA_GAME_BUTTONS && g.mask == (1u << A | 1u << RIGHT));
  // Menu: every button released in the core, the pause menu opens.
  CHECK(dena_game_input(&g, DENA_KEY_MENU, true, true) == DENA_GAME_MENU && g.mask == 0);
  // The game is paused now; releases of presses it took stay with it.
  CHECK(dena_game_input(&g, DENA_KEY_MENU, false, false) == DENA_GAME_TAKEN);
  CHECK(dena_game_input(&g, A, false, false) == DENA_GAME_BUTTONS && g.mask == 0);
  // New presses in the pause menu are the UI's, and so are their releases
  // after it resumed the game.
  CHECK(dena_game_input(&g, B, true, false) == DENA_GAME_IGNORED);
  CHECK(dena_game_input(&g, B, false, true) == DENA_GAME_IGNORED);
  CHECK(dena_game_input(&g, RIGHT, false, true) == DENA_GAME_BUTTONS);
  CHECK(g.consumed == 0);
  // Start + Select also opens the menu.
  CHECK(dena_game_input(&g, SELECT, true, true) == DENA_GAME_BUTTONS);
  CHECK(dena_game_input(&g, START, true, true) == DENA_GAME_MENU && g.mask == 0);
  CHECK(dena_game_input(&g, SELECT, false, false) == DENA_GAME_BUTTONS);
  CHECK(dena_game_input(&g, START, false, false) == DENA_GAME_BUTTONS && g.consumed == 0);
  // Power and volume never reach the game.
  CHECK(dena_game_input(&g, DENA_KEY_POWER, true, true) == DENA_GAME_IGNORED);
  CHECK(dena_game_input(&g, DENA_KEY_VOLUME_UP, true, true) == DENA_GAME_IGNORED);
  CHECK(dena_game_input(&g, DENA_KEY_NONE, true, true) == DENA_GAME_IGNORED);
}

int main(void) {
  press_release();
  h700_buttons();
  two_nodes();
  hats();
  resync_after_drop();
  unplug();
  dpad_repeat();
  volume_repeat();
  full_node();
  game_routing();
  if (failures) {
    fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  puts("input tests passed");
  return 0;
}
