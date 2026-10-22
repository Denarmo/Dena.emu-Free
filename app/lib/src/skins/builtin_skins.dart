// SPDX-License-Identifier: GPL-3.0-or-later
// Built-in touch skins, laid out for the actual screen size.
// Spec: docs/specs/skins.md (8a)
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'skin_layout.dart';

/// Face buttons per system, as (input, label, x, y) with x/y as offsets from
/// the cluster centre in units of the button size.
List<(String, String, double, double)> _faceButtons(String system) =>
    switch (system) {
      'snes' || 'nds' => [
        ('x', 'X', 0, -0.95),
        ('y', 'Y', -0.95, 0),
        ('a', 'A', 0.95, 0),
        ('b', 'B', 0, 0.95),
      ],
      // PlayStation: triangle, square, circle, cross on RetroPad X, Y, A, B.
      'psx' || 'psp' || 'ps2' => [
        ('x', '△', 0, -0.95),
        ('y', '□', -0.95, 0),
        ('a', '○', 0.95, 0),
        ('b', '✕', 0, 0.95),
      ],
      // Saturn (dreamcast-saturn.md): A B C below X Y Z, on Beetle Saturn's
      // RetroPad B, A, R1 and Y, X, L1.
      'saturn' => [
        ('y', 'X', -1.15, -0.55),
        ('x', 'Y', 0, -0.75),
        ('l', 'Z', 1.15, -0.95),
        ('b', 'A', -1.15, 0.65),
        ('a', 'B', 0, 0.45),
        ('r', 'C', 1.15, 0.25),
      ],
      // Dreamcast: Y on top, X left, B right, A below (Flycast's RetroPad
      // X, Y, A, B).
      'dreamcast' => [
        ('x', 'Y', 0, -0.95),
        ('y', 'X', -0.95, 0),
        ('a', 'B', 0.95, 0),
        ('b', 'A', 0, 0.95),
      ],
      // GameCube (gamecube-wii.md): the big A in the middle, B low left,
      // X right, Y on top, on Dolphin's RetroPad A, B, X, Y.
      'gamecube' => [
        ('a', 'A', 0, 0.1),
        ('b', 'B', -0.95, 0.75),
        ('x', 'X', 1.0, -0.2),
        ('y', 'Y', -0.2, -0.9),
      ],
      // Wii Remote + Nunchuk: A and B, the Nunchuk's C and Z (Dolphin's
      // RetroPad A, B, X, Y).
      'wii' => [
        ('x', 'C', 0, -0.95),
        ('y', 'Z', -0.95, 0),
        ('a', 'A', 0.95, 0),
        ('b', 'B', 0, 0.95),
      ],
      'genesis' => [
        ('y', 'A', -1.15, 0.35),
        ('b', 'B', 0, 0),
        ('a', 'C', 1.15, -0.35),
      ],
      // PICO-8 (pico8.md): O on RetroPad B, X on A.
      'pico8' => [('b', 'O', -0.62, 0.38), ('a', 'X', 0.62, -0.38)],
      _ => [('b', 'B', -0.62, 0.38), ('a', 'A', 0.62, -0.38)],
    };

bool _hasShoulders(String system) =>
    system == 'gba' ||
    system == 'snes' ||
    system == 'nds' ||
    system == 'psx' ||
    system == 'ps2' ||
    system == 'psp' ||
    system == 'saturn' ||
    system == 'dreamcast' ||
    system == 'gamecube' ||
    system == 'wii';

/// Systems whose only shoulder pair is the RetroPad's L2/R2: the Saturn's
/// L/R and the Dreamcast's triggers (dreamcast-saturn.md).
bool _shouldersOnL2(String system) =>
    system == 'saturn' || system == 'dreamcast';

/// Systems with a second pair of shoulder buttons (L2/R2); the GameCube's
/// L, Z and R take three of the four places.
bool _hasSecondShoulders(String system) =>
    system == 'psx' || system == 'ps2' || system == 'gamecube';

/// Largest D-pad / stick size, so tablets don't get palm-sized controls
/// (adaptive.md).
const maxControlSize = 220.0;

