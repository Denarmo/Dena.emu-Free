// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: brutalist-spec.md 4.2 (library table)
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:flutter_test/flutter_test.dart';

Game _game(
  String title, {
  String system = 'snes',
  String? fileName,
  int playSeconds = 0,
  DateTime? lastPlayedAt,
}) => Game(
  id: title.hashCode,
  system: system,
  title: title,
  searchTitle: searchKey(title),
  fileName: fileName ?? '$title.rom',
  path: '/nowhere',
  sha1: title,
  size: 1,
  crc32: '0',
  addedAt: DateTime(2026),
  lastPlayedAt: lastPlayedAt,
  playSeconds: playSeconds,
  favorite: false,
);

List<String> _titles(List<Game> games) => [for (final g in games) g.title];

void main() {
  final a = _game('Alpha', fileName: 'Alpha (1994) (USA).sfc', playSeconds: 60);
  final b = _game('Beta', system: 'nes', playSeconds: 7200);
  final c = _game(
    'Gamma',
    system: 'gba',
    fileName: 'Gamma [2003].gba',
    lastPlayedAt: DateTime(2026, 10, 1),
  );
  final games = [c, b, a];

  test('sorts by title, system, year, play time and last played', () {
    expect(_titles(sortGames(games, TableSort.title)), [
      'Alpha',
      'Beta',
      'Gamma',
    ]);
    expect(_titles(sortGames(games, TableSort.title, ascending: false)), [
      'Gamma',
      'Beta',
      'Alpha',
    ]);
    expect(_titles(sortGames(games, TableSort.system)), [
      'Beta',
      'Alpha',
      'Gamma',
    ]);
    // Unknown years and never-played games stay last both ways.
    expect(_titles(sortGames(games, TableSort.year)), [
      'Alpha',
      'Gamma',
      'Beta',
    ]);
    expect(_titles(sortGames(games, TableSort.year, ascending: false)), [
      'Gamma',
      'Alpha',
      'Beta',
    ]);
    expect(_titles(sortGames(games, TableSort.playTime, ascending: false)), [
      'Beta',
      'Alpha',
      'Gamma',
    ]);
    expect(_titles(sortGames(games, TableSort.lastPlayed, ascending: false)), [
      'Gamma',
      'Alpha',
      'Beta',
    ]);
  });

  test('the year comes from the file name, else nothing', () {
    expect(gameYear(a), 1994);
    expect(gameYear(c), 2003);
    expect(gameYear(b), isNull);
    expect(gameYear(_game('Quest', fileName: 'Quest (Rev 1999X).sfc')), isNull);
  });

  test('play time and last played read as short columns', () {
    expect(playTime(0), '--');
    expect(playTime(3600 * 14 + 300), '14h 05m');
    final now = DateTime(2026, 10, 18, 9);
    expect(lastPlayed(null, now), '--');
    expect(lastPlayed(DateTime(2026, 10, 18, 1), now), 'today');
    expect(lastPlayed(DateTime(2026, 10, 6), now), '12d');
    expect(lastPlayed(DateTime(2026, 6, 1), now), '4mo');
    expect(lastPlayed(DateTime(2023, 1, 1), now), '3y');
  });

  test('romhacks are told by their names', () {
    expect(isRomhack(_game('Quest', fileName: 'Quest (Hack).sfc')), isTrue);
    expect(isRomhack(a), isFalse);
  });
}
