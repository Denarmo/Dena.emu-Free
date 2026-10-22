// Spec: docs/specs/frame-generation.md (acceptance tests, app): settings,
// the host's fallback, the page, the session, goldens at 1280x720 and on a
// TV.
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/desktop/deck_presets.dart';
import 'package:dena_emu/src/desktop/frame_generation.dart';
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:dena_emu/src/library/database.dart';
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

void _screen(WidgetTester tester, Size size, {double hz = 60}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.display.size = size;
  tester.view.display.refreshRate = hz;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.reset);
}

/// A host that records the modes sent and answers with [status].
class _FakeHost {
  final sent = <int>[];
  String status = '0 - 0.0 0.0';

  FrameGenHost get host =>
      FrameGenHost(setMode: sent.add, status: () => status);
}

void main() {
  setUpAll(_loadFonts);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_frame_gen'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('settings', () {
    test('off everywhere by default; a damaged file too', () {
      final file = File('${dir.path}/desktop_frame_generation.json');
      final s = FrameGenSettings.load(file);
      for (final system in frameGenSystems) {
        expect(s.modeOf(system), FrameGenMode.off);
      }
      expect(frameGenSummary(s), 'off');
      file.writeAsStringSync('{broken');
      expect(FrameGenSettings.load(file).systemsOn, 0);
      file.writeAsStringSync('{"modes": {"nes": "nope", "snes": "off"}}');
      expect(FrameGenSettings.load(file).systemsOn, 0);
    });

    test('saves and loads modes per system', () {
      final file = File('${dir.path}/desktop_frame_generation.json');
      FrameGenSettings.load(file)
        ..setMode('nes', FrameGenMode.pixelArt)
        ..setMode('n64', FrameGenMode.interpolate)
        ..setMode('gba', FrameGenMode.interpolate)
        ..setMode('gba', FrameGenMode.off);
      final again = FrameGenSettings.load(file);
      expect(again.modeOf('nes'), FrameGenMode.pixelArt);
      expect(again.modeOf('n64'), FrameGenMode.interpolate);
      expect(again.modeOf('gba'), FrameGenMode.off);
      expect(frameGenSummary(again), '2 systems');
    });

    test('the refresh rule: 2x the game rate, 119 Hz is enough', () {
      expect(frameGenOffered('nes', 60), isFalse);
      expect(frameGenOffered('nes', 90), isFalse); // Deck OLED
      expect(frameGenOffered('nes', 118), isFalse);
      expect(frameGenOffered('nes', 119.88), isTrue);
      expect(frameGenOffered('nes', 120), isTrue);
      expect(frameGenOffered('nes', 144), isTrue);
    });

    test('parses the host status', () {
      expect(parseFrameGenStatus('1 - 8.4 10.3'), (
        mode: 1,
        reason: '',
        addedMs: 8.4,
        limitMs: 10.3,
      ));
      expect(parseFrameGenStatus('0 latency 12.3 10.3')?.reason, 'latency');
      expect(parseFrameGenStatus(''), isNull);
      expect(parseFrameGenStatus('x - 1 2'), isNull);
    });

    test('a game sends its mode; Off when it ends', () {
      final fake = _FakeHost();
      final s = FrameGenSettings(host: fake.host)
        ..setMode('snes', FrameGenMode.pixelArt);
      s.startGame('snes');
      s.endGame();
      s.startGame('gba');
      s.endGame();
      expect(fake.sent, [2, 0, 0, 0]);
    });

    test('the latency gate turns the system off and says why', () {
      final file = File('${dir.path}/desktop_frame_generation.json');
      final fake = _FakeHost();
      final s = FrameGenSettings.load(file, host: fake.host)
        ..setMode('n64', FrameGenMode.interpolate);
      s.startGame('n64');
      fake.status = '1 - 8.4 10.3';
      s.checkStatus();
      expect(s.modeOf('n64'), FrameGenMode.interpolate);
      // The screen dropped to 60 Hz: not kept, the system stays on.
      fake.status = '0 refresh 0.0 18.7';
      s.checkStatus();
      expect(s.modeOf('n64'), FrameGenMode.interpolate);
      fake.status = '0 latency 12.3 10.3';
      s.checkStatus();
      expect(s.modeOf('n64'), FrameGenMode.off);
      expect(
        s.fallbackOf('n64'),
        'Turned off: added 12 ms of input lag (limit 10 ms)',
      );
      s.endGame();
      // Kept across a restart; choosing again clears the reason.
      final again = FrameGenSettings.load(file);
      expect(again.fallbackOf('n64'), isNotNull);
      again.setMode('n64', FrameGenMode.pixelArt);
      expect(again.fallbackOf('n64'), isNull);
      expect(FrameGenSettings.load(file).fallbackOf('n64'), isNull);
    });

    test('a GL failure at game end is kept too', () {
      final fake = _FakeHost();
      final s = FrameGenSettings(host: fake.host)
        ..setMode('psx', FrameGenMode.interpolate);
      s.startGame('psx');
      fake.status = '0 gl 0.0 10.3';
      s.endGame();
      expect(s.modeOf('psx'), FrameGenMode.off);
      expect(s.fallbackOf('psx'), contains("graphics driver can't run it"));
      expect(fake.sent, [1, 0]);
    });
  });

  group('page', () {
    testWidgets('the row opens the page; D-pad and A set a system', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 720), hz: 144);
      final s = FrameGenSettings();
      await tester.pumpWidget(
        DenaApp(home: Scaffold(body: FrameGenTile(settings: s))),
      );
      expect(find.text('off >'), findsOneWidget);
      await tester.tap(find.text('FRAME GENERATION (EXPERIMENTAL)'));
      await tester.pumpAndSettle();
      expect(find.byType(FrameGenPage), findsOneWidget);
      expect(find.text('144 HZ'), findsOneWidget);
      expect(find.text('EXPERIMENTAL'), findsOneWidget);
      expect(find.textContaining('needs 120 Hz'), findsNothing);
      // Focus starts on NES OFF: right twice to PIXEL-ART.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(s.modeOf('nes'), FrameGenMode.pixelArt);
      // Down to SNES PIXEL-ART, left to INTERPOLATE.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(s.modeOf('snes'), FrameGenMode.interpolate);
      // B goes back; the row counts the systems.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pumpAndSettle();
      expect(find.text('2 systems >'), findsOneWidget);
    });

    testWidgets('a 60 Hz screen: choices locked, needs 120 Hz', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 720));
      final s = FrameGenSettings()..setMode('gba', FrameGenMode.interpolate);
      await tester.pumpWidget(DenaApp(home: FrameGenPage(settings: s)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Screen at 60 Hz: needs 120 Hz'), findsOne);
      await tester.tap(find.textContaining('PIXEL-ART').first);
      await tester.pumpAndSettle();
      expect(s.modeOf('nes'), FrameGenMode.off);
      expect(s.modeOf('gba'), FrameGenMode.interpolate); // kept
    });

    testWidgets('the Deck OLED gets a note; a fallback shows its reason', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800), hz: 90);
      final s = FrameGenSettings(
        fallbacks: {
          'n64': 'Turned off: added 12 ms of input lag (limit 10 ms)',
        },
      );
      await tester.pumpWidget(
        DenaApp(
          home: FrameGenPage(settings: s, model: DeckModel.oled),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Steam Deck OLED screen runs at up to 90 Hz'),
        findsOneWidget,
      );
      expect(find.textContaining('N64: Turned off: added 12 ms'), findsOne);
    });

    for (final (name, size, tv) in [
      ('1280x720', const Size(1280, 720), false),
      ('tv_1920x1080', const Size(1920, 1080), true),
    ]) {
      testWidgets('golden $name', (tester) async {
        _screen(tester, size, hz: 144);
        final s =
            FrameGenSettings(
                fallbacks: {
                  'psx': "Turned off: this PC's graphics driver can't run it",
                },
              )
              ..setMode('nes', FrameGenMode.pixelArt)
              ..setMode('n64', FrameGenMode.interpolate);
        final page = FrameGenPage(settings: s);
        await tester.pumpWidget(
          DenaApp(home: tv ? TvScale(enabled: true, child: page) : page),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(FrameGenPage),
          matchesGoldenFile('goldens/frame_generation_$name.png'),
        );
      });
    }
  });

  group('session', () {
    testWidgets('the system mode goes to the host at start, Off at the end', (
      tester,
    ) async {
      _screen(tester, const Size(1280, 800), hz: 120);
      final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
      final Game game = (await tester.runAsync(db.select(db.games).getSingle))!;
      final fake = _FakeHost();
      final s = FrameGenSettings(host: fake.host)
        ..setMode(game.system, FrameGenMode.pixelArt);
      await tester.pumpWidget(
        FrameGenScope(
          settings: s,
          child: sessionApp(db, game, FakeGameApi()),
        ),
      );
      await tester.tap(find.text('library'));
      await tester.pumpAndSettle();
      expect(fake.sent, [2]);
      // The host's gate turns it off while the game plays.
      fake.status = '0 latency 12.3 10.3';
      await tester.pump(const Duration(seconds: 2));
      expect(s.modeOf(game.system), FrameGenMode.off);
      expect(s.fallbackOf(game.system), contains('12 ms'));
      await closeDb(tester, db);
      expect(fake.sent, [2, 0]);
    });
  });
}
