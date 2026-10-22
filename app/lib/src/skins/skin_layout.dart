// SPDX-License-Identifier: GPL-3.0-or-later
// Skin model shared by built-in and imported skins, and touch hit-testing.
// Spec: docs/specs/skins.md
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:material_ui/material_ui.dart';

/// libretro RetroPad bit indices (same as the Kotlin `RetroPad`).
abstract final class RetroPad {
  static const b = 0, y = 1, select = 2, start = 3;
  static const up = 4, down = 5, left = 6, right = 7;
  static const a = 8, x = 9, l = 10, r = 11, l2 = 12, r2 = 13;
}

/// Skin input names (skins.md) to RetroPad bits.
const inputBits = {
  'up': RetroPad.up,
  'down': RetroPad.down,
  'left': RetroPad.left,
  'right': RetroPad.right,
  'a': RetroPad.a,
  'b': RetroPad.b,
  'x': RetroPad.x,
  'y': RetroPad.y,
  'l': RetroPad.l,
  'r': RetroPad.r,
  'l2': RetroPad.l2,
  'r2': RetroPad.r2,
  'start': RetroPad.start,
  'select': RetroPad.select,
};

/// Inputs that tilt an analog stick fully (N64 C-buttons on the right stick,
/// n64.md): name to (stick, direction).
const analogInputs = {
  'cup': (1, Offset(0, -1)),
  'cdown': (1, Offset(0, 1)),
  'cleft': (1, Offset(-1, 0)),
  'cright': (1, Offset(1, 0)),
};

/// Thumbstick dead zone, as a fraction of the stick's radius.
const stickDeadZone = 0.12;

enum SkinItemKind { button, dpad, menu, thumbstick }

/// One touch control in mapping space.
class SkinItem {
  const SkinItem({
    required this.kind,
    required this.frame,
    this.inputs = const [],
    this.label = '',
    this.extended = const EdgeInsets.all(8),
  });

  final SkinItemKind kind;
  final Rect frame;

  /// Input names pressed together (a combo when several); unused for D-pads.
  final List<String> inputs;

  /// Text drawn by built-in skins.
  final String label;

  /// Extra touch area around [frame].
  final EdgeInsets extended;

  Rect get touchRect => extended.inflateRect(frame);
}

/// A skin for one orientation: items and the game screen in mapping space.
class SkinLayout {
  const SkinLayout({
    required this.mappingSize,
    required this.items,
    required this.screen,
    this.translucent = false,
  });

  final Size mappingSize;
  final List<SkinItem> items;

  /// Where the game picture goes.
  final Rect screen;

  /// Controls drawn over the game (landscape built-in skins).
  final bool translucent;
}

/// The result of hit-testing all pointers.
class TouchState {
  const TouchState(
    this.mask,
    this.menu,
    this.pressed, [
    this.analog = const {},
  ]);

  static const none = TouchState(0, false, {});

  /// Stick (0 left, 1 right) to tilt, each axis -1..1 with +y down.
  final Map<int, Offset> analog;

  final int mask;

  /// A pointer is on the menu item.
  final bool menu;

  /// Index of the item under each pointer.
  final Map<int, int> pressed;
}

/// D-pad dead zone, as a fraction of the half-size (skins.md).
const dpadDeadZone = 0.15;

/// The item a point hits: the first whose frame contains it, else the nearest
/// (by centre) whose extended frame contains it. Null when none.
int? hitItem(SkinLayout layout, Offset p) {
  for (var i = layout.items.length - 1; i >= 0; i--) {
    if (layout.items[i].frame.contains(p)) return i;
  }
  int? best;
  var bestDist = double.infinity;
  for (var i = 0; i < layout.items.length; i++) {
    final item = layout.items[i];
    if (!item.touchRect.contains(p)) continue;
    final d = (item.frame.center - p).distanceSquared;
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

/// D-pad bits for a point: 8 directions by angle, nothing in the dead zone.
int dpadBits(Rect frame, Offset p) {
  final v = p - frame.center;
  final nx = v.dx / (frame.width / 2), ny = v.dy / (frame.height / 2);
  if (math.sqrt(nx * nx + ny * ny) < dpadDeadZone) return 0;
  // Sector 0 = right, counter-clockwise in 45° steps (y grows downward).
  final sector = ((math.atan2(-ny, nx) / (math.pi / 4)).round() + 8) % 8;
  const bits = [
    1 << RetroPad.right,
    1 << RetroPad.right | 1 << RetroPad.up,
    1 << RetroPad.up,
    1 << RetroPad.up | 1 << RetroPad.left,
    1 << RetroPad.left,
    1 << RetroPad.left | 1 << RetroPad.down,
    1 << RetroPad.down,
    1 << RetroPad.down | 1 << RetroPad.right,
  ];
  return bits[sector];
}

/// Combines every pointer (positions in mapping space) into a RetroPad mask.
/// A pointer that held a thumbstick in [previous] keeps it wherever it moves.
TouchState touchState(
  SkinLayout layout,
  Map<int, Offset> pointers, {
  TouchState? previous,
}) {
  var mask = 0;
  var menu = false;
  final pressed = <int, int>{};
  final analog = <int, Offset>{};
  void tilt(int stick, Offset v) {
    final sum = (analog[stick] ?? Offset.zero) + v;
    analog[stick] = Offset(sum.dx.clamp(-1.0, 1.0), sum.dy.clamp(-1.0, 1.0));
  }

  for (final MapEntry(key: id, value: p) in pointers.entries) {
    final held = previous?.pressed[id];
    final i =
        held != null &&
            held < layout.items.length &&
            layout.items[held].kind == SkinItemKind.thumbstick
        ? held
        : hitItem(layout, p);
    if (i == null) continue;
    pressed[id] = i;
    final item = layout.items[i];
    switch (item.kind) {
      case SkinItemKind.dpad:
        mask |= dpadBits(item.frame, p);
      case SkinItemKind.menu:
        menu = true;
      case SkinItemKind.thumbstick:
        tilt(
          item.inputs.contains('rightstick') ? 1 : 0,
          stickTilt(item.frame, p),
        );
      case SkinItemKind.button:
        for (final name in item.inputs) {
          final bit = inputBits[name];
          if (bit != null) mask |= 1 << bit;
          final a = analogInputs[name];
          if (a != null) tilt(a.$1, a.$2);
        }
    }
  }
  return TouchState(mask, menu, pressed, analog);
}

/// A thumbstick's tilt for a point: inside the unit circle, zero in the dead
/// zone, rescaled so the dead-zone edge is 0.
Offset stickTilt(Rect frame, Offset p) {
  var v = (p - frame.center) / (frame.width / 2);
  final d = v.distance;
  if (d < stickDeadZone) return Offset.zero;
  final t = ((d - stickDeadZone) / (1 - stickDeadZone)).clamp(0.0, 1.0);
  return v / d * t;
}

/// The horizontal fold of a foldable in tabletop posture (half open, hinge
/// across the screen), in screen coordinates; null otherwise (adaptive.md).
/// A physical hinge always splits the screen, whatever the posture.
Rect? tabletopFold(List<DisplayFeature> features) {
  for (final f in features) {
    final horizontal = f.bounds.width > f.bounds.height;
    if (!horizontal) continue;
    if (f.type == DisplayFeatureType.hinge ||
        (f.type == DisplayFeatureType.fold &&
            f.state == DisplayFeatureState.postureHalfOpened)) {
      return f.bounds;
    }
  }
  return null;
}
