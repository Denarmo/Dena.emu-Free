// Spec: docs/specs/sd-card.md (Card library)
import 'dart:io';

import 'package:dena_emu/src/library/card_library.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_roms.dart';

void main() {
  late Directory card;
  late LibraryDatabase db;
  late Importer importer;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    card = await Directory.systemTemp.createTemp('dena_card');
    db = LibraryDatabase(NativeDatabase.memory());
    importer = Importer(db, Directory(p.join(card.path, 'data', 'games')));
  });
  tearDown(() async {
    await db.close();
    await card.delete(recursive: true);
  });

  File rom(String rel, List<int> bytes) =>
      File(p.joinAll([card.path, 'Roms', ...rel.split('/')]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  test('the Roms folder is the card', () {
    expect(cardRomsDir({'DENA_CARD': '/mnt/card'})?.path, '/mnt/card/Roms');
    expect(cardRomsDir(const {}), isNull);
  });

  test(
    'games are added in place, once; junk and hidden files are skipped',
    () async {
      final nes = rom('nes/Alpha Quest (USA).nes', fakeRom('a.nes', fill: 1));
      rom('gba/Beta Racer.gba', fakeRom('b.gba', fill: 2));
      rom('nes/._Alpha Quest (USA).nes', fakeRom('c.nes', fill: 3));
      rom('nes/readme.txt', [1, 2, 3]);
      final roms = Directory(p.join(card.path, 'Roms'));

      final first = await scanCardRoms(roms, db, importer);
      expect(first.added, 2);
      expect(first.rejected, ['readme.txt']);
      final games = await db.allGames();
      expect(
        games.map((g) => g.title),
        containsAll(['Alpha Quest', 'Beta Racer']),
      );
      // In place: no copy in the app's games folder.
      expect(games.firstWhere((g) => g.system == 'nes').path, nes.path);
      expect(
        Directory(p.join(card.path, 'data', 'games')).existsSync(),
        isFalse,
      );

      // A second scan reads nothing it already has.
      final second = await scanCardRoms(roms, db, importer);
      expect(second.added, 0);
      expect(second.skipped, 0);
      expect(await db.allGames(), hasLength(2));

      // A copy of a known game under another name is a duplicate.
      rom('nes/copy.nes', fakeRom('a.nes', fill: 1));
      final third = await scanCardRoms(roms, db, importer);
      expect(third.skipped, 1);
    },
  );

  test('no Roms folder is an empty scan', () async {
    final s = await scanCardRoms(
      Directory(p.join(card.path, 'Roms')),
      db,
      importer,
    );
    expect(s.added, 0);
  });
}
