// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Data model)
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../shell/app_dirs.dart';

part 'database.g.dart';

/// Sort orders offered by the Games tab.
enum LibrarySort { recentlyPlayed, title, recentlyAdded }

@DataClassName('Game')
class Games extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get system => text()();
  TextColumn get title => text()();

  /// Lower-cased, diacritic-free title used for search (kept in sync by [LibraryDatabase]).
  TextColumn get searchTitle => text()();
  TextColumn get fileName => text()();
  TextColumn get path => text()();
  TextColumn get sha1 => text().unique()();
  IntColumn get size => integer()();
  TextColumn get crc32 => text()();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
  IntColumn get playSeconds => integer().withDefault(const Constant(0))();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();
  TextColumn get customArtPath => text().nullable()();
}

/// Cheat codes per game (docs/specs/cheats.md).
@DataClassName('Cheat')
class Cheats extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get gameId => integer().references(Games, #id)();
  TextColumn get name => text()();

  /// Normalised codes, one per line.
  TextColumn get code => text()();
  TextColumn get format => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime()();
}

@DriftDatabase(tables: [Games, Cheats])
class LibraryDatabase extends _$LibraryDatabase {
  LibraryDatabase(super.e);

  /// The on-device database: app-private storage on Android and iOS, the
  /// card's data folder on a handheld ([libraryDatabaseDir]), where
  /// path_provider has no documents folder.
  factory LibraryDatabase.open() {
    final dir = libraryDatabaseDir();
    return LibraryDatabase(
      driftDatabase(
        name: 'library',
        native: dir == null
            ? null
            : DriftNativeOptions(
                databaseDirectory: () async =>
                    (await dir.create(recursive: true)).path,
                // sqlite3's default (/tmp) is fine there.
                tempDirectoryPath: () async => null,
              ),
      ),
    );
  }

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(
        'CREATE INDEX IF NOT EXISTS games_search ON games (search_title)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS games_last_played ON games (last_played_at)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(cheats);
    },
  );

  /// The game with [sha1] (lower-case hex), or null (shortcuts.md).
  Future<Game?> gameBySha1(String sha1) =>
      (select(games)..where((g) => g.sha1.equals(sha1))).getSingleOrNull();

  /// Every game.
  Future<List<Game>> allGames() => select(games).get();

  /// The game with [id], or null.
  Future<Game?> gameById(int id) =>
      (select(games)..where((g) => g.id.equals(id))).getSingleOrNull();

  /// Adds a game unless one with the same SHA-1 exists. Returns its id, or null
  /// for a duplicate.
  Future<int?> addGame({
    required String system,
    required String title,
    required String fileName,
    required String path,
    required String sha1,
    required int size,
    required String crc32,
    DateTime? addedAt,
  }) async {
    final existing = await (select(
      games,
    )..where((g) => g.sha1.equals(sha1))).getSingleOrNull();
    if (existing != null) return null;
    return into(games).insert(
      GamesCompanion.insert(
        system: system,
        title: title,
        searchTitle: searchKey(title),
        fileName: fileName,
        path: path,
        sha1: sha1,
        size: size,
        crc32: crc32,
        addedAt: addedAt ?? DateTime.now(),
      ),
    );
  }

  /// Games matching an optional [system] filter and [query], in [sort] order.
  Stream<List<Game>> watchGames({
    String? system,
    String query = '',
    LibrarySort sort = LibrarySort.recentlyPlayed,
  }) {
    final q = select(games);
    if (system != null) q.where((g) => g.system.equals(system));
    final key = searchKey(query);
    if (key.isNotEmpty) q.where((g) => g.searchTitle.contains(key));
    q.orderBy(switch (sort) {
      LibrarySort.recentlyPlayed => [
        (g) => OrderingTerm(
          expression: g.lastPlayedAt,
          mode: OrderingMode.desc,
          nulls: NullsOrder.last,
        ),
        (g) => OrderingTerm(expression: g.searchTitle),
      ],
      LibrarySort.title => [(g) => OrderingTerm(expression: g.searchTitle)],
      LibrarySort.recentlyAdded => [
        (g) => OrderingTerm(expression: g.addedAt, mode: OrderingMode.desc),
      ],
    });
    return q.watch();
  }

  /// Systems that have at least one game, for the filter chips.
  Stream<List<String>> watchSystems() {
    final q = selectOnly(games, distinct: true)..addColumns([games.system]);
    return q.map((row) => row.read(games.system)!).watch();
  }

  /// The most recently played game, for "Continue playing".
  Stream<Game?> watchLastPlayed() =>
      (select(games)
            ..where((g) => g.lastPlayedAt.isNotNull())
            ..orderBy([
              (g) => OrderingTerm(
                expression: g.lastPlayedAt,
                mode: OrderingMode.desc,
              ),
            ])
            ..limit(1))
          .watchSingleOrNull();

  Future<void> rename(int id, String title) =>
      (update(games)..where((g) => g.id.equals(id))).write(
        GamesCompanion(
          title: Value(title),
          searchTitle: Value(searchKey(title)),
        ),
      );

  /// Sets or clears (null) the game's custom cover.
  Future<void> setCustomArt(int id, String? path) =>
      (update(games)..where((t) => t.id.equals(id))).write(
        GamesCompanion(customArtPath: Value(path)),
      );

  Future<void> setFavorite(int id, bool favorite) =>
      (update(games)..where((g) => g.id.equals(id))).write(
        GamesCompanion(favorite: Value(favorite)),
      );

  Future<void> recordPlay(int id, {required DateTime at, int seconds = 0}) =>
      customUpdate(
        'UPDATE games SET last_played_at = ?, play_seconds = play_seconds + ? WHERE id = ?',
        variables: [Variable(at), Variable(seconds), Variable(id)],
        updates: {games},
      );

  /// Deletes the row and returns it, so the caller can remove its files
  /// (ROM copy, saves, states).
  Future<Game?> deleteGame(int id) async {
    final g = await (select(
      games,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (g != null) {
      await transaction(() async {
        await (delete(cheats)..where((t) => t.gameId.equals(id))).go();
        await (delete(games)..where((t) => t.id.equals(id))).go();
      });
    }
    return g;
  }

  /// A game's cheats, oldest first.
  Stream<List<Cheat>> watchCheats(int gameId) =>
      (select(cheats)
            ..where((t) => t.gameId.equals(gameId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .watch();

  Future<List<Cheat>> cheatsFor(int gameId) =>
      (select(cheats)
            ..where((t) => t.gameId.equals(gameId))
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  Future<int> addCheat({
    required int gameId,
    required String name,
    required String code,
    required String format,
    required DateTime createdAt,
  }) => into(cheats).insert(
    CheatsCompanion.insert(
      gameId: gameId,
      name: name,
      code: code,
      format: format,
      createdAt: createdAt,
    ),
  );

  Future<void> setCheatEnabled(int id, bool enabled) =>
      (update(cheats)..where((t) => t.id.equals(id))).write(
        CheatsCompanion(enabled: Value(enabled)),
      );

  Future<void> deleteCheat(int id) =>
      (delete(cheats)..where((t) => t.id.equals(id))).go();
}

const _folds = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'æ': 'ae',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ß': 'ss',
  'œ': 'oe',
};

/// Case- and diacritic-insensitive search key.
String searchKey(String s) {
  final lower = s.toLowerCase().trim();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final c = String.fromCharCode(r);
    b.write(_folds[c] ?? c);
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ');
}
