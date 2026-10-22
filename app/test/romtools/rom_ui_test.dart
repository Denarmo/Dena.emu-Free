// SPDX-License-Identifier: GPL-3.0-or-later
// Goldens and behaviour of the ROM manager screens: the ROM page, the
// Settings page, INSPECT's DAT entry and the DAT.CHK filters.
// Spec: docs/specs/rom-manager.md (5, 6)
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/romtools/convert.dart';
import 'package:dena_emu/src/romtools/dat_store.dart';
import 'package:dena_emu/src/romtools/models.dart';
import 'package:dena_emu/src/romtools/openvgdb.dart';
import 'package:dena_emu/src/romtools/rom_manager.dart';
import 'package:dena_emu/src/romtools/rom_manager_page.dart';
import 'package:dena_emu/src/romtools/rom_page.dart';
import 'package:dena_emu/src/romtools/scraper.dart';
import 'package:dena_emu/src/romtools/screenscraper.dart';
import 'package:dena_emu/src/romtools/verify.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
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

const _snesDat = '''<?xml version="1.0"?>
<datafile>
  <header>
    <name>Nintendo - Super Nintendo Entertainment System</name>
    <version>20261001-000000</version>
  </header>
  <game name="Alpha Quest (USA)">
    <rom name="Alpha Quest (USA).sfc" size="1" crc="00000000" sha1="sha1"/>
  </game>
</datafile>
''';

final _when = DateTime(2026, 10, 18, 9);

/// A manager under [dir] with no network, no tools on disk, no
/// ScreenScraper key and a SNES DAT imported.
Future<RomManager> _manager(
  WidgetTester tester,
  String dir,
  LibraryDatabase db, {
  bool desktop = true,
}) async {
  Future<Never> offline(Uri _) => throw const SocketException('offline');
  final dats = DatStore(dir, fetch: offline, clock: () => _when);
  final results = VerifyResults(dir);
  final account = ScreenScraperAccount(dir);
  final openVgdb = OpenVgdb(dir, fetch: offline);
  final settings = RomSettings(
    File(p.join(dir, 'romtools', 'settings.json')),
    defaultKinds: desktop ? ScrapeKind.values.toSet() : ScrapeKind.small,
  );
  final m = RomManager(
    dats: dats,
    results: results,
    verifier: GameVerifier(dats: dats, results: results, clock: () => _when),
    scraper: Scraper(
      dir,
      openVgdb: openVgdb,
      screenScraper: account,
      fetch: offline,
      kinds: () => settings.kinds,
    ),
    settings: settings,
    account: account,
    openVgdb: openVgdb,
    conversions: desktop
        ? ConversionQueue(
            tools: ToolLocator(
              environment: const {},
              appDir: dir,
              dataDir: dir,
              exists: (_) => false,
            ),
            onConverted: (game, out) => pointGameAt(db, game, out),
          )
        : null,
  );
  await tester.runAsync(() async {
    await m.load();
    final datFile = File(p.join(dir, 'snes.dat'))..writeAsStringSync(_snesDat);
    await dats.importFile(datFile);
  });
  return m;
}

