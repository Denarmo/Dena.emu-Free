// Goldens of the Brutalist RetroAchievements pages.
// Spec: brutalist-ui.md (4.10, 7), achievements.md
import 'dart:io';

import 'package:dena_emu/src/achievements/achievements_ui.dart';
import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/screen_matrix.dart';
import 'achievements_test.dart' show game, settle, signedIn, tempDir;
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

bool _handheld(ScreenSize s) => s == handheld4x3 || s == handheldSquare;

void main() {
  setUpAll(_loadFonts);

  testScreens('achievements list page', (tester, screen, mode) async {
    final ra = signedIn(FakeRaNative(), tempDir());
    await tester.pumpWidget(
      Handheld(
        enabled: _handheld(screen),
        child: DenaApp(home: GameAchievementsPage(ra: ra, game: game())),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('1 of 2 unlocked'), findsOneWidget);
    expect(find.byType(ProgressCell), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('achievements_list', screen, mode)),
    );
    ra.dispose();
  });

  testScreens('achievements settings page', (tester, screen, mode) async {
    final ra = signedIn(FakeRaNative(), tempDir());
    await tester.pumpWidget(
      Handheld(
        enabled: _handheld(screen),
        child: DenaApp(home: RetroAchievementsPage(ra: ra)),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('[SIGN OUT]'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('achievements_settings', screen, mode)),
    );
    ra.dispose();
  }, sizes: const [handheld4x3, phone]);

  testWidgets('the list is D-pad scrollable, first row focused', (
    tester,
  ) async {
    final ra = signedIn(FakeRaNative(), tempDir());
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: DenaApp(home: GameAchievementsPage(ra: ra, game: game())),
      ),
    );
    await settle(tester);
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.descendant(
        of: find.byWidget(focused!.widget),
        matching: find.text('FIRST'),
      ),
      findsWidgets,
    );
    ra.dispose();
  });

  testWidgets('the settings row opens the page', (tester) async {
    final ra = RetroAchievements(native: FakeRaNative(), dataDir: tempDir().path);
    await tester.pumpWidget(
      DenaApp(home: Scaffold(body: RetroAchievementsTile(ra: ra))),
    );
    expect(find.text('[SIGN IN] >'), findsOneWidget);
    await tester.tap(find.text('RETROACHIEVEMENTS'));
    await tester.pumpAndSettle();
    expect(find.byType(RetroAchievementsPage), findsOneWidget);
    ra.dispose();
  });
}
