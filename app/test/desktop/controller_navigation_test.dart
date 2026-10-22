// The desktop app driven by a gamepad: launch rule, synthesized keys through
// the framework, hint bar glyphs, TV layout, leaving controller mode.
// Spec: docs/specs/controller-mode.md
import 'dart:io';

import 'package:dena_emu/src/desktop/desktop_startup.dart';
import 'package:dena_emu/src/desktop/launch_rule.dart';
import 'package:dena_emu/src/desktop/window_control.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/handheld_navigation_test.dart' show focusedTexts, settle;
import '../support/library_fixture.dart';
import 'fake_pads.dart';

const _window = MethodChannel('dena/window');

void main() {
  late Directory data;
  late List<MethodCall> calls;

  setUp(() {
    data = Directory.systemTemp.createTempSync('dena_desktop');
    calls = [];
    played = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, (call) async {
          calls.add(call);
          return call.method == 'isFullscreen' ? false : null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, null);
    data.deleteSync(recursive: true);
  });

  Future<DesktopShell> launch(FakePads pads) async {
    final shell = await DesktopShell.start(
      dataDir: data,
      pads: pads,
      window: const WindowControl(_window),
      steamDeck: false,
    );
    addTearDown(shell.dispose);
    return shell;
  }

  test('a pad at launch: back on the last monitor, then fullscreen', () async {
    await launch(FakePads(pads: 1, hostFamily: 2));
    expect(calls.map((c) => c.method), ['restorePlacement', 'setFullscreen']);
    expect(
      calls.first.arguments,
      '${data.path}${Platform.pathSeparator}window.txt',
    );
    expect(calls.last.arguments, isTrue);
  });

  test('no pad: windowed; Always still goes fullscreen', () async {
    final none = await launch(FakePads());
    expect(calls.map((c) => c.method), ['restorePlacement']);
    expect(none.mode.active, isFalse);
    none.display.fullscreenAtLaunch = FullscreenAtLaunch.always;
    calls.clear();
    final again = await launch(FakePads());
    expect(calls.map((c) => c.method), ['restorePlacement', 'setFullscreen']);
    expect(again.mode.active, isFalse);
  });

  testWidgets('the pad drives the library: D-pad moves, A plays, hints and '
      'TV layout; a click with no pad left goes back to the desktop layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final pads = FakePads(pads: 1, hostFamily: 1);
    final shell = (await tester.runAsync(() => launch(pads)))!;
    expect(shell.mode.active, isTrue);
    final db = (await tester.runAsync(
      () => seededDb([for (var i = 0; i < 12; i++) 'Game $i']),
    ))!;
    await tester.pumpWidget(
      DesktopShellScope(shell: shell, child: shellApp(db)),
    );
    await settle(tester);

    // TV layout: 1080p lays out at 1280x720.
    final context = tester.element(find.byType(GamesTab));
    expect(MediaQuery.sizeOf(context), const Size(1280, 720));
    // Xbox glyphs in the hint bar.
    expect(find.byType(HintBar), findsOneWidget);
    expect(find.text('LB'), findsOneWidget);

    expect(focusedTexts(), contains('GAME_0'));
    pads.press(5); // D-pad down: the next table row
    pads.release(5);
    await settle(tester);
    expect(focusedTexts(), contains('GAME_1'));

    // Held down: repeats after 400 ms.
    pads.press(5);
    await tester.pump(const Duration(milliseconds: 600));
    pads.release(5);
    await settle(tester);
    expect(focusedTexts(), isNot(contains('GAME_1')));

    // A PlayStation pad: its glyphs.
    pads.press(4, family: 2);
    pads.release(4, family: 2);
    await settle(tester);
    expect(find.text('✕'), findsOneWidget);

    // A (the button printed A or Cross) plays the focused game.
    pads.press(8, family: 2);
    pads.release(8, family: 2);
    await settle(tester);
    expect(played, hasLength(1));

    // A click with a pad still there stays in controller mode.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(900, 500));
    await gesture.down(const Offset(900, 500));
    await gesture.up();
    await settle(tester);
    expect(find.byType(HintBar), findsOneWidget);

    // Unplugged: the next click leaves it, keeping the screen as it was.
    pads.pads = 0;
    await gesture.down(const Offset(900, 500));
    await gesture.up();
    await settle(tester);
    expect(find.byType(HintBar), findsNothing);
    expect(
      MediaQuery.sizeOf(tester.element(find.byType(GamesTab))),
      const Size(1920, 1080),
    );
    expect(find.text('GAME_0'), findsOneWidget);
    await gesture.removePointer();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('Settings shows Fullscreen at launch on the desktop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = (await tester.runAsync(() => launch(FakePads(pads: 1))))!;
    final db = (await tester.runAsync(() => seededDb(['Game 0'])))!;
    await tester.pumpWidget(
      DesktopShellScope(shell: shell, child: shellApp(db)),
    );
    await settle(tester);
    // R1 three times: Games, Carts, Apps, Settings.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
    }
    expect(find.text('FULLSCREEN AT LAUNCH'), findsOneWidget);
    expect(find.text('[AUTO]'), findsOneWidget);
    await tester.tap(find.text(' ALWAYS '));
    await settle(tester);
    expect(find.text('[ALWAYS]'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('Settings lays out in two columns at 1280x720', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = (await tester.runAsync(() => launch(FakePads(pads: 1))))!;
    final db = (await tester.runAsync(() => seededDb(['Game 0'])))!;
    await tester.pumpWidget(
      DesktopShellScope(shell: shell, child: shellApp(db)),
    );
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
    }
    // Appearance on the left, video (with Presets) on the right.
    expect(find.text('PRESETS'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('VIDEO.CFG')).dx,
      greaterThan(tester.getTopLeft(find.text('APPEARANCE.CFG')).dx),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_desktop_1280x720.png'),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });
}