/// The built-in skin for [system] on a screen of [size] with a game picture
/// of [aspect] (width / height). With a horizontal [fold] (a foldable in
/// tabletop posture, adaptive.md) the picture sits above it and the controls
/// below.
SkinLayout builtinSkin(String system, Size size, double aspect, {Rect? fold}) {
  if (system == 'n64') return _n64Skin(size, aspect, fold);
  final w = size.width, h = size.height;
  final fullWidthHeight = w / aspect;
  // Portrait style when a full-width picture leaves room for the controls.
  final portrait = fold != null || h - fullWidthHeight >= h * 0.3;
  final items = <SkinItem>[];
  late final Rect screen;
  late final double d; // D-pad size
  late final Offset dpadAt, faceAt;
  late final double controlsTop;

  if (portrait) {
    final maxH = fold?.top ?? h * 0.55;
    final sh = math.min(fullWidthHeight, maxH);
    final sw = sh * aspect;
    screen = Rect.fromLTWH(
      (w - sw) / 2,
      fold == null ? 0 : (maxH - sh) / 2,
      sw,
      sh,
    );
    controlsTop = fold?.bottom ?? sh;
    final rh = h - controlsTop;
    d = math.min(math.min(w * 0.36, rh * 0.5), maxControlSize);
    final cy = controlsTop + rh * 0.48;
    dpadAt = Offset(w * 0.25, cy);
    faceAt = Offset(w * 0.75, cy);
  } else {
    final sw = math.min(w, h * aspect);
    final sh = sw / aspect;
    screen = Rect.fromLTWH((w - sw) / 2, (h - sh) / 2, sw, sh);
    controlsTop = 0;
    d = math.min(math.min(h * 0.34, w * 0.2), maxControlSize);
    dpadAt = Offset(math.max(d * 0.7, w * 0.11), h * 0.62);
    faceAt = Offset(w - math.max(d * 0.7, w * 0.11), h * 0.62);
  }

  items.add(
    SkinItem(
      kind: SkinItemKind.dpad,
      frame: Rect.fromCenter(center: dpadAt, width: d, height: d),
      extended: EdgeInsets.all(d * 0.15),
    ),
  );
  // PSP (psp.md): the analog nub below the D-pad, or beside it in landscape.
  // The Dreamcast's, PS2's, GameCube's and Nunchuk's sticks go in the same
  // place.
  if (const {'psp', 'dreamcast', 'ps2', 'gamecube', 'wii'}.contains(system)) {
    final s = d * 0.45;
    items.add(
      SkinItem(
        kind: SkinItemKind.thumbstick,
        frame: Rect.fromCenter(
          center: portrait
              ? dpadAt + Offset(-d * 0.1, d * 0.75)
              : dpadAt + Offset(d * 0.75, d * 0.45),
          width: s,
          height: s,
        ),
        inputs: const ['leftstick'],
      ),
    );
  }

  final f = d * 0.42;
  for (final (input, label, dx, dy) in _faceButtons(system)) {
    items.add(
      SkinItem(
        kind: SkinItemKind.button,
        frame: Rect.fromCenter(
          center: faceAt + Offset(dx * f, dy * f),
          width: f,
          height: f,
        ),
        inputs: [input],
        label: label,
        extended: EdgeInsets.all(f * 0.12),
      ),
    );
  }

  // Shoulders at the top corners of the controls area.
  final shoulderW = math.min(w * 0.22, 140.0),
      shoulderH = math.max(28.0, f * 0.55);
  final shoulderY = controlsTop + 10;
  if (_hasShoulders(system)) {
    final two = _hasSecondShoulders(system);
    // With L2/R2, each side gets two half-width buttons: outer L2/R2, inner L1/R1.
    final bw = two ? (shoulderW - 6) / 2 : shoulderW;
    void add(double x, String input, String label) => items.add(
      SkinItem(
        kind: SkinItemKind.button,
        frame: Rect.fromLTWH(x, shoulderY, bw, shoulderH),
        inputs: [input],
        label: label,
      ),
    );
    if (system == 'gamecube') {
      add(12, 'l2', 'L');
      add(w - 12 - 2 * bw - 6, 'r', 'Z');
      add(w - 12 - bw, 'r2', 'R');
    } else if (system == 'wii') {
      add(12, 'l', '−');
      add(w - 12 - bw, 'r', '+');
    } else if (two) {
      add(12, 'l2', 'L2');
      add(12 + bw + 6, 'l', 'L1');
      add(w - 12 - 2 * bw - 6, 'r', 'R1');
      add(w - 12 - bw, 'r2', 'R2');
    } else if (_shouldersOnL2(system)) {
      add(12, 'l2', system == 'dreamcast' ? 'LT' : 'L');
      add(w - 12 - bw, 'r2', system == 'dreamcast' ? 'RT' : 'R');
    } else {
      add(12, 'l', 'L');
      add(w - 12 - bw, 'r', 'R');
    }
  }

  // Select / Start below the clusters (portrait) or in the bottom corners.
  final pillW = math.min(76.0, w * 0.16), pillH = 26.0;
  final pillY = portrait ? h - pillH - 18 : h - pillH - 12;
  final selectX = portrait ? w / 2 - pillW - 10 : 12.0;
  final startX = portrait ? w / 2 + 10 : w - 12 - pillW;
  // PICO-8 has no Select; its Start is the cart's pause menu.
  if (system != 'pico8') {
    items.add(
      SkinItem(
        kind: SkinItemKind.button,
        frame: Rect.fromLTWH(selectX, pillY, pillW, pillH),
        inputs: const ['select'],
        label: system == 'genesis' ? 'Mode' : 'Select',
      ),
    );
  }
  items.add(
    SkinItem(
      kind: SkinItemKind.button,
      frame: Rect.fromLTWH(startX, pillY, pillW, pillH),
      inputs: const ['start'],
      label: system == 'pico8' ? 'Pause' : 'Start',
    ),
  );

  // Menu: top centre of the controls area.
  const m = 36.0;
  items.add(
    SkinItem(
      kind: SkinItemKind.menu,
      frame: Rect.fromLTWH(w / 2 - m / 2, controlsTop + 8, m, m),
      label: 'Menu',
      extended: const EdgeInsets.all(4),
    ),
  );

  return SkinLayout(
    mappingSize: size,
    items: items,
    screen: screen,
    translucent: !portrait,
  );
}

