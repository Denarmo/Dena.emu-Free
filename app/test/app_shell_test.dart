import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/shell/cfg_page.dart';
import 'package:dena_emu/src/spike/spike_screen.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/library_fixture.dart';
import 'support/screen_matrix.dart';

const _titles = ['Alpha Quest', 'Beta Racer', 'Gamma Golf'];

/// Unmounts the app so Drift's stream-cancel timers run, then closes the db.
Future<void> finish(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

Future<void> settle(WidgetTester tester) async {
  // Drift streams resolve asynchronously; let them deliver, then settle.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// The library shows titles as FILE_NAMEs (brutalist-ui.md 4.2).
String _file(String title) => title.toUpperCase().replaceAll(' ', '_');

double _rowY(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(_file(title))).dy;

Finder _search() => find.descendant(
  of: find.byType(CommandField),
  matching: find.byType(EditableText),
);

Finder _filter(String label) =>
    find.byWidgetPredicate((w) => w is CheckFilter && w.label == label);

void main() {
  testScreens('the focused row is lit only in D-pad mode', (
    tester,
    screen,
    mode,
  ) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    expect(
      find.text('->'),
      mode == InputMode.focus ? findsOneWidget : findsNothing,
    );
    await finish(tester, db);
  }, sizes: const [handheld4x3]);

  testScreens('empty library', (tester, screen, mode) async {
    final db = await seededDb([]);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    expect(find.text('NO ROMS FOUND.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('games_empty', screen, mode)),
    );
    await finish(tester, db);
  }, sizes: const [...allScreenSizes, desktop720]);

  testScreens('library with games', (tester, screen, mode) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    for (final t in _titles) {
      expect(find.text(_file(t)), findsWidgets, reason: 'a table row');
    }
    expect(find.byType(GameCard), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('games_three', screen, mode)),
    );
    await finish(tester, db);
  }, sizes: const [...allScreenSizes, desktop720]);

  testScreens('large library scrolls without overflow', (
    tester,
    screen,
    mode,
  ) async {
    final db = await seededDb([for (var i = 0; i < 40; i++) 'Game number $i']);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await finish(tester, db);
  }, modes: const [InputMode.touch]);

  testScreens('library grid view', (tester, screen, mode) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(
      shellApp(db, theme: ThemeSettings(library: LibraryView.grid)),
    );
    await settle(tester);
    expect(find.byType(GameCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('games_grid', screen, mode)),
    );
    await finish(tester, db);
  }, sizes: const [...allScreenSizes, desktop720]);

  testWidgets('search and system filters narrow the table', (tester) async {
    final db = await seededDb(_titles); // gba, snes, nes
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    await tester.enterText(_search(), 'beta');
    await settle(tester);
    expect(find.text('BETA_RACER'), findsOneWidget);
    expect(find.text('ALPHA_QUEST'), findsNothing);
    expect(find.text('1 ROWS // SORT=TITLE ASC'), findsOneWidget);
    await tester.enterText(_search(), '');
    await settle(tester);
    await tester.tap(_filter('NES'));
    await settle(tester);
    expect(find.text('GAMMA_GOLF'), findsOneWidget);
    expect(find.text('BETA_RACER'), findsNothing);
    await finish(tester, db);
  });

  testWidgets('titles show as FILE_NAMEs; the stored title is unchanged', (
    tester,
  ) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    expect(find.text('ALPHA_QUEST'), findsOneWidget);
    final stored = await tester.runAsync(() => db.watchGames().first);
    expect(stored!.map((g) => g.title), containsAll(_titles));
    await finish(tester, db);
  });

  testWidgets('a header tap sorts; a second tap flips the order', (
    tester,
  ) async {
    final db = await seededDb(_titles); // gba, snes, nes
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    expect(_rowY(tester, 'Alpha Quest'), lessThan(_rowY(tester, 'Gamma Golf')));
    await tester.tap(find.text('SYS'));
    await settle(tester);
    // Console order: NES, SNES, GBA.
    expect(_rowY(tester, 'Gamma Golf'), lessThan(_rowY(tester, 'Beta Racer')));
    expect(_rowY(tester, 'Beta Racer'), lessThan(_rowY(tester, 'Alpha Quest')));
    await tester.tap(find.text('SYS ↓'));
    await settle(tester);
    expect(_rowY(tester, 'Alpha Quest'), lessThan(_rowY(tester, 'Beta Racer')));
    expect(_rowY(tester, 'Beta Racer'), lessThan(_rowY(tester, 'Gamma Golf')));
    await finish(tester, db);
  });

  testWidgets('Select steps the sort key; X shuffles to another game', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final db = await seededDb([for (var i = 0; i < 60; i++) 'Game $i']);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonSelect);
    await settle(tester);
    expect(find.textContaining('SORT=SYS'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
      await settle(tester);
      // The shuffled row is focused and on screen.
      final marker = find.text('->');
      expect(marker, findsOneWidget);
      final y = tester.getCenter(marker).dy;
      expect(y, inInclusiveRange(0, tester.view.physicalSize.height));
    }
    await finish(tester, db);
  });

  testWidgets('D-pad: A plays the focused game, Y opens its sheet', (
    tester,
  ) async {
    played = [];
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonY);
    await settle(tester);
    expect(find.text('PLAY'), findsOneWidget, reason: 'details sheet is open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(played, hasLength(1));
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await finish(tester, db);
  });

  testWidgets('a play link opens its game; unknown links say so', (
    tester,
  ) async {
    played = [];
    final db = await seededDb(_titles);
    final links = FakeLinks()..pending = 'sha1';
    await tester.pumpWidget(shellApp(db, links: links));
    await settle(tester);
    expect(played.single.title, 'Beta Racer');
    links.pending = 'nope';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(played, hasLength(1));
    expect(find.text('That game is not in your library'), findsOneWidget);
    await finish(tester, db);
  });

  testWidgets('a link is dropped while another screen is on top', (
    tester,
  ) async {
    played = [];
    final db = await seededDb(_titles);
    final links = FakeLinks();
    await tester.pumpWidget(shellApp(db, links: links));
    await settle(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('game')));
    await settle(tester);
    links.pending = 'sha0';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(played, isEmpty);
    expect(links.pending, isNull);
    await finish(tester, db);
  });

  testWidgets('the game sheet pins a home-screen shortcut', (tester) async {
    final db = await seededDb(_titles);
    final links = FakeLinks();
    await tester.pumpWidget(shellApp(db, links: links));
    await settle(tester);
    await tester.longPress(find.text('ALPHA_QUEST'));
    await settle(tester);
    await tester.ensureVisible(find.text('HOME SCREEN'));
    await settle(tester);
    await tester.tap(find.text('HOME SCREEN'));
    await settle(tester);
    expect(links.pinned, ['sha0']);
    links.canPin = false;
    await tester.longPress(find.text('ALPHA_QUEST'));
    await settle(tester);
    await tester.ensureVisible(find.text('HOME SCREEN'));
    await settle(tester);
    await tester.tap(find.text('HOME SCREEN'));
    await settle(tester);
    expect(
      find.textContaining("can't pin shortcuts", findRichText: true),
      findsOneWidget,
    );
    await finish(tester, db);
  });

  testWidgets('R1 switches tabs; Settings opens the latency test', (
    tester,
  ) async {
    final db = await seededDb([]);
    await tester.pumpWidget(shellApp(db));
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
    }
    await tester.scrollUntilVisible(
      find.text('LATENCY TEST'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CfgSections),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('LATENCY TEST'));
    await settle(tester);
    await tester.tap(find.text('LATENCY TEST'));
    await settle(tester);
    expect(find.byType(SpikeScreen), findsOneWidget);
    await finish(tester, db);
  });
}
