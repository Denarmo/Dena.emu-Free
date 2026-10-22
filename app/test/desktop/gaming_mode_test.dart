// SteamOS Gaming Mode: gamescope detection, the launch rule under gamescope
// and Steam's keyboard for text fields.
// Spec: docs/specs/deck-presets.md (Gaming Mode)
import 'dart:io';

import 'package:dena_emu/src/desktop/deck_presets.dart';
import 'package:dena_emu/src/desktop/desktop_startup.dart';
import 'package:dena_emu/src/desktop/gaming_mode.dart';
import 'package:dena_emu/src/desktop/launch_rule.dart';
import 'package:dena_emu/src/desktop/window_control.dart';
import 'package:dena_emu/src/ui/onscreen_keyboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_pads.dart';

const _window = MethodChannel('dena/window');

void main() {
  test('gamescope is detected from its environment, on Linux only', () {
    expect(detectGamescope(env: {}, os: 'linux'), isFalse);
    expect(
      detectGamescope(
        env: {'GAMESCOPE_WAYLAND_DISPLAY': 'gamescope-0'},
        os: 'linux',
      ),
      isTrue,
    );
    expect(
      detectGamescope(env: {'XDG_CURRENT_DESKTOP': 'gamescope'}, os: 'linux'),
      isTrue,
    );
    expect(
      detectGamescope(env: {'XDG_CURRENT_DESKTOP': 'KDE'}, os: 'linux'),
      isFalse,
    );
    expect(
      detectGamescope(env: {'GAMESCOPE_WAYLAND_DISPLAY': 'x'}, os: 'windows'),
      isFalse,
    );
  });

  test('under gamescope the launch is fullscreen controller mode', () {
    for (final setting in FullscreenAtLaunch.values) {
      expect(decideLaunch(setting: setting, gamepads: 0, gamescope: true), (
        fullscreen: true,
        controllerMode: true,
      ));
    }
  });

  group('start-up under gamescope', () {
    late Directory data;
    late List<MethodCall> calls;
    setUp(() {
      data = Directory.systemTemp.createTempSync('dena_gamescope');
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_window, (call) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_window, null);
      data.deleteSync(recursive: true);
    });

    test('fullscreen without placing the window, Steam keyboard on; '
        'presets know the Deck', () async {
      final shell = await DesktopShell.start(
        dataDir: data,
        pads: FakePads(),
        window: const WindowControl(_window),
        steamDeck: true,
        deckModel: DeckModel.oled,
        gamescope: true,
        steamKeyboard: SteamKeyboard(run: (_, _) async => 0),
      );
      expect(calls.map((c) => c.method), ['setFullscreen']);
      expect(shell.mode.active, isTrue);
      expect(HandheldTextEntry.external, isNotNull);
      expect(shell.presets.model, DeckModel.oled);
      shell.dispose();
      expect(HandheldTextEntry.external, isNull);
    });

    test(
      'a Deck in Desktop Mode: no Steam keyboard; a PC has no Deck',
      () async {
        final deck = await DesktopShell.start(
          dataDir: data,
          pads: FakePads(),
          window: const WindowControl(_window),
          steamDeck: true,
          deckModel: DeckModel.none,
          gamescope: false,
        );
        expect(calls.first.method, 'restorePlacement');
        expect(HandheldTextEntry.external, isNull);
        // Only SteamDeck=1: counted as an LCD Deck.
        expect(deck.presets.model, DeckModel.lcd);
        deck.dispose();
        final pc = await DesktopShell.start(
          dataDir: data,
          pads: FakePads(),
          window: const WindowControl(_window),
          steamDeck: false,
          gamescope: false,
        );
        expect(pc.presets.model, DeckModel.none);
        pc.dispose();
      },
    );
  });

  group('Steam keyboard', () {
    Future<TextEditingController> field(WidgetTester tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HandheldTextEntry(
            child: Scaffold(
              body: TextField(
                autofocus: true,
                controller: controller,
                decoration: const InputDecoration(labelText: 'Server'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    tearDown(SteamKeyboard.uninstall);

    testWidgets('A on a field asks Steam once, not the app keyboard', (
      tester,
    ) async {
      final runs = <String>[];
      SteamKeyboard(
        run: (exe, args) async {
          runs.add('$exe ${args.join(' ')}');
          return 0;
        },
      ).install();
      await field(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(runs, ['xdg-open steam://open/keyboard']);
      expect(find.byType(OnScreenKeyboard), findsNothing);
    });

    testWidgets('Steam not answering: the app keyboard opens', (tester) async {
      SteamKeyboard(run: (_, _) async => 1).install();
      await field(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(find.byType(OnScreenKeyboard), findsOneWidget);
    });

    testWidgets('outside gamescope the app keyboard opens as before', (
      tester,
    ) async {
      await field(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(find.byType(OnScreenKeyboard), findsOneWidget);
    });
  });
}
