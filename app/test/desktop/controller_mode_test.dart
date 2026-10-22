// Spec: docs/specs/controller-mode.md (Controller mode, Glyphs)
import 'package:dena_emu/src/desktop/controller_mode.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a pad turns controller mode on; a click only without pads', () {
    final mode = ControllerMode();
    var changes = 0;
    mode.addListener(() => changes++);
    mode.padUsed(PadFamily.playStation);
    expect(mode.active, isTrue);
    expect(mode.family, PadFamily.playStation);
    mode.mouseUsed(padsConnected: 1);
    expect(mode.active, isTrue);
    mode.mouseUsed(padsConnected: 0);
    expect(mode.active, isFalse);
    mode.padConnected();
    expect(mode.active, isTrue);
    expect(changes, 3);
  });

  test('the Deck keeps controller mode and prints its own glyphs', () {
    final mode = ControllerMode(
      active: true,
      family: PadFamily.xbox,
      steamDeck: true,
    );
    expect(mode.family, PadFamily.steamDeck);
    mode.mouseUsed(padsConnected: 0);
    expect(mode.active, isTrue);
    mode.padUsed(PadFamily.playStation); // a DualSense plugged into the Deck
    expect(mode.family, PadFamily.playStation);
  });

  test('host families', () {
    expect(PadFamily.fromHost(-1), PadFamily.generic);
    expect(PadFamily.fromHost(1), PadFamily.xbox);
    expect(PadFamily.fromHost(4), PadFamily.steamDeck);
    expect(PadFamily.fromHost(99), PadFamily.generic);
  });

  test('hint glyphs follow the pad', () {
    expect(HintButton.a.glyphFor(PadFamily.generic), 'A');
    expect(HintButton.a.glyphFor(PadFamily.playStation), '✕');
    expect(HintButton.b.glyphFor(PadFamily.playStation), '○');
    expect(HintButton.l1.glyphFor(PadFamily.xbox), 'LB');
    expect(HintButton.r1.glyphFor(PadFamily.nintendo), 'R');
    expect(HintButton.l1.glyphFor(PadFamily.steamDeck), 'L1');
    expect(HintButton.start.glyphFor(PadFamily.steamDeck), 'MENU');
    expect(HintButton.y.glyphFor(PadFamily.xbox), 'Y');
  });
}
