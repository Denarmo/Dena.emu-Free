import 'package:dena_emu/src/library/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LibraryDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = LibraryDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<int> add(
    String title,
    String system,
    String sha1, {
    DateTime? at,
  }) async => (await db.addGame(
    system: system,
    title: title,
    fileName: '$title.rom',
    path: '/games/$sha1',
    sha1: sha1,
    size: 1,
    crc32: '00000000',
    addedAt: at,
  ))!;

  test('duplicates by SHA-1 are skipped', () async {
    await add('Alpha', 'nes', 'a');
    expect(
      await db.addGame(
        system: 'nes',
        title: 'Alpha copy',
        fileName: 'x',
        path: 'p',
        sha1: 'a',
        size: 1,
        crc32: '0',
      ),
      isNull,
    );
  });

  test('search is case- and diacritic-insensitive', () async {
    await add('Pokémon Café', 'gba', 'a');
    await add('Other', 'gba', 'b');
    final r = await db.watchGames(query: 'POKEMON caf').first;
    expect(r.map((g) => g.title), ['Pokémon Café']);
  });

  test('system filter and title sort', () async {
    await add('Zeta', 'snes', 'a');
    await add('Beta', 'snes', 'b');
    await add('Alpha', 'nes', 'c');
    final r = await db
        .watchGames(system: 'snes', sort: LibrarySort.title)
        .first;
    expect(r.map((g) => g.title), ['Beta', 'Zeta']);
    expect((await db.watchSystems().first).toSet(), {'snes', 'nes'});
  });

  test('recently played first, then never played by title', () async {
    final a = await add('Alpha', 'nes', 'a');
    await add('Beta', 'nes', 'b');
    final c = await add('Gamma', 'nes', 'c');
    await db.recordPlay(a, at: DateTime(2026, 1, 1), seconds: 30);
    await db.recordPlay(c, at: DateTime(2026, 2, 1), seconds: 5);
    final r = await db.watchGames().first;
    expect(r.map((g) => g.title), ['Gamma', 'Alpha', 'Beta']);
    expect((await db.watchLastPlayed().first)!.title, 'Gamma');
    await db.recordPlay(a, at: DateTime(2026, 3, 1), seconds: 10);
    final alpha = (await db.watchGames(query: 'alpha').first).single;
    expect(alpha.playSeconds, 40);
  });

  test('recently added sort, rename, favourite, delete', () async {
    final a = await add('Alpha', 'nes', 'a', at: DateTime(2026, 1, 1));
    await add('Beta', 'nes', 'b', at: DateTime(2026, 2, 1));
    expect(
      (await db.watchGames(sort: LibrarySort.recentlyAdded).first).first.title,
      'Beta',
    );
    await db.rename(a, 'Ålpha Prime');
    expect((await db.watchGames(query: 'alpha prime').first).single.id, a);
    await db.setFavorite(a, true);
    expect((await db.watchGames(query: 'alpha').first).single.favorite, isTrue);
    final deleted = await db.deleteGame(a);
    expect(deleted!.path, '/games/a');
    expect(await db.watchGames().first, hasLength(1));
  });

  test('search key folds diacritics and whitespace', () {
    expect(searchKey('  Ñandú   Æther '), 'nandu aether');
  });

  test('cheats are stored per game and deleted with it', () async {
    Future<int> game(String sha) async => (await db.addGame(
      system: 'nes',
      title: sha,
      fileName: '$sha.nes',
      path: '/x/$sha',
      sha1: sha,
      size: 1,
      crc32: '0',
      addedAt: DateTime(2026),
    ))!;
    final a = await game('a'), b = await game('b');
    final id = await db.addCheat(
      gameId: a,
      name: 'Lives',
      code: 'SXIOPO',
      format: 'Game Genie',
      createdAt: DateTime(2026),
    );
    await db.addCheat(
      gameId: b,
      name: 'Other',
      code: 'AAAAAA',
      format: 'Game Genie',
      createdAt: DateTime(2026),
    );
    await db.setCheatEnabled(id, false);
    expect((await db.cheatsFor(a)).single.enabled, isFalse);
    await db.deleteGame(a);
    expect(await db.cheatsFor(a), isEmpty);
    expect(await db.cheatsFor(b), hasLength(1));
  });
}
