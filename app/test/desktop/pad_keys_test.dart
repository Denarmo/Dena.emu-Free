// Spec: docs/specs/controller-mode.md (Buttons)
import 'dart:ui' as ui;

import 'package:dena_emu/src/desktop/pad_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actions map to the handheld embedder keys', () {
    expect(padActionKey(8), LogicalKeyboardKey.gameButtonA);
    expect(padActionKey(0), LogicalKeyboardKey.gameButtonB);
    expect(padActionKey(4), LogicalKeyboardKey.arrowUp);
    expect(padActionKey(10), LogicalKeyboardKey.gameButtonLeft1);
    expect(padActionKey(16), LogicalKeyboardKey.gameButtonMode);
    expect(padActionKey(17), isNull);
    // Same physical ids as shells/linux/include/dena/embedder_core.h.
    expect(
      padPhysicalKey(LogicalKeyboardKey.gameButtonA).usbHidUsage,
      0x0005ff11,
    );
    expect(
      padPhysicalKey(LogicalKeyboardKey.arrowUp),
      PhysicalKeyboardKey.arrowUp,
    );
  });

  testWidgets('held directions repeat after 400 ms, then every 80 ms', (
    tester,
  ) async {
    final sent = <ui.KeyData>[];
    final synth = PadKeySynth(sink: sent.add, clock: () => Duration.zero);
    synth.action(5, true);
    expect(sent.single.type, ui.KeyEventType.down);
    expect(sent.single.logical, LogicalKeyboardKey.arrowDown.keyId);
    expect(sent.single.synthesized, isTrue);
    await tester.pump(const Duration(milliseconds: 399));
    expect(sent, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, hasLength(2));
    expect(sent.last.type, ui.KeyEventType.repeat);
    await tester.pump(const Duration(milliseconds: 160));
    expect(sent, hasLength(4));
    synth.action(5, false);
    expect(sent.last.type, ui.KeyEventType.up);
    await tester.pump(const Duration(seconds: 1));
    expect(sent, hasLength(5));
    synth.dispose();
  });

  testWidgets('buttons do not repeat; stray releases are dropped; a second '
      'press lets go first', (tester) async {
    final sent = <ui.KeyData>[];
    final synth = PadKeySynth(sink: sent.add, clock: () => Duration.zero);
    synth.action(8, false); // the press went to the game
    expect(sent, isEmpty);
    synth.action(8, true);
    await tester.pump(const Duration(seconds: 1));
    expect(sent.map((d) => d.type), [ui.KeyEventType.down]);
    synth.action(8, true); // its release went to the game
    expect(sent.map((d) => d.type), [
      ui.KeyEventType.down,
      ui.KeyEventType.up,
      ui.KeyEventType.down,
    ]);
    synth.releaseAll();
    expect(sent.last.type, ui.KeyEventType.up);
    synth.dispose();
  });
}
