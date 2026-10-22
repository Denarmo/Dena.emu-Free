import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_roms.dart';

void main() {
  late Directory tmp;
  late LibraryDatabase db;
  late Importer importer;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tmp = await Directory.systemTemp.createTemp('dena_import');
    db = LibraryDatabase(NativeDatabase.memory());
    importer = Importer(db, Directory(p.join(tmp.path, 'games')));
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  File write(String name, List<int> bytes) => File(p.join(tmp.path, 'in', name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  Uint8List zip(Map<String, List<int>> entries) {
    final a = Archive();
    entries.forEach((n, b) => a.addFile(ArchiveFile.bytes(n, b)));
    return Uint8List.fromList(ZipEncoder().encode(a));
  }

  const nesBytes = [0x4e, 0x45, 0x53, 0x1a, 1, 2, 3];

  test('imports a plain ROM into app storage with hashes', () async {
    final out = await importer.importOne(
      write('Hero Quest (USA).nes', nesBytes),
    );
    expect(out, isA<Imported>());
    final g = (await db.watchGames().first).single;
    expect(g.title, 'Hero Quest');
    expect(g.system, 'nes');
    expect(g.sha1, 'd280aaa7d4cf8890bd4ad490fce4d452a9131a96');
    expect(g.crc32, '3c27116a');
    expect(File(g.path).readAsBytesSync(), nesBytes);
    expect(p.split(g.path), containsAllInOrder(['games', 'nes']));
  });

  test('second copy of the same content is a duplicate', () async {
    final rom = fakeRom('a.gba', fill: 9);
    await importer.importOne(write('a.gba', rom));
    expect(await importer.importOne(write('b.gba', rom)), isA<Duplicate>());
    expect(await db.watchGames().first, hasLength(1));
  });

  test('zip with one game is unpacked', () async {
    final sfc = fakeRom('g.sfc', fill: 5);
    final out = await importer.importOne(
      write(
        'pack.zip',
        zip({
          'Some Game [!].sfc': sfc,
          'readme.txt': [0],
        }),
      ),
    );
    expect(out, isA<Imported>());
    final g = (await db.watchGames().first).single;
    expect(g.system, 'snes');
    expect(g.title, 'Some Game');
    expect(File(g.path).readAsBytesSync(), sfc);
  });

  test('rejections carry a reason and do not stop the batch', () async {
    final results = await importer.importAll([
      write('notes.txt', [1]),
      write(
        'two.zip',
        zip({
          'a.nes': [1],
          'b.nes': [2],
        }),
      ),
      write(
        'none.zip',
        zip({
          'a.txt': [1],
        }),
      ),
      write('broken.zip', [1, 2, 3, 4]),
      write('rom.bin', List.filled(0x200, 0)),
      write('ok.gb', fakeRom('ok.gb', fill: 7)),
    ]).toList();
    expect(results.map((r) => r.runtimeType.toString()), [
      'Rejected',
      'Rejected',
      'Rejected',
      'Rejected',
      'Rejected',
      'Imported',
    ]);
    expect((results[1] as Rejected).reason, contains('several'));
    expect((results[3] as Rejected).reason, contains('damaged'));
  });

  test('a text file with a game extension is rejected everywhere', () async {
    final text = 'not a game\n'.codeUnits;
    final copied = await importer.importOne(write('notes.nes', text));
    expect((copied as Rejected).reason, 'Not a supported game file');
    final inPlace = await importer.importInPlace(write('notes.gba', text));
    expect((inPlace as Rejected).reason, 'Not a supported game file');
    final zipped = await importer.importOne(
      write('notes.zip', zip({'notes.gb': text})),
    );
    expect((zipped as Rejected).reason, 'Not a supported game file');
    final disc = await importer.importOne(write('notes.iso', text));
    expect((disc as Rejected).reason, 'Not a supported game file');
    expect(await db.watchGames().first, isEmpty);
    expect(Directory(importer.gamesDir.path).existsSync(), isFalse);
  });

  test('disc images are streamed: same hashes, stored once', () async {
    final disc = List<int>.generate(3 * 1024 * 1024 + 7, (i) => i * 31 & 0xff)
      ..setAll(0, 'MComprHD'.codeUnits);
    final r = await importer.importOne(write('Moon Disc (USA).chd', disc));
    expect(r, isA<Imported>());
    final g = (await db.watchGames().first).single;
    expect(g.system, 'psx');
    expect(g.title, 'Moon Disc');
    expect(g.sha1, sha1Hex(disc));
    expect(g.size, disc.length);
    expect(File(g.path).readAsBytesSync(), disc);
    expect(p.basename(g.path), '${g.sha1}.chd');
    expect(await importer.importOne(write('copy.chd', disc)), isA<Duplicate>());
    final leftovers = Directory(p.dirname(g.path))
        .listSync()
        .where((f) => p.basename(f.path).startsWith('.import-'));
    expect(leftovers, isEmpty);
  });

  test('Genesis is recognised but not imported until it has a core', () async {
    final rom = List<int>.filled(0x200, 0)..setAll(0x100, 'SEGA'.codeUnits);
    final result = await importer.importOne(write('sonic.bin', rom));
    expect((result as Rejected).reason, contains('Genesis'));
    expect(await db.watchGames().first, isEmpty);
  });

  test('deleting a game removes its ROM, battery save and states', () async {
    final dir = Directory.systemTemp.createTempSync('dena_delete');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rom = File(p.join(dir.path, 'games', 'g.gba'))
      ..createSync(recursive: true);
    final srm = File(p.join(dir.path, 'saves', 'abc.srm'))
      ..createSync(recursive: true);
    final slot = File(p.join(dir.path, 'states', 'abc', 'slot1.state'))
      ..createSync(recursive: true);
    final other = File(p.join(dir.path, 'states', 'def', 'auto.state'))
      ..createSync(recursive: true);
    final game = Game(
      id: 1,
      system: 'gba',
      title: 'G',
      searchTitle: 'g',
      fileName: 'g.gba',
      path: rom.path,
      sha1: 'abc',
      size: 0,
      crc32: '0',
      addedAt: DateTime(2026),
      playSeconds: 0,
      favorite: false,
    );
    await deleteGameFiles(game, dataDir: dir.path);
    expect(rom.existsSync(), isFalse);
    expect(srm.existsSync(), isFalse);
    expect(slot.parent.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });
}
