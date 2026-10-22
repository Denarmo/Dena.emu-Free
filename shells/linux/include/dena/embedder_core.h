// SPDX-License-Identifier: GPL-3.0-or-later
// The pure parts of the handheld embedder: display mode choice, panel
// rotation and the key mapping into Flutter. Spec: docs/specs/embedder.md
#ifndef DENA_EMBEDDER_CORE_H
#define DENA_EMBEDDER_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct dena_mode {
  int width, height;
  int refresh_mhz; // refresh in millihertz (59940 = 59.94 Hz)
  int preferred;   // the connector's preferred mode
};

// Index of the mode to use: an exact size match for the profile's display
// (width/height 0 = "auto"), refresh nearest 60 Hz; else the preferred size,
// else the largest, also at the refresh nearest 60 Hz. -1 for an empty list.
int dena_pick_mode(const struct dena_mode *modes, int count, int want_width,
                   int want_height);

// Panel rotation as Flutter's root transformation (FlutterTransformation
// field order: scaleX skewX transX skewY scaleY transY pers0 pers1 pers2),
// mapping logical (view) coordinates to the physical scan-out.
struct dena_transform {
  double m[9];
  int logical_width, logical_height;
};

// rotate: 0, 90, 180 or 270 degrees clockwise. Returns 0, or -1 for any
// other angle (then *out is the identity).
int dena_rotation(int rotate, int width, int height, struct dena_transform *out);

// Applies a transform to a point (used for touch panels mounted rotated:
// the inverse direction, physical to logical, is dena_unrotate_point).
void dena_unrotate_point(int rotate, int width, int height, double px,
                         double py, double *lx, double *ly);

// Flutter key ids (LogicalKeyboardKey / PhysicalKeyboardKey keyId values;
// checked against the framework by app/test/shell/embedder_keys_test.dart).
#define DENA_LOGICAL_ARROW_DOWN 0x00100000301ULL
#define DENA_LOGICAL_ARROW_LEFT 0x00100000302ULL
#define DENA_LOGICAL_ARROW_RIGHT 0x00100000303ULL
#define DENA_LOGICAL_ARROW_UP 0x00100000304ULL
#define DENA_LOGICAL_GAME_A 0x00200000311ULL
#define DENA_LOGICAL_GAME_B 0x00200000312ULL
#define DENA_LOGICAL_GAME_LEFT1 0x00200000314ULL
#define DENA_LOGICAL_GAME_LEFT2 0x00200000315ULL
#define DENA_LOGICAL_GAME_MODE 0x00200000316ULL
#define DENA_LOGICAL_GAME_RIGHT1 0x00200000317ULL
#define DENA_LOGICAL_GAME_RIGHT2 0x00200000318ULL
#define DENA_LOGICAL_GAME_SELECT 0x00200000319ULL
#define DENA_LOGICAL_GAME_START 0x0020000031aULL
#define DENA_LOGICAL_GAME_THUMB_LEFT 0x0020000031bULL
#define DENA_LOGICAL_GAME_THUMB_RIGHT 0x0020000031cULL
#define DENA_LOGICAL_GAME_X 0x0020000031dULL
#define DENA_LOGICAL_GAME_Y 0x0020000031eULL
// Physical ids: game buttons are 0x0005ff00 + the logical id's low byte;
// arrows are USB HID keyboard usages.
#define DENA_PHYSICAL_GAME_BASE 0x0005ff00ULL
#define DENA_PHYSICAL_ARROW_RIGHT 0x0007004fULL
#define DENA_PHYSICAL_ARROW_LEFT 0x00070050ULL
#define DENA_PHYSICAL_ARROW_DOWN 0x00070051ULL
#define DENA_PHYSICAL_ARROW_UP 0x00070052ULL

struct dena_flutter_key {
  uint64_t logical;
  uint64_t physical;
};

// The Flutter key for a profile action (RetroPad id or DENA_KEY_MENU), or
// {0, 0} for actions the UI never sees (power and volume).
struct dena_flutter_key dena_flutter_key(int action);

#ifdef __cplusplus
}
#endif
#endif
