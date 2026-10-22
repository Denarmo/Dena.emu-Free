// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat database browser sheet. Spec: docs/specs/cheats.md (Cheat database)
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/session/cheat_browser.dart';
import 'package:dena_emu/src/session/cheat_database.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

DbCheat cheat(String name, String code, {String format = 'Code Breaker'}) =>
    DbCheat(
      name: name,
      code: code,
      format: format,
      score: popularityScore(name),
      master: name.contains('Must Be On'),
    );

final master = cheat('Enable Code (Must Be On)', '00000000\n0002');
final sample = [
  master,
  cheat('Infinite Health', '82003DF4 0063'),
  cheat('Change Hair Color', '82003E00 0001'),
  cheat('Max Money', '83001000 FFFF'),
  cheat('Have All Items', '83001100 FFFF'),
  cheat('Infinite Health P2', '82003EF4 0063'),
  cheat('Walk Through Walls', '82004000 0001'),
  cheat('Start On Level 5', '33001200 0005'),
];

/// Serves a fixed lookup (or a failure) without files or network.
class FakeCheatDb extends CheatDatabase {
  FakeCheatDb({this.cheats = const [], this.fail = false})
    : super(
        '/nowhere',
        loadIndex: () async => CheatDbIndex.parse(''),
        loadNames: () async => BoxArtIndex.parse(''),
      );

  List<DbCheat> cheats;
  bool fail;
  int lookups = 0;

  @override
  Future<CheatLookup> cheatsFor(Game game) async {
    lookups++;
    if (fail) throw const CheatDownloadException('x');
    return CheatLookup(cheats, {
      for (final c in cheats)
        if (!c.master) c: [master],
    });
  }
}

class Applied {
  final calls = <List<String>>[];
  Future<void> call(List<String> codes) async => calls.add(codes);
}