/// N64 (n64.md): analog stick instead of a D-pad; A and B, four C-buttons
/// (right-stick tilts), Z, L, R and Start. Mupen64Plus-Next reads A as
/// RetroPad B, B as Y and Z as L2.
SkinLayout _n64Skin(Size size, double aspect, Rect? fold) {
  final w = size.width, h = size.height;
  final portrait = fold != null || h - w / aspect >= h * 0.3;
  late final Rect screen;
  late final double d;
  late final Offset stickAt, faceAt;
  late final double controlsTop;
  if (portrait) {
    final maxH = fold?.top ?? h * 0.55;
    final sh = math.min(w / aspect, maxH);
    screen = Rect.fromLTWH(
      (w - sh * aspect) / 2,
      fold == null ? 0 : (maxH - sh) / 2,
      sh * aspect,
      sh,
    );
    controlsTop = fold?.bottom ?? sh;
    final rh = h - controlsTop;
    d = math.min(math.min(w * 0.36, rh * 0.5), maxControlSize);
    stickAt = Offset(w * 0.25, controlsTop + rh * 0.5);
    faceAt = Offset(w * 0.73, controlsTop + rh * 0.5);
  } else {
    final sw = math.min(w, h * aspect);
    screen = Rect.fromLTWH(
      (w - sw) / 2,
      (h - sw / aspect) / 2,
      sw,
      sw / aspect,
    );
    controlsTop = 0;
    d = math.min(math.min(h * 0.34, w * 0.2), maxControlSize);
    stickAt = Offset(math.max(d * 0.7, w * 0.11), h * 0.62);
    faceAt = Offset(w - math.max(d * 0.7, w * 0.11), h * 0.62);
  }
  final items = <SkinItem>[
    SkinItem(
      kind: SkinItemKind.thumbstick,
      frame: Rect.fromCenter(center: stickAt, width: d, height: d),
      inputs: const ['leftstick'],
      // Generous, so a drag past the ring keeps steering.
      extended: EdgeInsets.all(d * 0.5),
    ),
  ];
  final f = d * 0.4, c = d * 0.28;
  void button(Offset at, double size, String input, String label) => items.add(
    SkinItem(
      kind: SkinItemKind.button,
      frame: Rect.fromCenter(center: at, width: size, height: size),
      inputs: [input],
      label: label,
      extended: EdgeInsets.all(size * 0.1),
    ),
  );
  button(faceAt + Offset(-f * 0.55, f * 0.75), f, 'b', 'A');
  button(faceAt + Offset(-f * 1.45, f * 0.05), f, 'y', 'B');
  final cAt = faceAt + Offset(f * 0.75, -f * 0.6);
  button(cAt + Offset(0, -c), c, 'cup', '▲');
  button(cAt + Offset(0, c), c, 'cdown', '▼');
  button(cAt + Offset(-c, 0), c, 'cleft', '◀');
  button(cAt + Offset(c, 0), c, 'cright', '▶');

  final shoulderW = math.min(w * 0.22, 140.0),
      shoulderH = math.max(28.0, f * 0.55);
  final y = controlsTop + 10;
  void pill(Rect r, String input, String label) => items.add(
    SkinItem(
      kind: SkinItemKind.button,
      frame: r,
      inputs: [input],
      label: label,
    ),
  );
  pill(Rect.fromLTWH(12, y, shoulderW, shoulderH), 'l', 'L');
  pill(Rect.fromLTWH(w - 12 - shoulderW, y, shoulderW, shoulderH), 'r', 'R');
  // Z sits under L, where the N64's trigger is reached from the left grip.
  pill(
    Rect.fromLTWH(12, y + shoulderH + 8, shoulderW * 0.7, shoulderH),
    'l2',
    'Z',
  );
  const pillW = 76.0, pillH = 26.0;
  pill(
    Rect.fromLTWH(
      w / 2 - pillW / 2,
      portrait ? h - pillH - 18 : h - pillH - 12,
      pillW,
      pillH,
    ),
    'start',
    'Start',
  );
  const m = 36.0;
  items.add(
    SkinItem(
      kind: SkinItemKind.menu,
      frame: Rect.fromLTWH(w / 2 - m / 2, controlsTop + 8, m, m),
      label: 'Menu',
      extended: const EdgeInsets.all(4),
    ),
  );
  return SkinLayout(
    mappingSize: size,
    items: items,
    screen: screen,
    translucent: !portrait,
  );
}
