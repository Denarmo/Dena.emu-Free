// Spec: docs/specs/psx.md (Library), docs/specs/library.md (Import)
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A raw 2352-byte Mode 2 sector: the CD sync header, then mode byte 2.
List<int> rawTrack({int fill = 1}) => [
  0,
  ...List.filled(10, 0xff),
  0,
  0,
  2,
  0,
  2,
  ...List.filled(2352 - 16, fill),
];

void main() {
  group('cue sheet rules', () {
    test('every FILE line, in order, once each', () {
      const sheet =
          'FILE "Game (Track 1).bin" BINARY\r\n'
          '  TRACK 01 MODE2/2352\r\n'
          'file track2.bin binary\n'
          'FILE "Game (Track 1).bin" BINARY\n'
          'REM FILE nope.bin\n';
      expect(cueTrackFiles(sheet), ['Game (Track 1).bin', 'track2.bin']);
      expect(cueTrackFiles('TRACK 01 AUDIO\n'), isEmpty);
    });

    test('every GDI track, skipping the count line', () {
      const gdi =
          '3\r\n'
          '1 0 4 2352 track01.bin 0\r\n'
          '2 600 0 2352 "Track 02.raw" 0\n'
          '3 45000 4 2352 track03.bin 0\n';
      expect(gdiTrackFiles(gdi), [
        'track01.bin',
        'Track 02.raw',
        'track03.bin',
      ]);
      expect(sheetTrackFiles(gdi, gdi: true), hasLength(3));
      expect(sheetTrackFiles('FILE a.bin BINARY', gdi: false), ['a.bin']);
      expect(isDiscSheet('dir/Game.CUE'), isTrue);
      expect(isDiscSheet('Game.gdi'), isTrue);
      expect(isDiscSheet('Game.bin'), isFalse);
    });

    test('track names must stay beside the sheet', () {
      expect(isSafeTrackName('Game (Track 1).bin'), isTrue);
      expect(isSafeTrackName('tracks/t1.bin'), isTrue);
      for (final bad in [
        '',
        '/etc/passwd',
        r'\x.bin',
        r'C:\games\t.bin',
        '../t.bin',
        r'a\..\..\t.bin',
        './t.bin',
      ]) {
        expect(isSafeTrackName(bad), isFalse, reason: bad);
      }
    });

    test('the first track must be a CD data track', () {
      expect(discTrackLooksValid(rawTrack()), isTrue);
      final cooked = List.filled(0x8010, 0)..setAll(0x8001, 'CD001'.codeUnits);
      expect(discTrackLooksValid(cooked), isTrue);
      expect(discTrackLooksValid('hello world'.codeUnits), isFalse);
    });
  });

  group('phone import of a cue set', () {
    late Directory tmp;
    late LibraryDatabase db;
    late Importer importer;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      tmp = await Directory.systemTemp.createTemp('dena_cue');
      db = LibraryDatabase(NativeDatabase.memory());
      importer = Importer(
        db,
        Directory(p.join(tmp.path, 'games')),
        desktop: false,
      );
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    File write(String name, List<int> bytes) =>
        File(p.join(tmp.path, 'in', name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    test('copies the sheet and every track and defaults to PS1', () async {
      final t1 = rawTrack();
      final t2 = List.filled(4704, 7);
      write('Game (Track 1).bin', t1);
      write('Game (Track 2).bin', t2);
      final cue = write(
        'Game (USA).cue',
        ('FILE "Game (Track 1).bin" BINARY\n  TRACK 01 MODE2/2352\n'
                'FILE "Game (Track 2).bin" BINARY\n  TRACK 02 AUDIO\n')
            .codeUnits,
      );
      final out = await importer.importOne(cue);
      expect(out, isA<Imported>());
      final g = (await db.allGames()).single;
      expect(g.system, 'psx');
      expect(g.title, 'Game');
      expect(g.crc32, getCrc32(t1).toRadixString(16).padLeft(8, '0'));
      expect(p.basename(g.path), 'Game (USA).cue');
      expect(p.basename(p.dirname(g.path)), g.sha1);
      final dir = p.dirname(g.path);
      expect(File(p.join(dir, 'Game (Track 1).bin')).readAsBytesSync(), t1);
      expect(File(p.join(dir, 'Game (Track 2).bin')).readAsBytesSync(), t2);
      expect(await importer.importOne(cue), isA<Duplicate>());

      await deleteGameFiles(g, dataDir: tmp.path, keepUserRom: false);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test('finds a track whose case differs from the sheet', () async {
      write('game.bin', rawTrack());
      final cue = write('Game.cue', 'FILE "GAME.BIN" BINARY\n'.codeUnits);
      expect(await importer.importOne(cue), isA<Imported>());
      final g = (await db.allGames()).single;
      expect(File(p.join(p.dirname(g.path), 'GAME.BIN')).existsSync(), isTrue);
    });

    test('a missing track rejects the sheet with its name', () async {
      write('t1.bin', rawTrack());
      final cue = write(
        'Game.cue',
        'FILE t1.bin BINARY\nFILE "t2.bin" BINARY\n'.codeUnits,
      );
      final out = await importer.importOne(cue);
      expect(out, isA<Rejected>());
      expect((out as Rejected).reason, contains('t2.bin'));
      expect(await db.allGames(), isEmpty);
    });

    test('a text track or an unsafe name is not a game', () async {
      write('t.bin', 'not a disc at all'.codeUnits);
      final text = write('Text.cue', 'FILE t.bin BINARY\n'.codeUnits);
      expect(await importer.importOne(text), isA<Rejected>());
      final climb = write('Climb.cue', 'FILE ../t.bin BINARY\n'.codeUnits);
      expect(await importer.importOne(climb), isA<Rejected>());
      expect(await db.allGames(), isEmpty);
    });

    test('a Saturn cue is refused on the phone', () async {
      final sat = List.filled(2352, 0)
        ..setAll(0, [0, ...List.filled(10, 0xff), 0, 0, 2, 0, 1])
        ..setAll(0x10, 'SEGA SEGASATURN'.codeUnits);
      write('s.bin', sat);
      final cue = write('Sat.cue', 'FILE s.bin BINARY\n'.codeUnits);
      final out = await importer.importOne(cue);
      expect(out, isA<Rejected>());
      expect((out as Rejected).reason, contains('Windows and SteamOS'));
    });

    test('a disc track alone asks for the cue', () async {
      final out = await importer.importOne(write('Game.bin', rawTrack()));
      expect(out, isA<Rejected>());
      expect((out as Rejected).reason, contains('.cue'));
      final junk = await importer.importOne(write('junk.bin', [1, 2, 3]));
      expect((junk as Rejected).reason, 'Not a supported game file');
    });

    test('a batch skips the tracks its cue sheets name', () async {
      final t = write('a/Track 1.bin', rawTrack());
      final cue = write('a/Game.cue', 'FILE "TRACK 1.bin" BINARY\n'.codeUnits);
      final other = write('b/Track 1.bin', rawTrack());
      final nes = write('a/x.nes', [0x4e, 0x45, 0x53, 0x1a]);
      expect(await withoutCueTracks([t.path, cue.path, other.path, nes.path]), [
        cue.path,
        other.path,
        nes.path,
      ]);
    });
  });

  group('zipped cue sets', () {
    late Directory tmp;
    late LibraryDatabase db;
    late Directory games;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      tmp = await Directory.systemTemp.createTemp('dena_zcue');
      db = LibraryDatabase(NativeDatabase.memory());
      games = Directory(p.join(tmp.path, 'games'));
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    File zip(String name, Map<String, List<int>> entries) {
      final a = Archive();
      entries.forEach((n, b) => a.addFile(ArchiveFile.bytes(n, b)));
      return File(p.join(tmp.path, 'in', name))
        ..createSync(recursive: true)
        ..writeAsBytesSync(ZipEncoder().encode(a));
    }

    const twoTracks =
        'FILE "Game (Track 1).bin" BINARY\n  TRACK 01 MODE2/2352\n'
        'FILE "Game (Track 2).bin" BINARY\n  TRACK 02 AUDIO\n';

    bool leftovers() => games.existsSync()
        ? games
              .listSync(recursive: true)
              .any((e) => p.basename(e.path).startsWith('.'))
        : false;

    for (final desktop in [true, false]) {
      test('unpacks the sheet and its tracks '
          '(${desktop ? 'desktop' : 'phone'})', () async {
        final importer = Importer(db, games, desktop: desktop);
        final t1 = rawTrack();
        final t2 = List.filled(4704, 7);
        final file = zip('Game (USA).zip', {
          'Game (USA).cue': twoTracks.codeUnits,
          'Game (Track 1).bin': t1,
          'Game (Track 2).bin': t2,
        });
        final out = await (desktop
            ? importer.importInPlace(file)
            : importer.importOne(file));
        expect(out, isA<Imported>());
        expect(out.source, 'Game (USA).zip');
        final g = (await db.allGames()).single;
        expect(g.system, 'psx');
        expect(g.title, 'Game');
        expect(g.fileName, 'Game (USA).cue');
        expect(g.crc32, getCrc32(t1).toRadixString(16).padLeft(8, '0'));
        expect(p.basename(g.path), 'Game (USA).cue');
        expect(p.basename(p.dirname(g.path)), g.sha1);
        final dir = p.dirname(g.path);
        expect(File(p.join(dir, 'Game (Track 1).bin')).readAsBytesSync(), t1);
        expect(File(p.join(dir, 'Game (Track 2).bin')).readAsBytesSync(), t2);
        expect(leftovers(), isFalse);

        // The same zip again is known from its listing, without unpacking.
        final again = await importer.importOne(file);
        expect(again, isA<Duplicate>());
        expect((again as Duplicate).gameId, g.id);
        expect(leftovers(), isFalse);

        // A picked .cue of the same disc is the same game.
        final loose = File(p.join(tmp.path, 'loose', 'Game (USA).cue'))
          ..createSync(recursive: true)
          ..writeAsStringSync(twoTracks);
        File(p.join(loose.parent.path, 'Game (Track 1).bin'))
            .writeAsBytesSync(t1);
        File(p.join(loose.parent.path, 'Game (Track 2).bin'))
            .writeAsBytesSync(t2);
        expect(await importer.importOne(loose), isA<Duplicate>());
      });
    }

    test('a sheet in a folder finds tracks whose case differs', () async {
      final importer = Importer(db, games, desktop: true);
      final out = await importer.importOne(
        zip('g.zip', {
          'Game/': const [],
          '__MACOSX/Game/._game.cue': [1, 2],
          'Game/game.cue': 'FILE "GAME.BIN" BINARY\n'.codeUnits,
          'Game/game.bin': rawTrack(),
        }),
      );
      expect(out, isA<Imported>());
      final g = (await db.allGames()).single;
      expect(File(p.join(p.dirname(g.path), 'GAME.BIN')).existsSync(), isTrue);
    });

    test('a track missing from the zip is named', () async {
      final importer = Importer(db, games, desktop: true);
      final out = await importer.importOne(
        zip('g.zip', {
          'Game.cue': twoTracks.codeUnits,
          'Game (Track 1).bin': rawTrack(),
        }),
      );
      expect(out, isA<Rejected>());
      final reason = (out as Rejected).reason;
      expect(reason, contains('Game (Track 2).bin'));
      expect(reason, contains('zip'));
      expect(await db.allGames(), isEmpty);
      expect(leftovers(), isFalse);
    });

    test('a zip of a text file named .bin is not a game', () async {
      final importer = Importer(db, games, desktop: true);
      final out = await importer.importOne(
        zip('g.zip', {
          'Game.cue': 'FILE t.bin BINARY\n'.codeUnits,
          't.bin': 'not a disc'.codeUnits,
        }),
      );
      expect((out as Rejected).reason, 'Not a supported game file');
      expect(leftovers(), isFalse);
    });

    test('each disc of a multi-disc zip is its own game', () async {
      final importer = Importer(db, games, desktop: true);
      final file = zip('Game.zip', {
        'Game (Disc 1).cue': 'FILE "d1.bin" BINARY\n'.codeUnits,
        'Game (Disc 2).cue': 'FILE "d2.bin" BINARY\n'.codeUnits,
        'd1.bin': rawTrack(fill: 1),
        'd2.bin': rawTrack(fill: 2),
      });
      final outs = await importer.importEach(file, inPlace: true);
      expect(outs, hasLength(2));
      expect(outs, everyElement(isA<Imported>()));
      expect((await db.allGames()).map((g) => g.fileName), [
        'Game (Disc 1).cue',
        'Game (Disc 2).cue',
      ]);
      expect(await importer.importEach(file), everyElement(isA<Duplicate>()));
    });

    test('a zipped GDI is a Dreamcast game on desktop only', () async {
      const gdi = '2\n1 0 4 2352 track01.bin 0\n2 600 0 2352 track02.raw 0\n';
      Map<String, List<int>> entries() => {
        'Game.gdi': gdi.codeUnits,
        'track01.bin': rawTrack(),
        'track02.raw': List.filled(2352, 3),
      };
      final phone = await Importer(
        db,
        games,
        desktop: false,
      ).importOne(zip('p.zip', entries()));
      expect((phone as Rejected).reason, contains('Windows and SteamOS'));
      final pc = await Importer(
        db,
        games,
        desktop: true,
      ).importOne(zip('d.zip', entries()));
      expect(pc, isA<Imported>());
      final g = (await db.allGames()).single;
      expect(g.system, 'dreamcast');
      expect(
        File(p.join(p.dirname(g.path), 'track02.raw')).existsSync(),
        isTrue,
      );
    });

    test('a zip of tracks without the sheet asks for the .cue', () async {
      final importer = Importer(db, games, desktop: true);
      final out = await importer.importOne(zip('g.zip', {'g.bin': rawTrack()}));
      expect((out as Rejected).reason, contains('.cue'));
    });

    test('a zip of one cartridge still unpacks it', () async {
      final importer = Importer(db, games, desktop: true);
      final out = await importer.importOne(
        zip('n.zip', {
          'n.nes': [0x4e, 0x45, 0x53, 0x1a, 1, 2, 3],
        }),
      );
      expect(out, isA<Imported>());
      expect((await db.allGames()).single.system, 'nes');
    });
  });
}
