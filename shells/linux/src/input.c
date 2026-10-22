// SPDX-License-Identifier: GPL-3.0-or-later
// Input router: per-node source tracking, action reference counts, D-pad
// repeat. Spec: docs/specs/handheld-input.md
#include "dena/input.h"

#include <string.h>

// Hat directions as the profile spells them: abs.<ABS_HAT0X + axis><+/->.
#define HAT_SOURCE(axis, dir) (0x10000 + (0x10 + (axis)) * 2 + ((dir) > 0))

// Actions as array slots: RetroPad 0-15, then menu, power, volume up/down.
static int slot(int action) {
  if (action >= 0 && action < 16) return action;
  if (action >= DENA_KEY_MENU && action <= DENA_KEY_VOLUME_DOWN) return 16 + action - DENA_KEY_MENU;
  return -1;
}

static bool is_dpad(int action) { return action >= 4 && action <= 7; }

static uint64_t ms(uint32_t v) { return (uint64_t)v * 1000u; }  // ms → usec

void dena_input_init(struct dena_input *in, const struct dena_profile *profile,
                     const struct dena_input_repeat *repeat) {
  memset(in, 0, sizeof *in);
  in->profile = profile;
  in->repeat = repeat ? *repeat : (struct dena_input_repeat){400, 80, 2000, 40};
  in->repeat_action = DENA_KEY_NONE;
}

static int find(const struct dena_input *in, int dev, int source) {
  for (int i = 0; i < in->dev[dev].count; i++)
    if (in->dev[dev].sources[i] == source) return i;
  return -1;
}

static int emit(struct dena_input_event *out, int n, int max, int action,
                enum dena_input_kind kind, uint64_t usec) {
  if (n < max) out[n++] = (struct dena_input_event){action, kind, usec};
  return n;
}

// One source on one node goes down or up; writes the action's edge, if any.
static int source(struct dena_input *in, int dev, int src, bool down, uint64_t usec,
                  struct dena_input_event *out, int n, int max) {
  int action = dena_profile_action(in->profile, src), s = slot(action);
  int at = find(in, dev, src);
  if (down) {
    if (at >= 0 || in->dev[dev].count == DENA_INPUT_HELD) return n;  // doubled
    in->dev[dev].sources[in->dev[dev].count++] = src;
    if (s < 0 || in->held[s]++ > 0) return n;  // unmapped, or already down elsewhere
    if (is_dpad(action)) {  // the newest direction repeats
      in->repeat_action = action;
      in->repeat_since = usec;
      in->repeat_next = usec + ms(in->repeat.delay_ms);
    }
    return emit(out, n, max, action, DENA_INPUT_DOWN, usec);
  }
  if (at < 0) return n;  // a release without its press
  in->dev[dev].sources[at] = in->dev[dev].sources[--in->dev[dev].count];
  if (s < 0 || in->held[s] == 0 || --in->held[s] > 0) return n;  // still held elsewhere
  if (in->repeat_action == action) in->repeat_action = DENA_KEY_NONE;
  return emit(out, n, max, action, DENA_INPUT_UP, usec);
}

static bool bad_dev(int dev) { return dev < 0 || dev >= DENA_INPUT_DEVICES; }

int dena_input_key(struct dena_input *in, int dev, int code, int value, uint64_t usec,
                   struct dena_input_event *out) {
  if (bad_dev(dev) || code <= 0 || code >= 0x10000) return 0;
  if (value == 2) {
    // Kernel auto-repeat: only the volume steps on it.
    int action = dena_profile_action(in->profile, code);
    bool volume = action == DENA_KEY_VOLUME_UP || action == DENA_KEY_VOLUME_DOWN;
    if (!volume || find(in, dev, code) < 0) return 0;
    return emit(out, 0, DENA_INPUT_MAX_OUT, action, DENA_INPUT_REPEAT, usec);
  }
  return source(in, dev, code, value != 0, usec, out, 0, DENA_INPUT_MAX_OUT);
}

static int hat_to(struct dena_input *in, int dev, int axis, int now, uint64_t usec,
                  struct dena_input_event *out, int n, int max) {
  int old = in->dev[dev].hat[axis];
  if (old == now) return n;
  if (old) n = source(in, dev, HAT_SOURCE(axis, old), false, usec, out, n, max);
  if (now) n = source(in, dev, HAT_SOURCE(axis, now), true, usec, out, n, max);
  in->dev[dev].hat[axis] = now;
  return n;
}

