// Spec: docs/specs/desktop-library.md
import 'dart:async';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/desktop_files.dart';
import 'package:dena_emu/src/library/game_folders.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/shell/app_dirs.dart';
import 'package:dena_emu/src/shell/platform_features.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_roms.dart';

void main() {
  late Directory tmp;
  late LibraryDatabase db;
  late Importer importer;
  late StreamController<FileSystemEvent> events;
  late List<String> watched;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tmp = await Directory.systemTemp.createTemp('dena_folders');
    db = LibraryDatabase(NativeDatabase.memory());
    importer = Importer(db, Directory(p.join(tmp.path, 'data', 'games')));
    events = StreamController<FileSystemEvent>.broadcast();
    watched = [];
  });
  tearDown(() async {
    await events.close();
    await db.close();
    await tmp.delete(recursive: true);
  });

  File rom(String rel, int fill) =>
      File(p.joinAll([tmp.path, ...rel.split('/')]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(fakeRom(rel, fill: fill));

  String dir(String rel) => p.joinAll([tmp.path, ...rel.split('/')]);

  GameFolders folders({List<String> fixed = const []}) => GameFolders(
    file: File(p.join(tmp.path, 'data', 'folders.json')),
    db: db,
    importer: importer,
    fixed: fixed,
    debounce: const Duration(milliseconds: 10),
    watcher: (d) {
      watched.add(d.path);
      return events.stream;
    },
  );

  test('adding a folder adds its games in place and remembers it', () async {
    final nes = rom('Games/NES/Alpha Quest (USA).nes', 1);
    rom('Games/GBA/Beta Racer.gba', 2);
    rom('Games/.hidden/Gamma.gba', 3);
    final f = folders();
    final s = await f.add(dir('Games'));
    expect(s.added, 2);
    final games = await db.allGames();
    expect(games.firstWhere((g) => g.system == 'nes').path, nes.path);
    // No copy in the app's games folder.
    expect(Directory(p.join(tmp.path, 'data', 'games')).existsSync(), isFalse);

    final again = folders();
    await again.load();
    expect(again.folders, [dir('Games')]);
  });

  test('a folder inside a watched one is not added twice; an outer one '
      'replaces it', () async {
    rom('Games/NES/a.nes', 1);
    final f = folders();
    await f.add(dir('Games/NES'));
    await f.add(dir('Games/NES'));
    expect(f.folders, [dir('Games/NES')]);
    await f.add(dir('Games'));
    expect(f.folders, [dir('Games')]);
    await f.add(dir('Games/NES'));
    expect(f.folders, [dir('Games')]);
  });

  test('changes rescan the folder: new games join, gone ones leave', () async {
    rom('Games/a.nes', 1);
    final f = folders()..startWatching();
    await f.add(dir('Games'));
    expect(watched, [dir('Games')]);
    final b = rom('Games/b.gba', 2);
    File(dir('Games/a.nes')).deleteSync();
    events.add(FileSystemCreateEvent(b.path, false));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (f.scanning) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final games = await db.allGames();
    expect(games.map((g) => g.path), [b.path]);
    f.dispose();
  });

  test('an unplugged folder keeps its games', () async {
    rom('Drive/a.nes', 1);
    final f = folders();
    await f.add(dir('Drive'));
    Directory(dir('Drive')).renameSync(dir('Elsewhere'));
    final s = await f.scanAll();
    expect(s.removed, 0);
    expect(await db.allGames(), hasLength(1));
  });

  test(
    'a deleted game is not added again until its folder is re-added',
    () async {
      final a = rom('Games/a.nes', 1);
      final f = folders();
      await f.add(dir('Games'));
      final g = (await db.allGames()).single;
      await db.deleteGame(g.id);
      await deleteGameFiles(g, dataDir: dir('data'), keepUserRom: true);
      await f.forget(g.path);
      expect(a.existsSync(), isTrue, reason: "the user's file stays");
      expect((await f.scanAll()).added, 0);

      final reloaded = folders();
      await reloaded.load();
      expect((await reloaded.scanAll()).added, 0);
      await reloaded.remove(dir('Games'));
      expect((await reloaded.add(dir('Games'))).added, 1);
    },
  );

  test('removing a folder takes its games out but keeps the files', () async {
    final a = rom('Games/a.nes', 1);
    rom('Other/b.gba', 2);
    final f = folders();
    await f.add(dir('Games'));
    await f.add(dir('Other'));
    expect(await f.remove(dir('Games')), 1);
    expect(f.folders, [dir('Other')]);
    expect((await db.allGames()).single.system, 'gba');
    expect(a.existsSync(), isTrue);
  });

  test(
    'the portable Roms folder is always scanned and cannot be removed',
    () async {
      rom('Dena/Roms/nes/a.nes', 1);
      final f = folders(fixed: [dir('Dena/Roms')]);
      expect(f.all, [dir('Dena/Roms')]);
      expect((await f.scanAll()).added, 1);
      expect(await f.remove(dir('Dena/Roms')), 0);
      expect(f.all, [dir('Dena/Roms')]);
    },
  );

  test(
    'copies in the data folder are deleted; user ROMs only if asked',
    () async {
      final copy = rom('data/games/nes/x.nes', 1);
      final own = rom('Games/y.nes', 2);
      Game game(String path) => Game(
        id: 1,
        system: 'nes',
        title: 't',
        searchTitle: 't',
        fileName: 'f',
        path: path,
        sha1: 's',
        size: 64,
        crc32: '0',
        addedAt: DateTime(2026),
        playSeconds: 0,
        favorite: false,
      );
      await deleteGameFiles(
        game(copy.path),
        dataDir: dir('data'),
        keepUserRom: true,
      );
      expect(copy.existsSync(), isFalse);
      await deleteGameFiles(
        game(own.path),
        dataDir: dir('data'),
        keepUserRom: true,
      );
      expect(own.existsSync(), isTrue);
      await deleteGameFiles(
        game(own.path),
        dataDir: dir('data'),
        keepUserRom: false,
      );
      expect(own.existsSync(), isFalse);
    },
  );

  test('folder pick lists matching files under the folder', () async {
    rom('Pick/a.nes', 1);
    rom('Pick/sub/b.GBA', 2);
    rom('Pick/notes.txt', 3);
    rom('Pick/.git/c.nes', 4);
    expect(
      await filesWithExtensions(Directory(dir('Pick')), ['.nes', '.gba']),
      [dir('Pick/a.nes'), dir('Pick/sub/b.GBA')],
    );
  });

  test('the portable Roms folder sits in the Dena folder', () {
    final was = hasAndroidShell;
    hasAndroidShell = false;
    addTearDown(() => hasAndroidShell = was);
    expect(
      desktopRomsDir(
        env: const {'APPDATA': r'C:\Users\a\AppData\Roaming'},
        os: 'windows',
        executable: r'D:\Dena.emu\dena_emu.exe',
        exists: (path) => path == r'D:\Dena.emu\portable.txt',
      )?.path,
      r'D:\Dena.emu\Dena\Roms',
    );
    expect(
      desktopRomsDir(
        env: const {'APPDATA': r'C:\Users\a\AppData\Roaming'},
        os: 'windows',
        executable: r'D:\Dena.emu\dena_emu.exe',
        exists: (_) => false,
      ),
      isNull,
    );
  });
}
