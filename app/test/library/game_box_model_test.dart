// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/game-boxes.md (Acceptance tests)
import 'dart:ui';

import 'package:dena_emu/src/library/game_box_model.dart';
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every system the app knows has its own box', () {
    for (final s in GameSystem.values) {
      expect(boxSpecFor(s.id).id, s.id, reason: s.id);
    }
    expect(boxSpecFor('unknown'), same(genericBoxSpec));
  });

  test('boxes keep their real shapes and materials', () {
    expect(boxSpecFor('snes').aspect, greaterThan(1)); // US carton, landscape
    expect(boxSpecFor('nes').aspect, lessThan(1));
    expect(boxSpecFor('psp').aspect, lessThan(0.65)); // tall UMD case
    expect(boxSpecFor('psx').material, BoxMaterial.jewel);
    expect(boxSpecFor('nds').material, BoxMaterial.plastic);
    expect(boxSpecFor('gb').material, BoxMaterial.cardboard);
    expect(boxSpecFor('pico8').material, BoxMaterial.cart);
    expect(boxSpecFor('psp').media, BoxMedia.umd);
    expect(boxSpecFor('psx').media, BoxMedia.disc);
    expect(boxSpecFor('nds').media, BoxMedia.card);
    expect(boxSpecFor('n64').hinge, BoxHinge.top);
    expect(boxSpecFor('psx').hinge, BoxHinge.left);
  });

  test('a Game Boy box is smaller than an N64 box on the same stage', () {
    const stage = Size(150, 150);
    final gb = boxSizeOn(boxSpecFor('gb'), stage);
    final n64 = boxSizeOn(boxSpecFor('n64'), stage);
    expect(gb.width, lessThan(n64.width));
    expect(gb.height, lessThan(n64.height));
  });

  test('every box fits its stage with its side showing', () {
    const stage = Size(140, 140);
    for (final spec in [...boxSpecs.values, genericBoxSpec]) {
      for (final s in [spec, spec.orientedFor(spec.aspect > 1 ? 0.7 : 1.4)]) {
        final f = boxFootprintOn(s, stage);
        expect(f.width, lessThanOrEqualTo(stage.width + 1e-9), reason: s.id);
        expect(f.height, lessThanOrEqualTo(stage.height + 1e-9), reason: s.id);
      }
    }
  });

  test('regional boxes turn to match a portrait cover', () {
    final us = boxSpecFor('snes');
    final eu = us.orientedFor(0.72);
    expect(eu.aspect, lessThan(1));
    expect(eu.widthMm, us.heightMm);
    expect(us.orientedFor(1.0), same(us)); // near-square keeps the default
    expect(us.orientedFor(null), same(us));
    // Fixed-shape boxes never turn.
    final ds = boxSpecFor('nds');
    expect(ds.orientedFor(1.6), same(ds));
  });

  test('label window and media rect lie inside the front face', () {
    for (final spec in [...boxSpecs.values, genericBoxSpec]) {
      final l = spec.labelRect(spec.frontMm);
      expect(l.left, greaterThanOrEqualTo(0), reason: spec.id);
      expect(l.right, lessThanOrEqualTo(spec.widthMm + 1e-9), reason: spec.id);
      expect(l.bottom, lessThanOrEqualTo(spec.heightMm + 1e-9));
      final m = spec.mediaRect;
      expect(m.left, greaterThanOrEqualTo(-1e-9), reason: spec.id);
      expect(m.right, lessThanOrEqualTo(1 + 1e-9), reason: spec.id);
      expect(m.bottom, lessThanOrEqualTo(1 + 1e-9), reason: spec.id);
    }
  });
}