Widget browserApp(
  LibraryDatabase db,
  Game game,
  CheatDatabase database,
  Applied applied,
) => DenaApp(
  home: Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => CheatBrowserSheet(
            db: db,
            game: game,
            database: database,
            apply: applied.call,
            clock: () => DateTime(2026, 10, 17),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

Future<void> closeDb(WidgetTester tester, LibraryDatabase db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(Duration.zero);
  await tester.runAsync(db.close);
}

Future<(LibraryDatabase, Game)> gbaGame(WidgetTester tester) async {
  final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
  final game = (await tester.runAsync(db.select(db.games).getSingle))!;
  return (db, game);
}

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await settle(tester);
}

/// The rows named [name] (one in Popular, one in All); a press toggles.
Finder tileSwitch(String name) => find.text(name);

/// Whether every row named [name] shows `[x]`.
bool allOn(WidgetTester tester, String name) {
  final marks = [
    for (final e in find.text('[x]').evaluate())
      tester.getCenter(find.byWidget(e.widget)).dy,
  ];
  return find.text(name).evaluate().every((e) {
    final dy = tester.getCenter(find.byWidget(e.widget)).dy;
    return marks.any((m) => (m - dy).abs() < 1);
  });
}

void main() {
  testScreens('cheat browser', (tester, screen, mode) async {
    final (db, game) = await gbaGame(tester);
    await tester.runAsync(
      () => db.addCheat(
        gameId: game.id,
        name: 'Max Money',
        code: '83001000 FFFF',
        format: 'Code Breaker',
        createdAt: DateTime(2026),
      ),
    );
    await tester.pumpWidget(
      browserApp(db, game, FakeCheatDb(cheats: sample), Applied()),
    );
    await open(tester);
    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('All cheats (8)'), findsOneWidget);
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile('../${goldenName('cheat_browser', screen, mode)}'),
    );
    await closeDb(tester, db);
  });

  testWidgets('popular lists the top five by score, masters excluded', (
    tester,
  ) async {
    final (db, game) = await gbaGame(tester);
    await tester.pumpWidget(
      browserApp(db, game, FakeCheatDb(cheats: sample), Applied()),
    );
    await open(tester);
    final known = {for (final c in sample) c.name};
    final names = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(BrutalTable).first,
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .where(known.contains)
        .toList();
    expect(names, [
      'Infinite Health',
      'Infinite Health P2',
      'Max Money',
      'Have All Items',
      'Walk Through Walls',
    ]);
    await closeDb(tester, db);
  });

  testWidgets('turning a cheat on adds it with its master code', (
    tester,
  ) async {
    final (db, game) = await gbaGame(tester);
    final applied = Applied();
    await tester.pumpWidget(
      browserApp(db, game, FakeCheatDb(cheats: sample), applied),
    );
    await open(tester);
    await tester.tap(tileSwitch('Infinite Health').first);
    await settle(tester);
    expect(applied.calls.last, ['00000000+0002', '82003DF4 0063']);
    final stored = (await tester.runAsync(() => db.cheatsFor(game.id)))!;
    expect(stored.map((c) => c.name), [
      'Enable Code (Must Be On)',
      'Infinite Health',
    ]);
    expect(stored.last.format, 'Code Breaker');
    // Both copies (Popular and All) show it on.
    expect(find.text('Infinite Health'), findsNWidgets(2));
    expect(allOn(tester, 'Infinite Health'), isTrue);

    await tester.tap(tileSwitch('Infinite Health').first);
    await settle(tester);
    expect(applied.calls.last, ['00000000+0002']);
    final left = (await tester.runAsync(() => db.cheatsFor(game.id)))!;
    expect(left.map((c) => c.name), ['Enable Code (Must Be On)']);
    await closeDb(tester, db);
  });

  testWidgets('a disabled stored copy is re-enabled, not duplicated', (
    tester,
  ) async {
    final (db, game) = await gbaGame(tester);
    await tester.runAsync(() async {
      final id = await db.addCheat(
        gameId: game.id,
        name: 'Max Money',
        code: '83001000 FFFF',
        format: 'Code Breaker',
        createdAt: DateTime(2026),
      );
      await db.setCheatEnabled(id, false);
    });
    final applied = Applied();
    await tester.pumpWidget(
      browserApp(
        db,
        game,
        FakeCheatDb(cheats: [cheat('Max Money', '83001000 FFFF')]),
        applied,
      ),
    );
    await open(tester);
    await tester.tap(tileSwitch('Max Money').first);
    await settle(tester);
    final stored = (await tester.runAsync(() => db.cheatsFor(game.id)))!;
    expect(stored.where((c) => c.name == 'Max Money'), hasLength(1));
    expect(applied.calls.last, contains('83001000 FFFF'));
    await closeDb(tester, db);
  });

  testWidgets('search filters the list and hides Popular', (tester) async {
    final (db, game) = await gbaGame(tester);
    await tester.pumpWidget(
      browserApp(db, game, FakeCheatDb(cheats: sample), Applied()),
    );
    await open(tester);
    await tester.enterText(find.byType(EditableText), 'health');
    await tester.pumpAndSettle();
    expect(find.text('Popular'), findsNothing);
    expect(find.text('All cheats (2)'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No cheats match "zzz".'), findsOneWidget);
    await closeDb(tester, db);
  });

  testWidgets('no cheats and download failure with retry', (tester) async {
    final (db, game) = await gbaGame(tester);
    final database = FakeCheatDb(fail: true);
    await tester.pumpWidget(browserApp(db, game, database, Applied()));
    await open(tester);
    expect(find.textContaining("Couldn't download cheats"), findsOneWidget);
    database.fail = false;
    await tester.tap(find.text('RETRY'));
    await settle(tester);
    expect(database.lookups, 2);
    expect(
      find.text('No cheats for this game in the database.'),
      findsOneWidget,
    );
    await closeDb(tester, db);
  });
}
