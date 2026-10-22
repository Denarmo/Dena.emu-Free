// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library-stash.md (Acceptance tests)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/library/stash_view.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

const _titles = [
  'Alpha Quest',
  'Beta Racer',
  'Gamma Golf',
  'Delta Dash',
  'Echo Island',
  'Foxtrot Fury',
  'Golf Story',
  'Hotel Hero',
];

Future<void> _finish(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// Where the box of [title] is; boxes show the title as a FILE_NAME.
Offset _pos(WidgetTester tester, String title) => tester.getCenter(
  find.textContaining(title.toUpperCase().replaceAll(' ', '_')),
);

void main() {
  testScreens('stash view', (tester, screen, mode) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
    await _settle(tester);
    expect(find.byType(StashView), findsOneWidget);
    expect(find.byType(GameCard), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('stash', screen, mode)),
    );
    await _finish(tester, db);
  }, sizes: const [handheld4x3, phone]);

  testScreens(
    'stash mid-fling',
    (tester, screen, mode) async {
      final db = await seededDb(_titles);
      await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
      await _settle(tester);
      await tester.tap(find.text('SHAKE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(goldenName('stash_shaken', screen, mode)),
      );
      await tester.pumpAndSettle();
      await _finish(tester, db);
    },
    sizes: const [phone],
    modes: const [InputMode.touch],
  );

  testWidgets('toggle switches views and saves the choice', (tester) async {
    final dir = Directory.systemTemp.createTempSync('stash');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/theme.json');
    final db = await seededDb(_titles.take(3).toList());
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(file: file)));
    await _settle(tester);
    expect(find.byType(GameCard), findsNothing, reason: 'opens as a table');
    await tester.tap(find.text('[STASH]'));
    await _settle(tester);
    expect(find.byType(StashView), findsOneWidget);
    expect(jsonDecode(file.readAsStringSync())['library'], 'stash');
    expect(ThemeSettings.load(file).stash, isTrue);
    await tester.tap(find.text('[GRID]'));
    await _settle(tester);
    expect(find.byType(GameCard), findsNWidgets(3));
    expect(ThemeSettings.load(file).stash, isFalse);
    expect(jsonDecode(file.readAsStringSync())['library'], 'grid');
    await tester.tap(find.text('[LIST]'));
    await _settle(tester);
    expect(find.byType(GameCard), findsNothing);
    expect(jsonDecode(file.readAsStringSync())['library'], 'table');
    await _finish(tester, db);
  });

  testWidgets('tapping a box plays it; flinging moves it', (tester) async {
    played = [];
    final db = await seededDb(_titles.take(3).toList());
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
    await _settle(tester);
    final before = _pos(tester, 'Beta Racer');
    await tester.fling(find.text('BETA_RACER'), const Offset(80, 0), 1500);
    await tester.pumpAndSettle();
    expect(_pos(tester, 'Beta Racer'), isNot(before));
    await tester.tap(find.text('GAMMA_GOLF'));
    await tester.pumpAndSettle();
    expect(played.single.title, 'Gamma Golf');
    await _finish(tester, db);
  });

  testWidgets('shake moves every box', (tester) async {
    final db = await seededDb(_titles);
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
    await _settle(tester);
    final before = {for (final t in _titles) t: _pos(tester, t)};
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    await tester.pumpAndSettle();
    for (final t in _titles) {
      expect(_pos(tester, t), isNot(before[t]), reason: t);
    }
    await _finish(tester, db);
  });

  testWidgets('D-pad: A plays the focused box', (tester) async {
    played = [];
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final db = await seededDb(_titles.take(3).toList());
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
    await _settle(tester);
    // Move focus off the search bar onto a box, then activate it.
    final cover = find.descendant(
      of: find.byType(StashView),
      matching: find.byType(GameCover),
    );
    Focus.of(tester.element(cover.first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(played, hasLength(1));
    await _finish(tester, db);
  });

  testScreens(
    'stash mid-drop',
    (tester, screen, mode) async {
      final db = await seededDb(_titles);
      await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(goldenName('stash_dropping', screen, mode)),
      );
      await tester.pumpAndSettle();
      await _finish(tester, db);
    },
    sizes: const [phone],
    modes: const [InputMode.touch],
  );

  testWidgets('switching to the stash drops the boxes in', (tester) async {
    final db = await seededDb(_titles.take(4).toList());
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings()));
    await _settle(tester);
    await tester.tap(find.text('[STASH]'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final world = tester.state<StashViewState>(find.byType(StashView)).world;
    expect(world.bodies, hasLength(4));
    expect(world.bodies.every((b) => b.airborne), isTrue);
    await tester.pumpAndSettle();
    expect(world.bodies.any((b) => b.airborne), isFalse);
    expect(world.active, isFalse);
    // Settled boxes are still draggable.
    final titles = _titles.take(4);
    final before = {for (final t in titles) t: _pos(tester, t)};
    final top = find
        .descendant(
          of: find.byType(StashView),
          matching: find.byType(GameCover),
        )
        .last;
    await tester.drag(top, const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(titles.any((t) => _pos(tester, t) != before[t]), isTrue);
    await _finish(tester, db);
  });

  testWidgets('reduced motion skips the drop', (tester) async {
    final db = await seededDb(_titles.take(4).toList());
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(shellApp(db, theme: ThemeSettings(stash: true)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();
    final world = tester.state<StashViewState>(find.byType(StashView)).world;
    expect(world.bodies, hasLength(4));
    expect(world.bodies.any((b) => b.airborne), isFalse);
    await _finish(tester, db);
  });

  testWidgets('handheld puts at most 40 boxes on the table', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final titles = [for (var i = 0; i < 45; i++) 'Game $i'];
    final db = await seededDb(titles);
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: shellApp(db, theme: ThemeSettings(stash: true)),
      ),
    );
    await _settle(tester);
    final stash = tester.state<StashViewState>(find.byType(StashView));
    expect(stash.world.bodies, hasLength(StashView.handheldLimit));
    expect(find.text('> 40 of 45 games: filter to find more'), findsOneWidget);
    expect(find.text('SHAKE [X]'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, db);
  });
}