Widget _app(LibraryDatabase db, RomManager m, Widget home) => RomManagerScope(
  manager: m,
  child: LibraryScope(
    db: db,
    importer: Importer(db, Directory.systemTemp),
    files: FakeFiles(),
    child: DenaApp(home: home),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  // File reads finish outside fake time; let them land, then settle.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

Finder _filter(String label) =>
    find.byWidgetPredicate((w) => w is CheckFilter && w.label == label);

void main() {
  setUpAll(_loadFonts);
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_rom_ui'));
  tearDown(() => dir.deleteSync(recursive: true));

  testScreens('rom page with a verified game', (tester, screen, mode) async {
    final db = await seededDb(['Alpha Quest', 'Beta Racer']);
    final m = await _manager(tester, dir.path, db);
    final games = await tester.runAsync(db.allGames);
    final game = games!.firstWhere((g) => g.title == 'Alpha Quest');
    await tester.runAsync(
      () => m.results.put(
        game.sha1,
        VerifyResult(
          status: VerifyStatus.verified,
          name: 'Alpha Quest (USA)',
          source: 'libretro-database',
          checkedAt: _when,
        ),
      ),
    );
    await tester.pumpWidget(_app(db, m, RomPage(game: game)));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('VERIFIED'), findsWidgets);
    expect(find.text('Alpha Quest (USA)'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('rom_page', screen, mode)),
    );
    await _finish(tester, db);
  }, sizes: const [phone, desktop720]);

  testScreens('rom manager settings page', (tester, screen, mode) async {
    final db = await seededDb(['Alpha Quest']);
    final m = await _manager(tester, dir.path, db);
    await tester.pumpWidget(_app(db, m, const RomManagerPage()));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('DATS.CFG'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('rom_manager_page', screen, mode)),
    );
    await _finish(tester, db);
  }, sizes: const [phone, desktop720]);

  testWidgets('phones get no conversion table', (tester) async {
    tester.view.physicalSize = const Size(1280, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await seededDb(['Alpha Quest']);
    final m = await _manager(tester, dir.path, db, desktop: false);
    await tester.pumpWidget(_app(db, m, const RomManagerPage()));
    await _settle(tester);
    expect(find.text('DATS.CFG'), findsOneWidget);
    expect(find.text('CONVERT.CFG'), findsNothing);
    await _finish(tester, db);
  });

  testWidgets('a PC gets the conversion table', (tester) async {
    tester.view.physicalSize = const Size(1280, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await seededDb(['Alpha Quest']);
    final m = await _manager(tester, dir.path, db);
    await tester.pumpWidget(_app(db, m, const RomManagerPage()));
    await _settle(tester);
    expect(find.text('CONVERT.CFG'), findsOneWidget);
    expect(find.textContaining('not found'), findsWidgets);
    await _finish(tester, db);
  });

  testWidgets('a check against the DAT shows on the ROM page', (tester) async {
    // The second seeded game is a SNES game with SHA-1 `sha1`, as in the DAT.
    final db = await seededDb(['Beta Racer', 'Alpha Quest']);
    final m = await _manager(tester, dir.path, db);
    final game = (await tester.runAsync(db.allGames))!
        .firstWhere((g) => g.title == 'Alpha Quest');
    await tester.pumpWidget(_app(db, m, RomPage(game: game)));
    await _settle(tester);
    expect(find.text('[UNCHECKED]'), findsOneWidget);
    // The isolate that parses the DAT needs real time, so the check runs
    // outside the fake clock; the page redraws from the shared results.
    await tester.runAsync(() => m.verifier.verify(game, download: true));
    await tester.pumpAndSettle();
    expect(m.resultFor(game)?.status, VerifyStatus.verified);
    expect(m.resultFor(game)?.name, 'Alpha Quest (USA)');
    expect(find.text('[VERIFIED]'), findsOneWidget);
    await _finish(tester, db);
  });

  testScreens('INSPECT shows the DAT result', (tester, screen, mode) async {
    final db = await seededDb(['Alpha Quest', 'Beta Racer', 'Gamma Golf']);
    final m = await _manager(tester, dir.path, db);
    final games = (await tester.runAsync(db.allGames))!;
    await tester.runAsync(() async {
      await m.results.put(
        games[0].sha1,
        VerifyResult(
          status: VerifyStatus.verified,
          name: 'Alpha Quest (USA)',
          checkedAt: _when,
        ),
      );
      await m.results.put(
        games[1].sha1,
        VerifyResult(status: VerifyStatus.badDump, checkedAt: _when),
      );
    });
    await tester.pumpWidget(RomManagerScope(manager: m, child: shellApp(db)));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('ROM CHECK'), findsOneWidget);
    expect(_filter('Verified'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('games_inspect_dat', screen, mode)),
    );

    // DAT.CHK narrows the table to the verified game, and back.
    await tester.tap(_filter('Verified'));
    await _settle(tester);
    expect(find.text('ALPHA_QUEST'), findsWidgets);
    expect(find.text('BETA_RACER'), findsNothing);
    await tester.tap(_filter('Bad'));
    await _settle(tester);
    expect(find.text('BETA_RACER'), findsWidgets);
    expect(find.text('ALPHA_QUEST'), findsNothing);
    await tester.tap(_filter('Bad'));
    await _settle(tester);
    expect(find.text('GAMMA_GOLF'), findsWidgets);
    await _finish(tester, db);
  }, sizes: const [desktop720]);
}
