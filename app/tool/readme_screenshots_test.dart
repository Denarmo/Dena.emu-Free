// Renders the README screenshots in docs/screenshots with the real fonts.
// Not part of the test suite; regenerate after a visible UI change with
//   cd app && flutter test tool/readme_screenshots_test.dart --update-goldens
// Game titles are made up; no real game names or box art.
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/foil.dart';
import 'package:dena_emu/src/shell/platform_features.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/session_screen_test.dart' show FakeGameApi, sessionApp;
import '../test/support/library_fixture.dart' show shellApp;

const _out = '../../docs/screenshots';

const _games = [
  ('Bubble Garden', 'gba'),
  ('Cave Runner', 'snes'),
  ('Crystal Keep', 'psx'),
  ('Moonlight Quest', 'gba'),
  ('Neon Golf', 'nes'),
  ('Pixel Racer DX', 'snes'),
  ('Pocket Tamer', 'nds'),
  ('Robo Rally', 'gb'),
  ('Sky Drift', 'n64'),
  ('Star Courier', 'gbc'),
  ('Tiny Tactics', 'nes'),
  ('Velocity Zero', 'psp'),
];

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
    }
    await loader.load();
  }

  await load(brutalMono, [
    for (final w in ['Medium', 'SemiBold', 'Bold'])
      'assets/fonts/ibm_plex_mono/IBMPlexMono-$w.ttf',
  ]);
  await load(brutalDisplay, [
    'assets/fonts/archivo_black/ArchivoBlack-Regular.ttf',
  ]);
  await load('DenaIcons', ['assets/fonts/dena_icons/DenaIcons.otf']);
}

Future<LibraryDatabase> _library() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = LibraryDatabase(NativeDatabase.memory());
  for (final (i, (title, system)) in _games.indexed) {
    await db.addGame(
      system: system,
      title: title,
      fileName: '$title.rom',
      path: '/nowhere/$i',
      sha1: 'sha$i',
      size: 1,
      crc32: '0',
      addedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
    );
  }
  return db;
}

void _screen(WidgetTester tester, Size size, double ratio, {bool pad = false}) {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  FocusManager.instance.highlightStrategy = pad
      ? FocusHighlightStrategy.alwaysTraditional
      : FocusHighlightStrategy.alwaysTouch;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

const _phone = Size(412, 915);
const _desktop = Size(1280, 720);
const _handheld = Size(640, 480);

void main() {
  FoilTilt.animate = false;
  hasAndroidShell = true;
  setUpAll(_loadFonts);

  Future<void> library(
    WidgetTester tester,
    String name,
    Size size,
    double ratio, {
    bool pad = false,
    ThemeSettings? theme,
  }) async {
    _screen(tester, size, ratio, pad: pad);
    final db = (await tester.runAsync(_library))!;
    await tester.pumpWidget(shellApp(db, theme: theme));
    await _settle(tester);
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile('$_out/$name.png'),
    );
    await _close(tester, db);
  }

  testWidgets('library, phone', (t) => library(t, 'library-phone', _phone, 2));
  testWidgets(
    'library, desktop',
    (t) => library(t, 'library-desktop', _desktop, 1),
  );
  testWidgets(
    'library, handheld with a pad',
    (t) => library(t, 'library-handheld', _handheld, 1, pad: true),
  );
  testWidgets(
    'library, ink and gold',
    (t) => library(
      t,
      'library-ink-gold',
      _desktop,
      1,
      theme: ThemeSettings(mode: ThemeMode.dark, accent: BrutalAccent.gold),
    ),
  );
  testWidgets(
    'library grid, phone',
    (t) => library(
      t,
      'library-grid-phone',
      _phone,
      2,
      theme: ThemeSettings(library: LibraryView.grid),
    ),
  );

  testWidgets('pause menu, phone', (tester) async {
    _screen(tester, _phone, 2);
    final db = (await tester.runAsync(_library))!;
    final game = (await tester.runAsync(
      (db.select(db.games)..limit(1)).getSingle,
    ))!;
    await tester.pumpWidget(sessionApp(db, game, FakeGameApi()));
    await tester.tap(find.text('library'));
    await tester.pumpAndSettle();
    // Back opens the pause menu, as in session_screen_test.dart.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile('$_out/pause-phone.png'),
    );
    await _close(tester, db);
  });
}
