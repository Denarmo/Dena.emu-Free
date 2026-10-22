// Steam Deck presets: plans per device, the settings file, the page, the
// session using the preset, goldens at 1280x720 and on a TV.
// Spec: docs/specs/deck-presets.md
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/desktop/deck_presets.dart';
import 'package:dena_emu/src/desktop/run_ahead.dart';
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../session_screen_test.dart' show FakeGameApi, closeDb, sessionApp;
import '../support/library_fixture.dart' show seededDb;

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

/// The test view as a screen [size] physical pixels at [hz].
void _screen(WidgetTester tester, Size size, {double hz = 60}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.display.size = size;
  tester.view.display.refreshRate = hz;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.reset);
}

PresetPlan? _plan(String system, DeckPreset p, DeckModel m, double h) =>
    planPreset(system, p, model: m, screenHeight: h);

void main() {
  setUpAll(_loadFonts);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_presets'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('plans', () {
    test('evenRefresh picks whole multiples in the panel range', () {
      expect(evenRefresh(60, 40, 60), 60);
      expect(evenRefresh(60, 45, 90), 60);
      expect(evenRefresh(60, 45, 90, high: true), 60);
      expect(evenRefresh(45, 45, 90, high: true), 90);
      expect(evenRefresh(20, 40, 60), 40);
      expect(evenRefresh(20, 40, 60, high: true), 60);
      expect(evenRefresh(50, 40, 60), 50);
      expect(evenRefresh(70, 40, 60), isNull);
      expect(dividesEvenly(60), isTrue);
      expect(dividesEvenly(59.94), isTrue);
      expect(dividesEvenly(120), isTrue);
      expect(dividesEvenly(45), isFalse);
      expect(dividesEvenly(144), isFalse);
    });

    test('Steam Deck LCD (800 px): factors, run-ahead, 60 Hz, TDP', () {
      const lcd = DeckModel.lcd;
      expect(_plan('nes', DeckPreset.off, lcd, 800), isNull);
      expect(
        _plan('n64', DeckPreset.balanced, lcd, 800),
        const PresetPlan(
          upscale: 3,
          runAhead: null,
          refreshHz: 60,
          tdpWatts: 9,
        ),
      );
      expect(_plan('n64', DeckPreset.performance, lcd, 800)!.upscale, 4);
      expect(_plan('n64', DeckPreset.battery, lcd, 800)!.upscale, 0);
      expect(_plan('psx', DeckPreset.balanced, lcd, 800)!.upscale, 2);
      expect(_plan('psx', DeckPreset.performance, lcd, 800)!.upscale, 4);
      expect(_plan('psp', DeckPreset.balanced, lcd, 800)!.upscale, 2);
      expect(_plan('psp', DeckPreset.performance, lcd, 800)!.upscale, 3);
      expect(_plan('nds', DeckPreset.balanced, lcd, 800)!.upscale, 2);
      expect(_plan('nds', DeckPreset.performance, lcd, 800)!.upscale, 3);
      expect(
        _plan('gba', DeckPreset.battery, lcd, 800),
        const PresetPlan(upscale: 0, runAhead: 0, refreshHz: 60, tdpWatts: 4),
      );
      expect(_plan('snes', DeckPreset.balanced, lcd, 800)!.runAhead, 1);
      expect(_plan('nes', DeckPreset.performance, lcd, 800)!.runAhead, 2);
      expect(_plan('psx', DeckPreset.performance, lcd, 800)!.runAhead, 2);
      expect(_plan('psp', DeckPreset.performance, lcd, 800)!.runAhead, isNull);
      expect(_plan('psp', DeckPreset.performance, lcd, 800)!.tdpWatts, 13);
    });

    test('Steam Deck OLED: same factors, 60 Hz in its 45-90 Hz range', () {
      const oled = DeckModel.oled;
      final p = _plan('n64', DeckPreset.performance, oled, 800)!;
      expect((p.upscale, p.refreshHz, p.tdpWatts), (4, 60, 12));
      expect(_plan('gb', DeckPreset.battery, oled, 800)!.refreshHz, 60);
    });

    test('a 4K PC: performance 8x, balanced fits, no refresh or TDP', () {
      const pc = DeckModel.none;
      final perf = _plan('n64', DeckPreset.performance, pc, 2160)!;
      expect(
        perf,
        const PresetPlan(
          upscale: 8,
          runAhead: null,
          refreshHz: null,
          tdpWatts: null,
        ),
      );
      expect(_plan('n64', DeckPreset.balanced, pc, 2160)!.upscale, 8);
      expect(_plan('psx', DeckPreset.balanced, pc, 2160)!.upscale, 8);
      expect(_plan('nds', DeckPreset.balanced, pc, 2160)!.upscale, 4);
      expect(_plan('nds', DeckPreset.performance, pc, 2160)!.upscale, 6);
      // A screen lower than the native picture: Balanced is Auto.
      expect(_plan('nds', DeckPreset.balanced, pc, 600)!.upscale, 0);
    });

    test('the Deck model comes from the board name', () {
      DeckModel detect(String vendor, String board, {String deck = ''}) =>
          detectDeckModel(
            env: {'SteamDeck': deck},
            os: 'linux',
            readFile: (path) => path.endsWith('vendor') ? vendor : board,
          );
      expect(detect('Valve\n', 'Jupiter\n'), DeckModel.lcd);
      expect(detect('Valve', 'Galileo'), DeckModel.oled);
      expect(detect('LENOVO', 'X'), DeckModel.none);
      expect(detect('LENOVO', 'X', deck: '1'), DeckModel.lcd);
      expect(detectDeckModel(os: 'windows'), DeckModel.none);
    });
  });

  group('settings', () {
    test('Balanced on a Deck, off on a PC; saved and loaded', () {
      final file = File('${dir.path}/desktop_presets.json');
      final pc = DeckPresetSettings.load(file);
      expect(pc.presetOf('n64'), DeckPreset.off);
      expect(pc.planFor('n64', screenHeight: 1080), isNull);
      final deck = DeckPresetSettings.load(file, model: DeckModel.oled);
      expect(deck.presetOf('n64'), DeckPreset.balanced);
      expect(deck.common, DeckPreset.balanced);
      var notified = 0;
      deck.addListener(() => notified++);
      deck.setPreset('n64', DeckPreset.performance);
      expect(deck.common, isNull);
      deck.setPreset('nes', DeckPreset.off);
      expect(notified, 2);
      final again = DeckPresetSettings.load(file, model: DeckModel.oled);
      expect(again.presetOf('n64'), DeckPreset.performance);
      expect(again.presetOf('nes'), DeckPreset.off);
      expect(again.presetOf('gba'), DeckPreset.balanced);
      again.setAll(DeckPreset.battery);
      expect(
        DeckPresetSettings.load(file, model: DeckModel.lcd).common,
        DeckPreset.battery,
      );
    });

    test('a damaged file gives the defaults', () {
      final file = File('${dir.path}/desktop_presets.json')
        ..writeAsStringSync('{broken');
      expect(
        DeckPresetSettings.load(file, model: DeckModel.lcd).common,
        DeckPreset.balanced,
      );
      file.writeAsStringSync('{"systems": {"n64": "turbo", "nes": "off"}}');
      final s = DeckPresetSettings.load(file, model: DeckModel.lcd);
      expect(s.presetOf('n64'), DeckPreset.balanced);
      expect(s.presetOf('nes'), DeckPreset.off);
    });

    test(
      'run-ahead: the preset frames with the Settings method, then back',
      () {
        final sent = <(int, int)>[];
        final ra = RunAheadSettings(
          frames: 1,
          method: RunAheadMethod.runAhead,
          sink: (mode, frames) => sent.add((mode, frames)),
        );
        sent.clear(); // the choice sent when the settings were made
        final plan = _plan('snes', DeckPreset.performance, DeckModel.lcd, 800)!;
        applyPresetRunAhead(ra, plan);
        applyPresetRunAhead(
          ra,
          _plan('snes', DeckPreset.battery, DeckModel.lcd, 800)!,
        );
        // No run-ahead on PSP: nothing sent.
        applyPresetRunAhead(
          ra,
          _plan('psp', DeckPreset.performance, DeckModel.lcd, 800)!,
        );
        restoreRunAhead(ra);
        expect(sent, [(2, 2), (0, 0), (2, 1)]);
      },
    );
  });

  group('page', () {
    testWidgets('the row opens the page; A steps a system, ALL sets all', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800));
      final s = DeckPresetSettings(model: DeckModel.lcd);
      await tester.pumpWidget(
        DenaApp(
          home: Scaffold(body: PresetsTile(settings: s)),
        ),
      );
      expect(find.text('balanced · Steam Deck LCD >'), findsOneWidget);
      await tester.tap(find.text('PRESETS'));
      await tester.pumpAndSettle();
      expect(find.byType(PresetsPage), findsOneWidget);
      expect(find.text('STEAM DECK LCD · 40-60 HZ'), findsOneWidget);
      expect(find.text('3x'), findsOneWidget); // N64 balanced at 800 px
      // Focus starts on the ALL choices: right to BATTERY.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(s.common, DeckPreset.battery);
      // A click on the N64 row steps it to Balanced.
      await tester.tap(find.text('N64'));
      await tester.pumpAndSettle();
      expect(s.presetOf('n64'), DeckPreset.balanced);
      expect(s.presetOf('nes'), DeckPreset.battery);
      expect(find.textContaining('judder'), findsNothing);
    });

    testWidgets('a display that does not divide 60 fps gets a warning', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800), hz: 45);
      await tester.pumpWidget(
        DenaApp(
          home: PresetsPage(
            settings: DeckPresetSettings(model: DeckModel.oled),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Display at 45 Hz: 60 fps games judder. Set 60 Hz.',
        ),
        findsOneWidget,
      );
    });

    for (final (name, size, tv) in [
      ('1280x720', const Size(1280, 720), false),
      ('tv_1920x1080', const Size(1920, 1080), true),
    ]) {
      testWidgets('golden $name', (tester) async {
        _screen(tester, size);
        final s = DeckPresetSettings(model: DeckModel.oled)
          ..setPreset('n64', DeckPreset.performance)
          ..setPreset('nes', DeckPreset.off);
        final page = PresetsPage(settings: s);
        await tester.pumpWidget(
          DenaApp(home: tv ? TvScale(enabled: true, child: page) : page),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(PresetsPage),
          matchesGoldenFile('goldens/deck_presets_$name.png'),
        );
      });
    }
  });

  group('session', () {
    Future<(LibraryDatabase, Game)> n64Game(WidgetTester tester) async {
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
      return (db, game);
    }

    Future<FakeGameApi> play(
      WidgetTester tester,
      LibraryDatabase db,
      Game game,
      ShaderStore store,
      DeckPresetSettings presets, {
      RunAheadSettings? runAhead,
    }) async {
      final api = FakeGameApi();
      Widget app = DeckPresetsScope(
        settings: presets,
        child: sessionApp(db, game, api, shaders: store),
      );
      if (runAhead != null) {
        app = RunAheadScope(settings: runAhead, child: app);
      }
      await tester.pumpWidget(app);
      await tester.tap(find.text('library'));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('the preset factor beats the system RES', (tester) async {
      _screen(tester, const Size(1280, 800));
      final (db, game) = await n64Game(tester);
      final store = ShaderStore(dir.path, desktop: true)
        ..setSystemUpscale('n64', 8);
      final api = await play(
        tester,
        db,
        game,
        store,
        DeckPresetSettings(model: DeckModel.lcd),
      );
      expect(api.upscale, 3); // Balanced at 800 px
      await closeDb(tester, db);
    });

    testWidgets('a game\'s own RES beats the preset; off keeps the RES', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800));
      final (db, game) = await n64Game(tester);
      final store = ShaderStore(dir.path, desktop: true)
        ..setSystemUpscale('n64', 8)
        ..setGameUpscale(game.sha1, 2);
      final presets = DeckPresetSettings(model: DeckModel.lcd)
        ..setAll(DeckPreset.performance);
      expect((await play(tester, db, game, store, presets)).upscale, 2);
      await closeDb(tester, db);
    });

    testWidgets('run-ahead: the preset frames at start, Settings after', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800));
      final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
      final game = (await tester.runAsync(db.select(db.games).getSingle))!;
      final sent = <(int, int)>[];
      final ra = RunAheadSettings(sink: (m, f) => sent.add((m, f)));
      sent.clear(); // the choice sent when the settings were made
      final presets = DeckPresetSettings(model: DeckModel.lcd)
        ..setAll(DeckPreset.performance);
      await play(
        tester,
        db,
        game,
        ShaderStore(dir.path, desktop: true),
        presets,
        runAhead: ra,
      );
      expect(sent, [(1, 2)]); // 2 frames, Preemptive from Settings
      await closeDb(tester, db);
      expect(sent, [(1, 2), (1, 1)]); // the Settings choice again
    });
  });
}
