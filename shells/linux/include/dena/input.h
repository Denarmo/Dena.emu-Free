// SPDX-License-Identifier: GPL-3.0-or-later
// Input router for Linux handhelds: raw evdev key and hat events from every
// input node become one clean stream of profile actions. Pure (no
// linux/input.h): the launcher feeds it events and carries out what it
// returns. Spec: docs/specs/handheld-input.md
#ifndef DENA_INPUT_H
#define DENA_INPUT_H

#include <stdbool.h>
#include <stdint.h>

#include "dena/platform.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DENA_INPUT_DEVICES 16  // input nodes followed at once
#define DENA_INPUT_HELD 32     // sources held at once on one node
#define DENA_INPUT_ACTIONS 20  // RetroPad 0-15, then menu, power, volume up/down
#define DENA_INPUT_MAX_OUT 4   // events one key or hat event can produce

enum dena_input_kind { DENA_INPUT_DOWN, DENA_INPUT_UP, DENA_INPUT_REPEAT };

struct dena_input_event {
  int action;  // RetroPad id or enum dena_key_action
  enum dena_input_kind kind;
  uint64_t usec;  // event time (CLOCK_MONOTONIC)
};

// Held D-pad directions repeat for menu navigation: first after delay_ms,
// then every interval_ms, and every fast_interval_ms once held fast_after_ms.
struct dena_input_repeat {
  uint32_t delay_ms, interval_ms, fast_after_ms, fast_interval_ms;
};

struct dena_input {
  const struct dena_profile *profile;
  struct dena_input_repeat repeat;
  struct {
    int sources[DENA_INPUT_HELD];  // key codes / hat sources held on this node
    int count;
    int hat[8];  // ABS_HAT0X..ABS_HAT3Y: -1, 0, 1
  } dev[DENA_INPUT_DEVICES];
  uint8_t held[DENA_INPUT_ACTIONS];  // sources holding each action, all nodes
  int repeat_action;                 // DENA_KEY_NONE when nothing repeats
  uint64_t repeat_since, repeat_next;
};

// repeat may be NULL for the defaults (400 ms, 80 ms, 40 ms after 2 s).
void dena_input_init(struct dena_input *in, const struct dena_profile *profile,
                     const struct dena_input_repeat *repeat);

// One EV_KEY event from node dev (value 0 up, 1 down, 2 kernel auto-repeat).
// Writes up to DENA_INPUT_MAX_OUT events to out; returns how many.
// - An action goes down when its first source goes down and up when its last
//   is released, so the same button on two nodes (or a key and a hat on one)
//   never doubles; a second down without an up and an up without a down are
//   dropped.
// - Kernel auto-repeat only steps the volume; D-pad repeat comes from
//   dena_input_tick at the configured rate.
int dena_input_key(struct dena_input *in, int dev, int code, int value, uint64_t usec,
                   struct dena_input_event *out);

// One hat axis event (axis 0..7 = ABS_HAT0X..ABS_HAT3Y): a hat is two
// buttons; the old direction is released before the new one is pressed.
int dena_input_hat(struct dena_input *in, int dev, int axis, int value, uint64_t usec,
                   struct dena_input_event *out);

// After SYN_DROPPED: the node's real state (key codes down, hat values) as
// read back with EVIOCGKEY / EVIOCGABS. Releases what is no longer held and
// presses what is. Returns how many events it wrote (at most max).
int dena_input_sync(struct dena_input *in, int dev, const int *keys_down, int key_count,
                    const int hat[8], uint64_t usec, struct dena_input_event *out, int max);

// The node went away (unplugged, or a read error): everything it held is
// released.
int dena_input_remove(struct dena_input *in, int dev, uint64_t usec,
                      struct dena_input_event *out, int max);

// A D-pad repeat when one is due at usec (at most one per call; a late call
// does not burst). Returns 1 with *out filled, else 0.
int dena_input_tick(struct dena_input *in, uint64_t usec, struct dena_input_event *out);

// Milliseconds until the next repeat is due (0 = now), or -1 for none.
int dena_input_timeout_ms(const struct dena_input *in, uint64_t usec);

// Whether an action is held on any node.
bool dena_input_held(const struct dena_input *in, int action);

// Buttons during a game (handheld-session.md). A press the game took sends
// its release to the game too, wherever the UI is by then; everything else
// is the UI's.
struct dena_game_input {
  uint32_t mask;      // RetroPad buttons held (port 0)
  uint32_t consumed;  // presses the game took: bits 0-15 RetroPad, 16 menu
};

enum dena_game_route {
  DENA_GAME_IGNORED,  // not the game's: a key for the UI
  DENA_GAME_TAKEN,    // the game's, nothing to do
  DENA_GAME_BUTTONS,  // send mask to the core
  DENA_GAME_MENU,     // release every button in the core, open the pause menu
};

// playing: a game runs and is not paused.
enum dena_game_route dena_game_input(struct dena_game_input *g, int action, bool down,
                                     bool playing);

#ifdef __cplusplus
}
#endif
#endif
