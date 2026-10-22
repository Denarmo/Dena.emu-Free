// The Brutalist shell: wordmark, tabs, rail and header bar per device.
// Spec: docs/specs/brutalist-ui.md (4.1, 4.12, 5)
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/shell/shell_chrome.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

const _desktop = ScreenSize('1280x720', Size(1280, 720));

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

List<String> _tabLabels(WidgetTester tester) => [
  for (final tab in tester.widgetList<BrutalTab>(find.byType(BrutalTab)))
    tab.item.label,
];

int _selectedTab(WidgetTester tester) => tester
    .widgetList<BrutalTab>(find.byType(BrutalTab))
    .toList()
    .indexWhere((t) => t.selected);

void main() {
  test('stat line counts ROMs and sizes in decimal units', () {
    expect(libraryStatLine(12, 4100000000), '12 ROMS // 4.1 GB');
    expect(libraryStatLine(1, 512000), '1 ROM // 512 KB');
    expect(libraryStatLine(0, 0), '0 ROMS // 0 B');
    expect(formatBytes(38400000), '38 MB');
    expect(shellPath('Games'), '/games');
  });

  testScreens('phone: wordmark and four tabs on top, no bottom bar', (
    tester,
    screen,
    mode,
  ) async {
    final db = await seededDb(['Alpha Quest', 'Beta Racer', 'Gamma Golf']);
    await tester.pumpWidget(shellApp(db));
    await _settle(tester);
    expect(find.byType(ShellTopTabs), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text(DenaWordmark.text), findsOneWidget);
    expect(find.text('/games'), findsOneWidget);
    expect(find.textContaining('3 ROMS // '), findsOneWidget);
    expect(_tabLabels(tester), ['Games', 'Carts', 'Apps', 'Settings']);
    expect(find.byType(BrutalGridPaper), findsWidgets);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('shell', screen, mode)),
    );
    // Tabs sit above the body: the wordmark is the top of the screen.
    final tabs = tester.getRect(find.byType(ShellTopTabs));
    final body = tester.getRect(find.byType(GamesTab));
    expect(tabs.bottom, lessThanOrEqualTo(body.top));
    await tester.tap(find.text('SETTINGS'));
    await _settle(tester);
    expect(_selectedTab(tester), 3);
    expect(find.text('/settings'), findsOneWidget);
    await _finish(tester, db);
  }, sizes: const [phone]);

  testScreens('tablet and desktop: one yellow header bar', (
    tester,
    screen,
    mode,
  ) async {
    final db = await seededDb(['Alpha Quest', 'Beta Racer', 'Gamma Golf']);
    await tester.pumpWidget(shellApp(db));
    await _settle(tester);
    expect(find.byType(ShellHeaderBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(_tabLabels(tester), ['Games', 'Carts', 'Apps', 'Settings']);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('shell', screen, mode)),
    );
    await _finish(tester, db);
  }, sizes: const [handheld4x3, handheldSquare, _desktop]);

  testScreens(
    'handheld: left rail without Apps, hint bar, L1/R1 switch',
    (tester, screen, mode) async {
      final db = await seededDb(['Alpha Quest', 'Beta Racer']);
      await tester.pumpWidget(Handheld(enabled: true, child: shellApp(db)));
      await _settle(tester);
      expect(find.byType(ShellRail), findsOneWidget);
      expect(_tabLabels(tester), ['Games', 'Carts', 'Settings']);
      expect(find.byType(BrutalHintBar), findsOneWidget);
      expect(find.byType(KeyGlyph), findsWidgets);
      // The rail is on the left of the body.
      final rail = tester.getRect(find.byType(ShellRail));
      final body = tester.getRect(find.byType(GamesTab));
      expect(rail.right, lessThanOrEqualTo(body.left));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(goldenName('shell_handheld', screen, mode)),
      );
      // Something is focused, and L1 wraps to the last tab.
      expect(FocusManager.instance.primaryFocus?.context, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
      await _settle(tester);
      expect(_selectedTab(tester), 2);
      expect(FocusManager.instance.primaryFocus?.context, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await _settle(tester);
      expect(_selectedTab(tester), 0);
      await _finish(tester, db);
    },
    sizes: const [handheld4x3, handheldSquare],
    modes: const [InputMode.focus],
  );

  testWidgets('hint bar shrinks a long hint list instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          bottomNavigationBar: HintBar(
            hints: [
              ([HintButton.a], 'Play'),
              ([HintButton.y], 'Details'),
              ([HintButton.x], 'Search'),
              ([HintButton.start], 'Menu'),
              ([HintButton.l1, HintButton.r1], 'Tabs'),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(HintBar)).height, HintBar.height);
    expect(tester.getSize(find.byType(HintBar)).width, 320);
  });
}
