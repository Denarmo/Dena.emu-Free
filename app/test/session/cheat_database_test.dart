// SPDX-License-Identifier: GPL-3.0-or-later
// Tests for the cheat database: `.cht` parsing, index matching, popularity
// ranking and the download/cache behaviour. Spec: docs/specs/cheats.md
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/session/cheat_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Game game({
  String system = 'nes',
  String fileName = 'Foo.nes',
  String crc32 = 'deadbeef',
}) => Game(
  id: 1,
  system: system,
  title: 'Foo',
  searchTitle: 'foo',
  fileName: fileName,
  path: '/x/$fileName',
  sha1: 'abc',
  size: 1,
  crc32: crc32,
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

void main() {
  group('parseCht', () {
    test('reads the header, quoted values and splits + into lines', () {
      const text = '''
cheats = 2
cheat0_desc = "Infinite Health"
cheat0_code = "SXIOPO+YEUZUGAA"
cheat1_desc = "Another"
cheat1_code = "075A:05"
''';
      final cheats = parseCht('nes', text);
      expect(cheats, hasLength(2));

      final c = cheats.first;
      expect(c.name, 'Infinite Health');
      expect(c.code, 'SXIOPO\nYEUZUGAA');
      expect(c.format, 'Game Genie');
      expect(c.score, 100);
      expect(c.master, isFalse);

      expect(cheats[1].name, 'Another');
      expect(cheats[1].code, '075A:05');
      expect(cheats[1].format, 'Raw');
    });

    test('a rejected code keeps its raw lines and the device label', () {
      const text = '''
cheats = 1
cheat0_desc = "Level 99"
cheat0_code = "00000000+0002"
''';
      final labelled = parseCht('gba', text, device: 'Code Breaker').single;
      expect(labelled.code, '00000000\n0002');
      expect(labelled.format, 'Code Breaker');

      final unlabelled = parseCht('gba', text).single;
      expect(unlabelled.code, '00000000\n0002');
      expect(unlabelled.format, 'Database');
    });

    test('a valid NES Game Genie code keeps the Game Genie format', () {
      const text = '''
cheats = 1
cheat0_desc = "Lots of lives"
cheat0_code = "SZNXGUVV"
''';
      final c = parseCht('nes', text).single;
      expect(c.code, 'SZNXGUVV');
      expect(c.format, 'Game Genie');
    });

    test('codes containing ? and empty codes are skipped', () {
      const text = '''
cheats = 2
cheat0_desc = "Needs a value"
cheat0_code = "075A?01:05"
cheat1_desc = "Empty"
cheat1_code = ""
''';
      expect(parseCht('nes', text), isEmpty);
    });

    test('PSP splits _L entries into one line each', () {
      const text = '''
cheats = 1
cheat0_desc = "Max Money"
cheat0_code = "_L 0x0042B144 0x00000009 _L 0x0042C6C4 0x00000009"
''';
      final c = parseCht('psp', text).single;
      expect(c.code, '0x0042B144 0x00000009\n0x0042C6C4 0x00000009');
      expect(c.format, 'CWCheat');
    });

    test('a quoted header and two spaces around = still parse', () {
      const text = '''
cheats = "7"
cheat0_desc =  "Infinite Health"
cheat0_code =  "_L 0x0042B144 0x00000009"
''';
      final c = parseCht('psp', text).single;
      expect(c.name, 'Infinite Health');
      expect(c.code, '0x0042B144 0x00000009');
      expect(c.format, 'CWCheat');
    });

    test('a "Must Be On" description is a master code with score 0', () {
      const text = '''
cheats = 1
cheat0_desc = "Enable Code (Must Be On)"
cheat0_code = "SXIOPO"
''';
      final c = parseCht('nes', text).single;
      expect(c.master, isTrue);
      expect(c.score, 0);
    });
  });

  group('deviceOf / baseOf', () {
    test('detects a known device suffix and strips it', () {
      expect(deviceOf('Game (USA) (Game Genie)'), 'Game Genie');
      expect(baseOf('Game (USA) (Game Genie)'), 'Game (USA)');
    });

    test('a region tag is not a device and leaves the name alone', () {
      expect(deviceOf('Game (USA)'), isNull);
      expect(baseOf('Game (USA)'), 'Game (USA)');
    });
  });

  group('looseKey', () {
    test('drops tags, case and punctuation', () {
      expect(
        looseKey('Pokemon - Emerald Version (USA, Europe)'),
        'pokemonemeraldversion',
      );
    });
  });

  group('CheatDbIndex.match', () {
    test('an exact name matches', () {
      final index = CheatDbIndex.parse('nes\tFoo (USA)');
      expect(index.match('nes', 'Foo (USA)'), ['Foo (USA)']);
    });

    test('the name and its device-suffixed files are all returned sorted', () {
      final index = CheatDbIndex.parse(
        'nes\tFoo (USA) (Game Genie)\nnes\tFoo (USA)',
      );
      expect(index.match('nes', 'Foo (USA)'), [
        'Foo (USA)',
        'Foo (USA) (Game Genie)',
      ]);
    });

    test('falls back to the cleaned key when there is no exact hit', () {
      final index = CheatDbIndex.parse('nes\tFoo Bar (USA)');
      expect(index.match('nes', 'Foo-Bar'), ['Foo Bar (USA)']);
    });

    test('prefers the loose file sharing the most region tags', () {
      final index = CheatDbIndex.parse('nes\tFoo (Japan)\nnes\tFoo (USA)');
      expect(index.match('nes', 'Foo (USA, Europe)'), ['Foo (USA)']);
    });

    test('region tags in [] are understood (PSP-style names)', () {
      final index = CheatDbIndex.parse(
        'psp\tFoo [US] [ULUS-1]\npsp\tFoo [JP] [ULJM-1]',
      );
      expect(index.match('psp', 'Foo (USA)'), ['Foo [US] [ULUS-1]']);
    });

    test('a wider-region device file joins the exact name, other regions '
        'and variants do not', () {
      final index = CheatDbIndex.parse(
        'snes\tZelda (USA)\n'
        'snes\tZelda (USA, Europe) (Game Genie)\n'
        'snes\tZelda (Japan)\n'
        'snes\tZelda (World) (Action Replay)\n'
        'snes\tZelda (Rumbles)',
      );
      expect(index.match('snes', 'Zelda (USA)'), [
        'Zelda (USA)',
        'Zelda (USA, Europe) (Game Genie)',
      ]);
    });

    test('unknown systems and no matches return empty', () {
      final index = CheatDbIndex.parse('nes\tFoo (USA)');
      expect(index.match('genesis', 'Foo (USA)'), isEmpty);
      expect(index.match('nes', 'Bar'), isEmpty);
    });
  });

  group('popularityScore', () {
    test('scores each spec category', () {
      expect(popularityScore('Infinite Health'), 100);
      expect(popularityScore('Invincibility'), 95);
      expect(popularityScore('Infinite Lives'), 90);
      expect(popularityScore('Max Money'), 85);
      expect(popularityScore('Have All Items'), 75);
      expect(popularityScore('Moon Jump'), 55);
      expect(popularityScore('Change Color'), 0);
    });

    test('a player-2 cheat loses 10 points', () {
      expect(popularityScore('Infinite Health P2'), 90);
    });
  });

  group('popular', () {
    DbCheat cheat(String name, int score) =>
        DbCheat(name: name, code: 'c', format: 'Raw', score: score);

    test('keeps the top 5, ties in list order, skipping score 0', () {
      final cheats = [
        cheat('a', 50),
        cheat('b', 90),
        cheat('c', 90),
        cheat('d', 100),
        cheat('e', 0),
        cheat('f', 70),
        cheat('g', 60),
      ];
      expect(popular(cheats).map((c) => c.name), ['d', 'b', 'c', 'f', 'g']);
    });
  });

  group('CheatDatabase', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('cheatdb_test'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    const indexTsv = 'nes\tFoo (USA)';
    const namesTsv = 'nes\tdeadbeef\tFoo (USA)';
    const chtText = '''
cheats = 2
cheat0_desc = "Enable Code (Must Be On)"
cheat0_code = "SXIOPO"
cheat1_desc = "Infinite Health"
cheat1_code = "YEUZUGAA"
''';

    test('downloads once then reads the cache', () async {
      var fetches = 0;
      final db = CheatDatabase(
        tmp.path,
        loadIndex: () async => CheatDbIndex.parse(indexTsv),
        loadNames: () async => BoxArtIndex.parse(namesTsv),
        fetch: (url) async {
          fetches++;
          return utf8.encode(chtText);
        },
      );

      final first = await db.cheatsFor(game());
      expect(fetches, 1);
      expect(first.cheats, hasLength(2));

      final second = await db.cheatsFor(game());
      expect(fetches, 1);
      expect(second.cheats.map((c) => c.code), first.cheats.map((c) => c.code));
      expect(
        File(p.join(tmp.path, 'cheats', 'nes', 'Foo (USA).cht')).existsSync(),
        isTrue,
      );
    });

    test('a failed download throws and writes no file', () async {
      final db = CheatDatabase(
        tmp.path,
        loadIndex: () async => CheatDbIndex.parse(indexTsv),
        loadNames: () async => BoxArtIndex.parse(namesTsv),
        fetch: (url) async => null,
      );

      await expectLater(
        db.cheatsFor(game()),
        throwsA(isA<CheatDownloadException>()),
      );
      final file = File(p.join(tmp.path, 'cheats', 'nes', 'Foo (USA).cht'));
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('an unmatched game never calls fetch', () async {
      var fetches = 0;
      final db = CheatDatabase(
        tmp.path,
        loadIndex: () async => CheatDbIndex.parse(indexTsv),
        loadNames: () async => BoxArtIndex.parse(namesTsv),
        fetch: (url) async {
          fetches++;
          return const [];
        },
      );

      final lookup = await db.cheatsFor(
        game(crc32: 'ffffffff', fileName: 'Bar.nes'),
      );
      expect(lookup.cheats, isEmpty);
      expect(fetches, 0);
    });

    test('mastersOf returns the file master codes for other cheats', () async {
      final db = CheatDatabase(
        tmp.path,
        loadIndex: () async => CheatDbIndex.parse(indexTsv),
        loadNames: () async => BoxArtIndex.parse(namesTsv),
        fetch: (url) async => utf8.encode(chtText),
      );

      final lookup = await db.cheatsFor(game());
      final master = lookup.cheats.firstWhere((c) => c.master);
      final normal = lookup.cheats.firstWhere((c) => !c.master);
      expect(lookup.mastersOf(normal), [master]);
      expect(lookup.mastersOf(master), isEmpty);
    });
  });
}