int dena_input_hat(struct dena_input *in, int dev, int axis, int value, uint64_t usec,
                   struct dena_input_event *out) {
  if (bad_dev(dev) || axis < 0 || axis >= 8) return 0;
  int now = value > 0 ? 1 : value < 0 ? -1 : 0;
  return hat_to(in, dev, axis, now, usec, out, 0, DENA_INPUT_MAX_OUT);
}

int dena_input_sync(struct dena_input *in, int dev, const int *keys_down, int key_count,
                    const int hat[8], uint64_t usec, struct dena_input_event *out, int max) {
  if (bad_dev(dev)) return 0;
  int n = 0;
  // Releases first, so an action moving between sources never doubles.
  for (int i = in->dev[dev].count - 1; i >= 0; i--) {
    int src = in->dev[dev].sources[i];
    if (src >= 0x10000) continue;  // hats below
    bool still = false;
    for (int k = 0; k < key_count && !still; k++) still = keys_down[k] == src;
    if (!still) n = source(in, dev, src, false, usec, out, n, max);
  }
  for (int a = 0; a < 8; a++) {
    int now = hat ? (hat[a] > 0 ? 1 : hat[a] < 0 ? -1 : 0) : 0;
    n = hat_to(in, dev, a, now, usec, out, n, max);
  }
  for (int k = 0; k < key_count; k++)
    if (keys_down[k] > 0 && keys_down[k] < 0x10000 && find(in, dev, keys_down[k]) < 0)
      n = source(in, dev, keys_down[k], true, usec, out, n, max);
  return n;
}

int dena_input_remove(struct dena_input *in, int dev, uint64_t usec,
                      struct dena_input_event *out, int max) {
  if (bad_dev(dev)) return 0;
  int n = 0;
  while (in->dev[dev].count > 0)
    n = source(in, dev, in->dev[dev].sources[in->dev[dev].count - 1], false, usec, out, n, max);
  memset(in->dev[dev].hat, 0, sizeof in->dev[dev].hat);
  return n;
}

int dena_input_tick(struct dena_input *in, uint64_t usec, struct dena_input_event *out) {
  if (in->repeat_action == DENA_KEY_NONE || usec < in->repeat_next) return 0;
  bool fast = usec - in->repeat_since >= ms(in->repeat.fast_after_ms);
  in->repeat_next = usec + ms(fast ? in->repeat.fast_interval_ms : in->repeat.interval_ms);
  *out = (struct dena_input_event){in->repeat_action, DENA_INPUT_REPEAT, usec};
  return 1;
}

int dena_input_timeout_ms(const struct dena_input *in, uint64_t usec) {
  if (in->repeat_action == DENA_KEY_NONE) return -1;
  if (usec >= in->repeat_next) return 0;
  return (int)((in->repeat_next - usec + 999) / 1000);
}

bool dena_input_held(const struct dena_input *in, int action) {
  int s = slot(action);
  return s >= 0 && in->held[s] > 0;
}

enum dena_game_route dena_game_input(struct dena_game_input *g, int action, bool down,
                                     bool playing) {
  int bit = action >= 0 && action < 16 ? action : action == DENA_KEY_MENU ? 16 : -1;
  if (bit < 0) return DENA_GAME_IGNORED;  // power and volume
  uint32_t b = 1u << bit;
  if (!down && (g->consumed & b)) {  // release of a press the game took
    g->consumed &= ~b;
    if (bit == 16) return DENA_GAME_TAKEN;
    g->mask &= ~b;
    return DENA_GAME_BUTTONS;
  }
  if (!down || !playing) return DENA_GAME_IGNORED;
  g->consumed |= b;
  if (action == DENA_KEY_MENU) {
    g->mask = 0;
    return DENA_GAME_MENU;
  }
  g->mask |= b;
  const uint32_t chord = 1u << 2 | 1u << 3;  // Select + Start (gamepads.md)
  if ((g->mask & chord) == chord) {
    g->mask = 0;
    return DENA_GAME_MENU;
  }
  return DENA_GAME_BUTTONS;
}
