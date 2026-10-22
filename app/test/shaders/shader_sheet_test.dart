import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/shaders/shader_settings.dart';
import 'package:dena_emu/src/shaders/shader_sheet.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../session_screen_test.dart'
    show tapPauseItem, FakeGameApi, closeDb, firstGame, openPause, sessionApp;
import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

ShaderStore tempStore() {
  final dir = Directory.systemTemp.createTempSync('dena_shader_sheet');
  addTearDown(() => dir.deleteSync(recursive: true));
  return ShaderStore(dir.path);
}

Future<void> openShaders(WidgetTester tester) async {
  await openPause(tester);
  await tapPauseItem(tester, 'SHADER');
}

/// Taps the [name] entry of the open shader sheet, scrolling it into view.
Future<void> pick(WidgetTester tester, String name) async {
  final list = find
      .descendant(
        of: find.byType(ShaderSheet),
        matching: find.byType(Scrollable),
      )
      .last;
  tester.state<ScrollableState>(list).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(name), 50, scrollable: list);
  await tester.ensureVisible(find.text(name));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  testScreens('shader sheet', (tester, screen, mode) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db); // a GBA game
    final store = tempStore()..setSystem('gba', 'lcd-grid');
    await tester.pumpWidget(
      sessionApp(db, game, FakeGameApi(), shaders: store),
    );
    await openShaders(tester);
    expect(find.byType(ShaderSheet), findsOneWidget);
    expect(find.textContaining('ALL GAME BOY ADVANCE GAMES'), findsOneWidget);
    expect(find.text('SUGGESTED'), findsWidgets);
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile(goldenName('shader_sheet', screen, mode)),
    );
    await closeDb(tester, db);
  });

  testWidgets('the saved shader is set before the game starts', (tester) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore()..setSystem('gba', 'lcd3x');
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await tester.tap(find.text('library'));
    await tester.pumpAndSettle();
    expect(api.calls.take(3), [
      'shader lcd3x',
      'latency 40',
      startsWith('start '),
    ]);
    expect(find.text('This shader could not be loaded'), findsNothing);
    await closeDb(tester, db);
  });

  testWidgets('no shader call when the game has none', (tester) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore()
      ..setSystem('gba', 'lcd3x')
      ..setGame(game.sha1, '');
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await tester.tap(find.text('library'));
    await tester.pumpAndSettle();
    expect(api.calls.first, 'latency 40');
    expect(api.calls[1], startsWith('start '));
    expect(api.calls.where((c) => c.startsWith('shader')), isEmpty);
    await closeDb(tester, db);
  });

  testWidgets('a shader that fails at start is reported and is Off', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore()..setSystem('gba', 'crt-geom');
    final api = FakeGameApi(shaderError: 'compile error');
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await tester.tap(find.text('library'));
    await tester.pumpAndSettle();
    expect(api.calls.first, 'shader crt-geom');
    expect(find.text('This shader could not be loaded'), findsOneWidget);
    // The sheet shows Off as current; the saved choice is kept.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tapPauseItem(tester, 'SHADER');
    // Off is the one row marked [x].
    expect(find.text('[x]'), findsOneWidget);
    expect(
      tester.getCenter(find.text('[x]')).dy,
      tester.getCenter(find.text('Off')).dy,
    );
    expect(store.systemDefault('gba'), 'crt-geom');
    await closeDb(tester, db);
  });

  testWidgets('picking previews at once and saves to the chosen scope', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore();
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await openShaders(tester);

    // Default scope: every game of the system.
    await pick(tester, 'Dot matrix');
    expect(api.calls.last, 'shader dot-matrix');
    expect(store.systemDefault('gba'), 'dot-matrix');
    expect(store.hasGameOverride(game.sha1), isFalse);

    // This game only, including Off.
    await tester.tap(find.textContaining('THIS GAME'));
    await tester.pumpAndSettle();
    await pick(tester, 'Off');
    expect(api.calls.last, 'shader ');
    expect(store.resolve('gba', game.sha1), '');
    expect(store.systemDefault('gba'), 'dot-matrix');

    // Back to all games drops the game's own choice.
    await tester.tap(find.textContaining('ALL GAME BOY ADVANCE GAMES'));
    await tester.pumpAndSettle();
    await pick(tester, 'LCD grid');
    expect(store.hasGameOverride(game.sha1), isFalse);
    expect(store.resolve('gba', game.sha1), 'lcd-grid');

    // B returns to the pause sheet.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ShaderSheet), findsNothing);
    expect(find.text('RESUME'), findsOneWidget);
    await closeDb(tester, db);
  });

  testWidgets('a shader failing in the sheet falls back to Off', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore();
    final api = FakeGameApi(shaderError: 'no GLES 3');
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await openShaders(tester);
    await pick(tester, 'CRT (curved)');
    expect(api.calls.last, 'shader crt-geom');
    expect(find.text('This shader could not be loaded'), findsOneWidget);
    expect(store.systemDefault('gba'), '');
    await closeDb(tester, db);
  });

  testWidgets('the shader sheet is D-pad operable', (tester) async {
    // Tall enough that the stack folds nothing under SETTINGS.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final store = tempStore();
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await openPause(tester);
    // Resume → Save → Load → Rewind → Cheats → Shader.
    for (var i = 0; i < 5; i++) {
      await dpad(tester, LogicalKeyboardKey.tab);
    }
    await dpad(tester, LogicalKeyboardKey.enter);
    expect(find.byType(ShaderSheet), findsOneWidget);
    // Off has focus; the next entry is the first suggested shader.
    await dpad(tester, LogicalKeyboardKey.arrowDown);
    await dpad(tester, LogicalKeyboardKey.enter);
    expect(api.calls.last, 'shader sharp-bilinear');
    expect(store.systemDefault('gba'), 'sharp-bilinear');
    await dpad(tester, LogicalKeyboardKey.escape);
    expect(find.byType(ShaderSheet), findsNothing);
    expect(find.text('RESUME'), findsOneWidget);
    await closeDb(tester, db);
  });

  testScreens('shader settings', (tester, screen, mode) async {
    final db = await seededDb([]);
    final store = tempStore()
      ..setSystem('nes', 'crt-geom')
      ..setSystem('gb', 'dot-matrix');
    await tester.pumpWidget(shellApp(db, shaders: store));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(
      find.text('SHADERS'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    // Bring the row clear of the handheld hint bar at the bottom.
    await tester.ensureVisible(find.text('SHADERS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SHADERS'));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderSettingsPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(CfgRow, 'NES'),
        matching: find.text('CRT (curved) >'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(CfgRow, 'GAME BOY'),
        matching: find.text('Dot matrix >'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(CfgRow, 'SNES'),
        matching: find.text('Off >'),
      ),
      findsOneWidget,
    );
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile(goldenName('shader_settings', screen, mode)),
    );

    // A system opens the list in system scope; a pick updates the row.
    await tester.tap(find.text('SNES'));
    await tester.pumpAndSettle();
    expect(find.text('SNES shader and resolution'), findsOneWidget);
    expect(find.textContaining('THIS GAME'), findsNothing);
    await pick(tester, 'Scanlines');
    expect(store.systemDefault('snes'), 'scanlines');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(CfgRow, 'SNES'),
        matching: find.text('Scanlines >'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  testWidgets('resolution: unsupported factors are disabled with a note', (
    tester,
  ) async {
    final store = tempStore();
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'gba'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Game Boy Advance draws at its native resolution only'),
      findsOneWidget,
    );
    // Factors the core can't do are not offered.
    expect(find.textContaining('2X'), findsNothing);
    expect(store.systemUpscale('gba'), 0);

    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'psx'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('PlayStation renders at 2x at most'), findsOneWidget);
    expect(find.textContaining('4X'), findsNothing);
    expect(store.systemUpscale('psx'), 0);
    await tester.tap(find.textContaining('2X'));
    await tester.pumpAndSettle();
    expect(store.systemUpscale('psx'), 2);

    // GB and GBC go up to 4x through the xBRZ filter.
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'gbc'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Smoothed with the xBRZ pixel-art filter'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('4X'));
    await tester.pumpAndSettle();
    expect(store.systemUpscale('gbc'), 4);

    // DS renders 3D at true 2x-4x on OpenGL ES 3.2.
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'nds'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('True 3D resolution, needs OpenGL ES 3.2'),
      findsOneWidget,
    );
    expect(find.text('Smoothed with the xBRZ pixel-art filter'), findsNothing);
    await tester.tap(find.textContaining('3X'));
    await tester.pumpAndSettle();
    expect(store.systemUpscale('nds'), 3);
  });

  testWidgets('in a game the factor saves per scope and starts the core', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    await tester.runAsync(
      () => db.addGame(
        system: 'n64',
        title: 'Kart',
        fileName: 'Kart.z64',
        path: '/nowhere/n64',
        sha1: 'shaN64',
        size: 1,
        crc32: '0',
        addedAt: DateTime(2026, 2, 1),
      ),
    );
    final game = (await tester.runAsync(
      (db.select(db.games)..where((g) => g.system.equals('n64'))).getSingle,
    ))!;
    final store = tempStore()..setSystemUpscale('n64', 2);
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await openShaders(tester);
    expect(api.upscale, 2); // the system default, set before start
    await tester.tap(find.textContaining('THIS GAME'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('4X'));
    await tester.pumpAndSettle();
    expect(
      find.text('The new resolution applies the next time the game starts'),
      findsOneWidget,
    );
    expect(store.resolveUpscale('n64', game.sha1), 4);
    expect(store.systemUpscale('n64'), 2);
    await closeDb(tester, db);
  });

  testWidgets('desktop: 8x and the widescreen row', (tester) async {
    final dir = Directory.systemTemp.createTempSync('dena_shader_sheet');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ShaderStore(dir.path, desktop: true);
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'n64'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final f in ['2X', '3X', '4X', '6X', '8X']) {
      expect(find.textContaining(f), findsOneWidget, reason: f);
    }
    await tester.tap(find.textContaining('8X'));
    await tester.pumpAndSettle();
    expect(store.systemUpscale('n64'), 8);
    expect(find.text('Above 4x needs a strong graphics card'), findsOneWidget);
    expect(
      find.text('Widescreen hack: 3D games only, 2D art stretches'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('16:9'));
    await tester.pumpAndSettle();
    expect(store.systemWidescreen('n64'), isTrue);

    // PSX: Beetle PSX HW's 2x, 4x, 8x. DS has no widescreen hack.
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'psx'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('3X'), findsNothing);
    expect(find.textContaining('8X'), findsOneWidget);
    expect(find.textContaining('16:9'), findsOneWidget);
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'nds'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('8X'), findsOneWidget);
    expect(find.textContaining('16:9'), findsNothing);
    expect(find.textContaining('OpenGL ES'), findsNothing);
    // GB stays native on the desktop.
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'gb'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Game Boy draws at its native resolution only'),
      findsOneWidget,
    );
  });

  testWidgets('desktop: slang stacks and pass counts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('dena_shader_sheet');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ShaderStore(dir.path, desktop: true);
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'psx'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CRT (bloom)'), findsNothing); // the phone's own
    await pick(tester, 'CRT-Royale');
    expect(store.systemDefault('psx'), 'crt-royale');
    expect(find.textContaining('12 passes'), findsWidgets);
    await expectLater(
      find.byType(ShaderSheet),
      matchesGoldenFile('goldens/shader_sheet_desktop_1280x720.png'),
    );
  });

  testWidgets('phone: no widescreen row', (tester) async {
    final store = tempStore();
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: ShaderSheet(store: store, system: 'n64'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('16:9'), findsNothing);
    expect(find.textContaining('8X'), findsNothing);
  });

  testWidgets('desktop session sends widescreen before start, draws 16:9', (
    tester,
  ) async {
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    await tester.runAsync(
      () => db.addGame(
        system: 'n64',
        title: 'Kart',
        fileName: 'Kart.z64',
        path: '/nowhere/n64',
        sha1: 'shaN64',
        size: 1,
        crc32: '0',
        addedAt: DateTime(2026, 2, 1),
      ),
    );
    final game = (await tester.runAsync(
      (db.select(db.games)..where((g) => g.system.equals('n64'))).getSingle,
    ))!;
    final dir = Directory.systemTemp.createTempSync('dena_shader_sheet');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ShaderStore(dir.path, desktop: true)
      ..setSystemUpscale('n64', 8)
      ..setSystemWidescreen('n64', true);
    final api = FakeGameApi();
    await tester.pumpWidget(sessionApp(db, game, api, shaders: store));
    await openShaders(tester);
    expect(api.upscale, 8);
    expect(api.widescreen, isTrue);
    expect(api.calls, contains('aspect 1.778'));
    await tester.tap(find.textContaining('THIS GAME'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('OFF'));
    await tester.pumpAndSettle();
    expect(
      find.text('Widescreen applies the next time the game starts'),
      findsOneWidget,
    );
    expect(store.resolveWidescreen('n64', game.sha1), isFalse);
    expect(store.systemWidescreen('n64'), isTrue);
    await closeDb(tester, db);
  });
}
