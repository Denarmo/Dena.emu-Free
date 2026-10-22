// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/embedder.md (Acceptance tests, host-buildable parts)
#include <math.h>
#include <stdio.h>

#include "dena/embedder_core.h"
#include "dena/platform.h"

static int failures;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #c); \
      failures++;                                                 \
    }                                                             \
  } while (0)

static void modes(void) {
  struct dena_mode list[] = {
      {1280, 720, 60000, 0}, {640, 480, 50000, 0}, {640, 480, 59940, 0},
      {720, 720, 60000, 1},  {1920, 1080, 60000, 0},
  };
  CHECK(dena_pick_mode(list, 5, 640, 480) == 2);  // exact size, nearest 60
  CHECK(dena_pick_mode(list, 5, 0, 0) == 3);      // auto: preferred
  CHECK(dena_pick_mode(list, 5, 800, 600) == 3);  // no match: preferred
  CHECK(dena_pick_mode(list, 3, 0, 0) == 0);      // no preferred: largest
  CHECK(dena_pick_mode(list, 0, 0, 0) == -1);
  // The SP's panel prefers 120 Hz: auto still runs at 60.
  struct dena_mode sp[] = {{640, 480, 120000, 1}, {640, 480, 60000, 0}};
  CHECK(dena_pick_mode(sp, 2, 0, 0) == 1);
  CHECK(dena_pick_mode(sp, 2, 640, 480) == 1);
  struct dena_mode largest[] = {{640, 480, 60000, 0}, {1280, 720, 120000, 0}, {1280, 720, 59940, 0}};
  CHECK(dena_pick_mode(largest, 3, 0, 0) == 2);
}

static void apply(const struct dena_transform *t, double x, double y,
                  double *px, double *py) {
  *px = t->m[0] * x + t->m[1] * y + t->m[2];
  *py = t->m[3] * x + t->m[4] * y + t->m[5];
}

static void rotation(void) {
  const int W = 640, H = 480;
  struct dena_transform t;
  CHECK(dena_rotation(0, W, H, &t) == 0 && t.logical_width == W);
  CHECK(dena_rotation(45, W, H, &t) == -1 && t.m[0] == 1 && t.m[4] == 1);
  const int angles[] = {0, 90, 180, 270};
  for (int i = 0; i < 4; i++) {
    int a = angles[i];
    CHECK(dena_rotation(a, W, H, &t) == 0);
    int swapped = a == 90 || a == 270;
    CHECK(t.logical_width == (swapped ? H : W));
    CHECK(t.logical_height == (swapped ? W : H));
    // Logical corners land inside the physical screen; unrotating returns them.
    const double pts[][2] = {{0, 0}, {t.logical_width, 0}, {0, t.logical_height},
                             {13, 7}};
    for (int j = 0; j < 4; j++) {
      double px, py, lx, ly;
      apply(&t, pts[j][0], pts[j][1], &px, &py);
      CHECK(px >= 0 && px <= W && py >= 0 && py <= H);
      dena_unrotate_point(a, W, H, px, py, &lx, &ly);
      CHECK(fabs(lx - pts[j][0]) < 1e-9 && fabs(ly - pts[j][1]) < 1e-9);
    }
  }
  // 90° clockwise: the logical top-left is the physical top-right.
  double px, py;
  dena_rotation(90, W, H, &t);
  apply(&t, 0, 0, &px, &py);
  CHECK(px == W && py == 0);
}

static void keys(void) {
  struct dena_flutter_key k = dena_flutter_key(8); // RetroPad A
  CHECK(k.logical == DENA_LOGICAL_GAME_A && k.physical == 0x0005ff11ULL);
  k = dena_flutter_key(0); // B: back in the UI
  CHECK(k.logical == DENA_LOGICAL_GAME_B && k.physical == 0x0005ff12ULL);
  k = dena_flutter_key(4);
  CHECK(k.logical == DENA_LOGICAL_ARROW_UP && k.physical == DENA_PHYSICAL_ARROW_UP);
  CHECK(dena_flutter_key(DENA_KEY_MENU).logical == DENA_LOGICAL_GAME_MODE);
  CHECK(dena_flutter_key(DENA_KEY_POWER).logical == 0);
  CHECK(dena_flutter_key(DENA_KEY_VOLUME_UP).logical == 0);
  CHECK(dena_flutter_key(DENA_KEY_NONE).logical == 0);
  // Every RetroPad button has a distinct key.
  for (int a = 0; a < 16; a++) {
    CHECK(dena_flutter_key(a).logical != 0);
    for (int b = 0; b < a; b++)
      CHECK(dena_flutter_key(a).logical != dena_flutter_key(b).logical);
  }
}

int main(void) {
  modes();
  rotation();
  keys();
  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  puts("embedder: all passed");
  return 0;
}
