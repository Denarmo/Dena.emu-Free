// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/embedder.md
#include "dena/embedder_core.h"

#include <stdlib.h>
#include <string.h>

#include "dena/platform.h"

// Among the modes of the given size, the one whose refresh is nearest 60 Hz;
// -1 if there is none.
static int nearest_60(const struct dena_mode *modes, int count, int width, int height) {
  int best = -1;
  for (int i = 0; i < count; i++) {
    if (modes[i].width != width || modes[i].height != height) continue;
    if (best < 0 || abs(modes[i].refresh_mhz - 60000) < abs(modes[best].refresh_mhz - 60000))
      best = i;
  }
  return best;
}

int dena_pick_mode(const struct dena_mode *modes, int count, int want_width,
                   int want_height) {
  if (count <= 0) return -1;
  if (want_width > 0 && want_height > 0) {
    int best = nearest_60(modes, count, want_width, want_height);
    if (best >= 0) return best;
  }
  // The preferred size (else the largest), at the refresh nearest 60 Hz: some
  // panels (RG35XX SP) prefer a 120 Hz mode the UI and the cores cannot fill.
  int size = -1;
  for (int i = 0; i < count && size < 0; i++)
    if (modes[i].preferred) size = i;
  if (size < 0) {
    size = 0;
    for (int i = 1; i < count; i++) {
      long a = (long)modes[i].width * modes[i].height;
      long b = (long)modes[size].width * modes[size].height;
      if (a > b) size = i;
    }
  }
  return nearest_60(modes, count, modes[size].width, modes[size].height);
}

int dena_rotation(int rotate, int width, int height, struct dena_transform *out) {
  static const double identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  memcpy(out->m, identity, sizeof identity);
  out->logical_width = width;
  out->logical_height = height;
  double *m = out->m;
  switch (rotate) {
    case 0:
      return 0;
    case 90: // logical (x, y) → physical (W - y, x)
      m[0] = 0, m[1] = -1, m[2] = width;
      m[3] = 1, m[4] = 0, m[5] = 0;
      break;
    case 180: // → (W - x, H - y)
      m[0] = -1, m[2] = width;
      m[4] = -1, m[5] = height;
      return 0;
    case 270: // → (y, H - x)
      m[0] = 0, m[1] = 1, m[2] = 0;
      m[3] = -1, m[4] = 0, m[5] = height;
      break;
    default:
      return -1;
  }
  out->logical_width = height;
  out->logical_height = width;
  return 0;
}

void dena_unrotate_point(int rotate, int width, int height, double px,
                         double py, double *lx, double *ly) {
  switch (rotate) {
    case 90:
      *lx = py, *ly = width - px;
      break;
    case 180:
      *lx = width - px, *ly = height - py;
      break;
    case 270:
      *lx = height - py, *ly = px;
      break;
    default:
      *lx = px, *ly = py;
  }
}

static struct dena_flutter_key game(uint64_t logical) {
  struct dena_flutter_key k = {logical, DENA_PHYSICAL_GAME_BASE | (logical & 0xff)};
  return k;
}

struct dena_flutter_key dena_flutter_key(int action) {
  struct dena_flutter_key none = {0, 0};
  switch (action) {
    case 0: return game(DENA_LOGICAL_GAME_B);
    case 1: return game(DENA_LOGICAL_GAME_Y);
    case 2: return game(DENA_LOGICAL_GAME_SELECT);
    case 3: return game(DENA_LOGICAL_GAME_START);
    case 4: return (struct dena_flutter_key){DENA_LOGICAL_ARROW_UP, DENA_PHYSICAL_ARROW_UP};
    case 5: return (struct dena_flutter_key){DENA_LOGICAL_ARROW_DOWN, DENA_PHYSICAL_ARROW_DOWN};
    case 6: return (struct dena_flutter_key){DENA_LOGICAL_ARROW_LEFT, DENA_PHYSICAL_ARROW_LEFT};
    case 7: return (struct dena_flutter_key){DENA_LOGICAL_ARROW_RIGHT, DENA_PHYSICAL_ARROW_RIGHT};
    case 8: return game(DENA_LOGICAL_GAME_A);
    case 9: return game(DENA_LOGICAL_GAME_X);
    case 10: return game(DENA_LOGICAL_GAME_LEFT1);
    case 11: return game(DENA_LOGICAL_GAME_RIGHT1);
    case 12: return game(DENA_LOGICAL_GAME_LEFT2);
    case 13: return game(DENA_LOGICAL_GAME_RIGHT2);
    case 14: return game(DENA_LOGICAL_GAME_THUMB_LEFT);
    case 15: return game(DENA_LOGICAL_GAME_THUMB_RIGHT);
    case DENA_KEY_MENU: return game(DENA_LOGICAL_GAME_MODE);
    default: return none;
  }
}
