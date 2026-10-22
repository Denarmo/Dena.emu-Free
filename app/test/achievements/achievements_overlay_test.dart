// The desktop's in-game RetroAchievements overlay: settings, progress and
// challenge events, placement, the chime, goldens at 1280x720 and on a TV.
// Spec: achievements.md (Desktop overlay), brutalist-ui.md
import 'dart:io';

import 'package:dena_emu/src/achievements/achievements_overlay.dart';
import 'package:dena_emu/src/achievements/achievements_ui.dart';
import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../session_screen_test.dart'
    show FakeGameApi, closeDb, firstGame, sessionApp;
import '../support/library_fixture.dart' show seededDb;
import 'achievements_test.dart' show settle, signedIn, tempDir;
import 'fake_ra_native.dart';

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

Map<String, Object?> _ach(int id, String title, String progress, double pct) =>
    {
      'id': id,
      'title': title,
      'description': 'Do it',
      'points': 10,
      'unlocked': 0,
      'progress': progress,
      'percent': pct,
    };

/// A signed-in client in a hardcore session with a progress box and one
/// challenge on, its game toast already shown.
Future<RetroAchievements> _session(FakeRaNative native) async {
  final ra = signedIn(native, tempDir());
  await ra.beginSession('/games/test.gba', 'gba');
  native.events
    ..add({'type': 'progress', 'achievement': _ach(2, 'Second', '6/20', 30)})
    ..add({'type': 'challenge', 'achievement': _ach(3, 'No hit', '', 0)});
  ra.tick();
  return ra;
}

