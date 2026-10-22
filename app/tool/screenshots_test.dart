// Renders the current screens with real fonts (IBM Plex Mono, Archivo Black and Dena Icons from the
// app, Roboto + Material Icons from the
// Flutter SDK) for sharing progress. Not part of CI:
//   flutter test tool/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/spike/spike_screen.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:dena_emu/src/ui/brutal/tokens.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/session_screen_test.dart' show FakeGameApi, sessionApp;
import '../test/spike_screen_test.dart' show FakeSpikeApi;
import '../test/support/library_fixture.dart';

Future<void> loadFont(String family, List<String> files) async {
  final fonts =
      '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter'}'
      '/bin/cache/artifacts/material_fonts';
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      Future.value(ByteData.sublistView(File('$fonts/$f').readAsBytesSync())),
    );
  }
  await loader.load();
}

/// Loads a font bundled with the app (assets/fonts/...).
Future<void> loadAppFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      Future.value(
        ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync()),
      ),
    );
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    await loadAppFont('Roboto', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
        'roboto/Roboto-$w.ttf',
    ]);
    await loadFont('MaterialIcons', ['MaterialIcons-Regular.otf']);
    await loadAppFont('IBM Plex Mono', [
      for (final w in ['Medium', 'SemiBold', 'Bold'])
        'ibm_plex_mono/IBMPlexMono-$w.ttf',
    ]);
    await loadAppFont('Archivo Black', [
      'archivo_black/ArchivoBlack-Regular.ttf',
    ]);
    await loadAppFont('DenaIcons', ['dena_icons/DenaIcons.otf']);
  });

  Future<void> shoot(
    WidgetTester tester,
    Widget app,
    String name, {
    Size size = const Size(412, 915),
    double ratio = 2.625,
    Future<void> Function()? before,
  }) async {
    // flutter_test draws shadows as black outlines unless this is off.
    debugDisableShadows = false;
    tester.view.physicalSize = size * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await before?.call();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/$name.png'),
    );
    debugDisableShadows = true; // the test binding checks it is restored
  }

  const titles = [
    'Moonlight Quest',
    'Pixel Racer DX',
    'Tiny Tactics',
    'Star Courier',
    'Bubble Garden',
    'Cave Runner',
    'Neon Golf',
    'Robo Rally',
  ];

  testWidgets('library on a phone', (tester) async {
    final db = await seededDb(titles);
    await shoot(tester, shellApp(db), 'library_phone');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('library on a 640x480 handheld', (tester) async {
    final db = await seededDb(titles);
    await shoot(
      tester,
      shellApp(db),
      'library_640x480',
      size: const Size(640, 480),
      ratio: 1,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('empty library', (tester) async {
    final db = await seededDb([]);
    await shoot(tester, shellApp(db), 'library_empty_phone');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('latency test screen', (tester) async {
    await shoot(
      tester,
      DenaApp(home: SpikeScreen(api: FakeSpikeApi())),
      'latency_test_phone',
    );
  });

  Future<void> session(
    WidgetTester tester,
    String name, {
    Size size = const Size(412, 915),
    double ratio = 2.625,
    String system = 'gba',
    Future<void> Function()? then,
  }) async {
    final db = await seededDb(['Moonlight Quest']);
    await db.customStatement("UPDATE games SET system = '$system'");
    final game = await db.select(db.games).getSingle();
    await db.addCheat(
      gameId: game.id,
      name: 'Infinite lives',
      code: '82003DF4 0063',
      format: 'CodeBreaker',
      createdAt: DateTime(2026),
    );
    await db.addCheat(
      gameId: game.id,
      name: 'Max money',
      code: '12345678 9ABCDEF0',
      format: 'GameShark / Action Replay',
      createdAt: DateTime(2026),
    );
    await shoot(
      tester,
      sessionApp(db, game, FakeGameApi()),
      name,
      size: size,
      ratio: ratio,
      before: () async {
        await tester.tap(find.text('library'));
        await tester.pumpAndSettle();
        await then?.call();
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  }

  testWidgets('game with touch controls, phone', (tester) async {
    await session(tester, 'game_touch_phone');
  });

  testWidgets('SNES game with touch controls, 640x480', (tester) async {
    await session(
      tester,
      'game_touch_snes_640x480',
      size: const Size(640, 480),
      ratio: 1,
      system: 'snes',
    );
  });

  testWidgets('pause menu, phone', (tester) async {
    await session(
      tester,
      'pause_menu_phone',
      then: () async {
        await systemBack(tester);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('pause menu, 640x480', (tester) async {
    await session(
      tester,
      'pause_menu_640x480',
      size: const Size(640, 480),
      ratio: 1,
      then: () async {
        await systemBack(tester);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('cheats, phone', (tester) async {
    await session(
      tester,
      'cheats_phone',
      then: () async {
        await systemBack(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cheats'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('skins tab, phone', (tester) async {
    final db = await seededDb(titles);
    await shoot(
      tester,
      shellApp(db),
      'skins_tab_phone',
      before: () async {
        await tester.tap(find.text('Skins'));
        await tester.pumpAndSettle();
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  // Theming (theming.md): the settings page and the library in other themes.
  testWidgets('theme settings, phone', (tester) async {
    final db = await seededDb(titles);
    await shoot(
      tester,
      shellApp(db),
      'theme_settings_phone',
      before: () async {
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Theme'));
        await tester.pumpAndSettle();
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  for (final (mode, accent) in [
    (ThemeMode.light, BrutalAccent.hazard),
    (ThemeMode.dark, BrutalAccent.hazard),
    (ThemeMode.dark, BrutalAccent.gold),
  ]) {
    testWidgets('library in ${accent.name} ${mode.name}', (tester) async {
      final db = await seededDb(titles);
      await shoot(
        tester,
        shellApp(
          db,
          theme: ThemeSettings(mode: mode, accent: accent),
        ),
        'library_phone_${accent.name}_${mode.name}',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
    });
  }
}

/// Presses the system back button (the session opens its pause menu).
Future<void> systemBack(WidgetTester tester) =>
    // tool/ isn't test/, so the analyzer doesn't treat this as a test.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    tester.binding.handlePopRoute();
