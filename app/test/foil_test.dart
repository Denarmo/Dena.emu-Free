// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dena_emu/src/library/foil.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the stripe moves at most 8 px, in whole 2 px steps', () {
    expect(foilShiftFor(Offset.zero), 0);
    expect(foilShiftFor(const Offset(1, 1)), foilMaxShift);
    expect(foilShiftFor(const Offset(-5, -5)), -foilMaxShift);
    for (var x = -1.0; x <= 1.0; x += 0.03) {
      final s = foilShiftFor(Offset(x, 0.2));
      expect(s.abs(), lessThanOrEqualTo(foilMaxShift));
      expect(s % foilShiftStep, 0, reason: 'x=$x');
    }
  });

  test('a tilt within one step does not repaint', () {
    expect(foilShiftFor(const Offset(0.05, 0)), foilShiftFor(Offset.zero));
    expect(
      const FoilStripePainter(shift: 2).shouldRepaint(
        const FoilStripePainter(shift: 2),
      ),
      isFalse,
    );
  });
}
