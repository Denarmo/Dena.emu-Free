import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/skins/builtin_skins.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:dena_emu/src/skins/touch_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/screen_matrix.dart';

int bit(int b) => 1 << b;

const layout = SkinLayout(
  mappingSize: Size(400, 300),
  screen: Rect.fromLTWH(0, 0, 400, 150),
  items: [
    SkinItem(kind: SkinItemKind.dpad, frame: Rect.fromLTWH(20, 170, 100, 100)),
    SkinItem(
      kind: SkinItemKind.button,
      frame: Rect.fromLTWH(300, 200, 40, 40),
      inputs: ['a'],
    ),
    SkinItem(
      kind: SkinItemKind.button,
      frame: Rect.fromLTWH(250, 200, 40, 40),
      inputs: ['b'],
    ),
    SkinItem(
      kind: SkinItemKind.button,
      frame: Rect.fromLTWH(270, 250, 40, 20),
      inputs: ['a', 'b'],
    ),
    SkinItem(kind: SkinItemKind.menu, frame: Rect.fromLTWH(180, 160, 30, 30)),
  ],
);

void main() {
  group('hit testing', () {
    test('frames, extended edges and nearest centre', () {
      expect(hitItem(layout, const Offset(320, 220)), 1);
      // In both extended areas (8 px), outside both frames: nearest wins.
      expect(hitItem(layout, const Offset(296, 220)), 1);
      expect(hitItem(layout, const Offset(293, 220)), 2);
      expect(hitItem(layout, const Offset(200, 120)), isNull);
    });

    test('D-pad: 8 directions and a dead zone', () {
      const f = Rect.fromLTWH(0, 0, 100, 100);
      expect(dpadBits(f, const Offset(50, 50)), 0);
      expect(dpadBits(f, const Offset(55, 52)), 0);
      expect(dpadBits(f, const Offset(50, 5)), bit(RetroPad.up));
      expect(dpadBits(f, const Offset(95, 50)), bit(RetroPad.right));
      expect(dpadBits(f, const Offset(50, 95)), bit(RetroPad.down));
      expect(dpadBits(f, const Offset(5, 50)), bit(RetroPad.left));
      expect(
        dpadBits(f, const Offset(90, 10)),
        bit(RetroPad.up) | bit(RetroPad.right),
      );
      expect(
        dpadBits(f, const Offset(10, 90)),
        bit(RetroPad.down) | bit(RetroPad.left),
      );
    });

    test('multi-touch combines; combos press several; menu is reported', () {
      final s = touchState(layout, {
        1: const Offset(70, 175), // D-pad up
        2: const Offset(320, 220), // A
      });
      expect(s.mask, bit(RetroPad.up) | bit(RetroPad.a));
      expect(s.menu, isFalse);
      final combo = touchState(layout, {3: const Offset(290, 260)});
      expect(combo.mask, bit(RetroPad.a) | bit(RetroPad.b));
      expect(touchState(layout, {4: const Offset(195, 175)}).menu, isTrue);
      expect(touchState(layout, {}).mask, 0);
    });
  });

  group('built-in skins', () {
    test('every system gets a D-pad, Start, Select and menu', () {
      for (final system in ['nes', 'snes', 'gb', 'gbc', 'gba', 'nds']) {
        final l = builtinSkin(system, const Size(412, 915), 4 / 3);
        final inputs = l.items.expand((i) => i.inputs).toSet();
        expect(l.items.where((i) => i.kind == SkinItemKind.dpad), hasLength(1));
        expect(l.items.where((i) => i.kind == SkinItemKind.menu), hasLength(1));
        expect(inputs, containsAll(['start', 'select']), reason: system);
      }
      final snes = builtinSkin('snes', const Size(412, 915), 4 / 3);
      expect(
        snes.items.expand((i) => i.inputs).toSet(),
        containsAll(['a', 'b', 'x', 'y', 'l', 'r']),
      );
      final psx = builtinSkin('psx', const Size(412, 915), 4 / 3);
      expect(
        psx.items.expand((i) => i.inputs).toSet(),
        containsAll(['a', 'b', 'x', 'y', 'l', 'r', 'l2', 'r2']),
      );
      final n64 = builtinSkin('n64', const Size(412, 915), 4 / 3);
      expect(
        n64.items.expand((i) => i.inputs).toSet(),
        containsAll(['b', 'y', 'l', 'r', 'l2', 'cup', 'cdown', 'leftstick']),
      );
    });

    test('a touch stick tilts with a dead zone and C buttons tilt the right '
        'stick', () {
      final frame = const Rect.fromLTWH(0, 0, 100, 100);
      expect(stickTilt(frame, const Offset(52, 50)), Offset.zero);
      final full = stickTilt(frame, const Offset(150, 50));
      expect(full.dx, closeTo(1, 1e-9));
      expect(full.dy, 0);
      final half = stickTilt(frame, const Offset(75, 50));
      expect(half.dx, inInclusiveRange(0.3, 0.5));
      final l = builtinSkin('n64', const Size(412, 915), 4 / 3);
      final stick = l.items.firstWhere(
        (i) => i.kind == SkinItemKind.thumbstick,
      );
      final down = touchState(l, {1: stick.frame.center});
      final s = touchState(l, {
        1: stick.frame.center + const Offset(0, -200),
      }, previous: down);
      expect(s.analog[0]!.dy, closeTo(-1, 1e-9));
      expect(s.mask, 0);
      final cup = l.items.firstWhere((i) => i.inputs.contains('cup'));
      final c = touchState(l, {2: cup.frame.center});
      expect(c.analog[1], const Offset(0, -1));
    });

    test('tabletop: picture above the fold, controls below', () {
      const fold = Rect.fromLTWH(0, 440, 1080, 20);
      for (final system in ['gba', 'psx', 'n64']) {
        final l = builtinSkin(system, const Size(1080, 900), 3 / 2, fold: fold);
        expect(l.screen.bottom, lessThanOrEqualTo(fold.top), reason: system);
        expect(l.translucent, isFalse, reason: system);
        for (final i in l.items) {
          expect(
            i.frame.top,
            greaterThanOrEqualTo(fold.bottom),
            reason: system,
          );
          expect(
            i.frame.width,
            lessThanOrEqualTo(maxControlSize),
            reason: system,
          );
        }
      }
    });

    test('tablets cap the D-pad size', () {
      final l = builtinSkin('snes', const Size(1280, 800), 4 / 3);
      final dpad = l.items.firstWhere((i) => i.kind == SkinItemKind.dpad);
      expect(dpad.frame.width, maxControlSize);
    });

    test('only a horizontal half-open fold or a hinge is tabletop', () {
      const bounds = Rect.fromLTWH(0, 400, 800, 0);
      DisplayFeature f(
        DisplayFeatureType type,
        DisplayFeatureState state, [
        Rect b = bounds,
      ]) => DisplayFeature(bounds: b, type: type, state: state);
      expect(
        tabletopFold([
          f(DisplayFeatureType.fold, DisplayFeatureState.postureHalfOpened),
        ]),
        bounds,
      );
      expect(
        tabletopFold([
          f(DisplayFeatureType.fold, DisplayFeatureState.postureFlat),
        ]),
        isNull,
      );
      expect(
        tabletopFold([
          f(
            DisplayFeatureType.fold,
            DisplayFeatureState.postureHalfOpened,
            const Rect.fromLTWH(400, 0, 0, 800),
          ),
        ]),
        isNull,
      );
      const hinge = Rect.fromLTWH(0, 400, 800, 30);
      expect(
        tabletopFold([
          f(DisplayFeatureType.hinge, DisplayFeatureState.unknown, hinge),
        ]),
        hinge,
      );
      expect(tabletopFold(const []), isNull);
    });

    test('portrait puts the game on top; landscape overlays', () {
      final p = builtinSkin('gba', const Size(412, 915), 3 / 2);
      expect(p.screen.top, 0);
      expect(p.translucent, isFalse);
      final l = builtinSkin('gba', const Size(915, 412), 3 / 2);
      expect(l.translucent, isTrue);
      expect(l.screen.height, 412);
    });

    for (final (system, aspect) in [
      ('nes', 4 / 3),
      ('snes', 4 / 3),
      ('gb', 10 / 9),
      ('gba', 3 / 2),
      ('nds', 256 / 384),
      ('psx', 4 / 3),
      ('n64', 4 / 3),
      ('psp', 480 / 272),
      ('pico8', 1.0),
    ]) {
      testScreens('$system built-in skin', (tester, screen, mode) async {
        await tester.pumpWidget(
          DenaApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: LayoutBuilder(
                builder: (context, box) {
                  final l = builtinSkin(system, box.biggest, aspect);
                  return Stack(
                    children: [
                      Positioned.fromRect(
                        rect: l.screen,
                        child: const ColoredBox(color: Color(0xff3a7d6b)),
                      ),
                      Positioned.fill(
                        child: TouchControls(
                          layout: l,
                          onMask: (_) {},
                          onMenu: () {},
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await expectLater(
          find.byType(DenaApp),
          matchesGoldenFile(goldenName('skin_$system', screen, mode)),
        );
      }, modes: const [InputMode.touch]);
    }

    testWidgets('a stretched copy of the art fills small bars only', (
      tester,
    ) async {
      Future<int> arts(double width) async {
        await tester.pumpWidget(
          DenaApp(
            home: Center(
              child: SizedBox(
                width: width,
                height: 300,
                child: SkinView(
                  layout: layout,
                  game: const SizedBox(),
                  artwork: const ColoredBox(
                    key: ValueKey('art'),
                    color: Color(0xff336699),
                  ),
                  paintItems: false,
                  onMask: (_) {},
                  onMenu: () {},
                ),
              ),
            ),
          ),
        );
        return find.byKey(const ValueKey('art')).evaluate().length;
      }

      final w = layout.mappingSize.width / layout.mappingSize.height * 300;
      expect(await arts(w), 1);
      expect(await arts(w * 1.1), 2);
      expect(await arts(w * 1.5), 1);
    });

    testWidgets('pressed keys of a skin with its own art sink into it', (
      tester,
    ) async {
      await tester.pumpWidget(
        DenaApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: TouchControls(
                layout: layout,
                onMask: (_) {},
                onMenu: () {},
                paintItems: false,
                art: const ColoredBox(
                  key: ValueKey('art'),
                  color: Color(0xff336699),
                ),
              ),
            ),
          ),
        ),
      );
      final art = find.byKey(const ValueKey('art'));
      expect(art, findsNothing);
      final origin = tester.getTopLeft(find.byType(TouchControls));
      final g = await tester.startGesture(origin + const Offset(320, 220));
      await tester.pump();
      // One sunk copy of the art: smaller, lower and darker than the key.
      expect(art, findsOneWidget);
      expect(
        find.ancestor(of: art, matching: find.byType(ColorFiltered)),
        findsOneWidget,
      );
      final scales = tester
          .widgetList<Transform>(
            find.ancestor(of: art, matching: find.byType(Transform)),
          )
          .map((t) => t.transform.storage[0]);
      expect(scales, contains(lessThan(1)));
      await g.up();
      await tester.pumpAndSettle();
      expect(art, findsNothing);
    });

    test('the D-pad rocks as one piece towards the held direction', () {
      const f = Rect.fromLTWH(0, 0, 90, 90);
      // How far a point of the pad ends up from the pivot, on screen.
      double reach(KeyPose pose, Offset p) {
        final m = dpadTransform(f, pose);
        final s = m.storage;
        final w = s[3] * p.dx + s[7] * p.dy + s[15];
        final x = (s[0] * p.dx + s[4] * p.dy + s[12]) / w;
        final y = (s[1] * p.dx + s[5] * p.dy + s[13]) / w;
        return (Offset(x, y) - f.center).distance;
      }

      const top = Offset(45, 0), bottom = Offset(45, 90);
      const left = Offset(0, 45), right = Offset(90, 45);
      const rest = (press: 0.0, tilt: Offset.zero);
      expect(reach(rest, top), closeTo(45, 0.01));
      // Up: the top arm goes down (smaller), the bottom one comes up.
      const up = (press: 1.0, tilt: Offset(0, -1));
      expect(reach(up, top), lessThan(reach(rest, top) - 2));
      expect(reach(up, bottom), greaterThan(reach(up, top) + 2));
      const r = (press: 1.0, tilt: Offset(1, 0));
      expect(reach(r, right), lessThan(reach(r, left) - 2));
      // A diagonal rocks towards its corner.
      const d = (press: 1.0, tilt: Offset(0.7071, 0.7071));
      expect(
        reach(d, const Offset(90, 90)),
        lessThan(reach(d, Offset.zero) - 2),
      );
    });

    testWidgets('keys travel down and spring back up', (tester) async {
      await tester.pumpWidget(
        DenaApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: TouchControls(
                layout: layout,
                onMask: (_) {},
                onMenu: () {},
                paintItems: false,
                art: const ColoredBox(
                  key: ValueKey('art'),
                  color: Color(0xff336699),
                ),
              ),
            ),
          ),
        ),
      );
      final art = find.byKey(const ValueKey('art'));
      final origin = tester.getTopLeft(find.byType(TouchControls));
      // Up on the D-pad: one rocked copy of the whole cross, in perspective.
      final g = await tester.startGesture(origin + const Offset(70, 175));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(art, findsOneWidget);
      final m = tester
          .widget<Transform>(
            find.ancestor(of: art, matching: find.byType(Transform)).first,
          )
          .transform;
      expect(m.storage[11], isNot(0)); // perspective
      await g.up();
      await tester.pump();
      // Still coming back up, then gone.
      expect(art, findsOneWidget);
      await tester.pumpAndSettle();
      expect(art, findsNothing);
    });

    testWidgets('touching the controls reports masks and the menu', (
      tester,
    ) async {
      final masks = <int>[];
      var menus = 0;
      await tester.pumpWidget(
        DenaApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: TouchControls(
                layout: layout,
                onMask: masks.add,
                onMenu: () => menus++,
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(TouchControls));
      final g = await tester.startGesture(origin + const Offset(320, 220));
      // Input goes out on touch-down, before any frame of the key's travel.
      expect(masks.last, bit(RetroPad.a));
      await tester.pump();
      await g.moveTo(origin + const Offset(270, 220));
      await tester.pump();
      expect(masks.last, bit(RetroPad.b));
      await g.up();
      await tester.pump();
      expect(masks.last, 0);
      await tester.tapAt(origin + const Offset(195, 175));
      await tester.pump();
      expect(menus, 1);
    });
  });
}