Widget _game(RetroAchievements ra, RaOverlaySettings s, {bool tv = false}) {
  final overlay = Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Color(0xff3a7d6b)),
      RaOverlay(ra: ra, settings: s),
    ],
  );
  return DenaApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: tv ? TvScale(enabled: true, child: overlay) : overlay,
    ),
  );
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(_loadFonts);

  group('RaOverlaySettings', () {
    test('defaults, kept across launches, damaged file gives defaults', () {
      final file = File(p.join(tempDir().path, 'ra_overlay.json'));
      final s = RaOverlaySettings.load(file);
      expect(s.corner, RaToastCorner.topRight);
      expect(s.time, RaToastTime.normal);
      expect(s.sound, isFalse);
      expect(s.progress, isTrue);
      expect(s.hardcoreSticker, isTrue);
      s
        ..corner = RaToastCorner.bottomLeft
        ..time = RaToastTime.long
        ..sound = true
        ..progress = false
        ..hardcoreSticker = false;
      final again = RaOverlaySettings.load(file);
      expect(again.corner, RaToastCorner.bottomLeft);
      expect(again.time, RaToastTime.long);
      expect(again.sound, isTrue);
      expect(again.progress, isFalse);
      expect(again.hardcoreSticker, isFalse);
      file.writeAsStringSync('{nope');
      expect(RaOverlaySettings.load(file).corner, RaToastCorner.topRight);
    });

    test('the free corners never meet the toasts', () {
      for (final c in RaToastCorner.values) {
        expect(c.stickerCorner, isNot(c.alignment));
        expect(c.progressCorner, isNot(c.alignment));
        expect(c.progressCorner, isNot(c.stickerCorner));
      }
    });
  });

  test('progress and challenge events; unlock and session end clear', () async {
    final native = FakeRaNative();
    final ra = await _session(native);
    expect(ra.progress?.progress, '6/20');
    expect(ra.progress?.percent, 30);
    expect(ra.challenges.single.id, 3);
    // The same challenge again replaces, never doubles.
    native.events.add({
      'type': 'challenge',
      'achievement': _ach(3, 'No hit', '', 0),
    });
    ra.tick();
    expect(ra.challenges, hasLength(1));
    native.events.add({'type': 'progress_hide'});
    ra.tick();
    expect(ra.progress, isNull);
    native.events.add({
      'type': 'unlock',
      'hardcore': true,
      'achievement': {..._ach(3, 'No hit', '', 0), 'unlocked': 2},
    });
    ra.tick();
    expect(ra.challenges, isEmpty);
    native.events
      ..add({'type': 'progress', 'achievement': _ach(2, 'Second', '7/20', 35)})
      ..add({'type': 'challenge', 'achievement': _ach(4, 'Four', '', 0)})
      ..add({'type': 'challenge_hide', 'id': 4});
    ra.tick();
    expect(ra.challenges, isEmpty);
    ra.endSession();
    expect(ra.progress, isNull);
    ra.dispose();
  });

  testWidgets('pieces sit in their corners; the chime follows the setting', (
    tester,
  ) async {
    _size(tester, const Size(1280, 720));
    final native = FakeRaNative();
    final ra = (await tester.runAsync(() => _session(native)))!;
    final settings = RaOverlaySettings();
    var chimes = 0;
    await tester.pumpWidget(
      DenaApp(
        home: RaOverlay(ra: ra, settings: settings, chime: () => chimes++),
      ),
    );
    await tester.pump();
    final toast = find.byType(RaToast);
    final sticker = find.text('HARDCORE');
    final box = find.byKey(const ValueKey('ra-progress'));
    expect(find.byKey(const ValueKey('challenge-3')), findsOneWidget);
    expect(tester.getTopRight(box).dx, greaterThan(1200));
    expect(tester.getBottomRight(box).dy, greaterThan(650));

    // The game toast came before the overlay was up: show an unlock.
    native.events.add({
      'type': 'unlock',
      'hardcore': true,
      'achievement': {..._ach(1, 'First', '', 0), 'unlocked': 2},
    });
    ra.tick();
    await tester.pump();
    expect(find.text('FIRST'), findsOneWidget);
    expect(tester.getTopRight(toast).dx, greaterThan(1200));
    expect(tester.getTopLeft(toast).dy, lessThan(60));
    expect(tester.getTopLeft(sticker).dx, lessThan(80));
    expect(chimes, 0); // sound is off by default

    await tester.pump(const Duration(seconds: 5));
    expect(toast, findsNothing);

    settings
      ..sound = true
      ..corner = RaToastCorner.bottomLeft
      ..time = RaToastTime.short;
    await tester.pump();
    native.events.add({'type': 'mastered', 'title': 'Test Game'});
    ra.tick();
    await tester.pump();
    await tester.pump();
    expect(chimes, 1);
    expect(tester.getBottomLeft(toast).dx, lessThan(80));
    expect(tester.getBottomLeft(toast).dy, greaterThan(650));
    expect(tester.getTopRight(sticker).dx, greaterThan(1150));
    expect(tester.getTopLeft(box).dx, lessThan(80));
    expect(tester.getTopLeft(box).dy, lessThan(200));
    await tester.pump(const Duration(seconds: 3));
    expect(toast, findsNothing);

    settings
      ..progress = false
      ..hardcoreSticker = false;
    await tester.pump();
    expect(box, findsNothing);
    expect(sticker, findsNothing);
    ra.endSession();
    ra.dispose();
  });

  testWidgets('the desktop game screen uses the overlay', (tester) async {
    _size(tester, const Size(1280, 720));
    final native = FakeRaNative();
    final ra = signedIn(native, tempDir());
    final db = (await tester.runAsync(() => seededDb(['Pocket: Quest'])))!;
    final g = await firstGame(tester, db);
    await tester.pumpWidget(
      RaOverlayScope(
        settings: RaOverlaySettings(),
        child: sessionApp(db, g, FakeGameApi(), achievements: ra),
      ),
    );
    await tester.tap(find.text('library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(RaOverlay), findsOneWidget);
    expect(find.text('HARDCORE'), findsOneWidget);
    expect(
      find.text('1 of 2 achievements unlocked · Hardcore'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('QUIT GAME'));
    await tester.pumpAndSettle();
    await settle(tester);
    ra.dispose();
    await closeDb(tester, db);
  });

  testWidgets('Settings shows OVERLAY.CFG only on the desktop', (tester) async {
    _size(tester, const Size(1280, 720));
    final ra = signedIn(FakeRaNative(), tempDir());
    await tester.pumpWidget(DenaApp(home: RetroAchievementsPage(ra: ra)));
    await settle(tester);
    expect(find.text('OVERLAY.CFG'), findsNothing);

    final settings = RaOverlaySettings();
    await tester.pumpWidget(
      RaOverlayScope(
        settings: settings,
        child: DenaApp(home: RetroAchievementsPage(ra: ra)),
      ),
    );
    await settle(tester);
    await tester.scrollUntilVisible(find.text('OVERLAY.CFG'), 200);
    await tester.pumpAndSettle();
    expect(find.text('OVERLAY.CFG'), findsOneWidget);
    await tester.tap(find.text(' BOTTOM LEFT '));
    await tester.pump();
    expect(settings.corner, RaToastCorner.bottomLeft);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/achievements_overlay_settings_1280x720.png'),
    );
    ra.dispose();
  });

  for (final (name, size, tv) in [
    ('1280x720', const Size(1280, 720), false),
    ('tv_1920x1080', const Size(1920, 1080), true),
  ]) {
    testWidgets('overlay golden $name', (tester) async {
      _size(tester, size);
      final native = FakeRaNative();
      final ra = (await tester.runAsync(() => _session(native)))!;
      await tester.pumpWidget(_game(ra, RaOverlaySettings(), tv: tv));
      native.events.add({
        'type': 'unlock',
        'hardcore': true,
        'achievement': {..._ach(1, 'First Steps', '', 0), 'unlocked': 2},
      });
      ra.tick();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/achievements_overlay_$name.png'),
      );
      await tester.pump(const Duration(seconds: 5));
      ra.endSession();
      ra.dispose();
    });
  }
}
