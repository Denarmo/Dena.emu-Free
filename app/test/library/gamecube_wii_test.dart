// Spec: docs/specs/gamecube-wii.md
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/desktop/deck_presets.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/session/bios_check.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/skins/builtin_skins.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A plain disc image's first bytes: the game id, then the GameCube magic at
/// 0x1C or the Wii one at 0x18.
Uint8List plainDisc({required bool wii, int length = 0x440}) {
  final b = Uint8List(length);
  b.setAll(0, 'GALE01'.codeUnits);
  if (wii) {
    b.setAll(0x18, const [0x5d, 0x1c, 0x9e, 0xa3]);
  } else {
    b.setAll(0x1c, const [0xc2, 0x33, 0x9f, 0x3d]);
  }
  return b;
}

Uint8List ciso({required bool wii}) {
  final b = Uint8List(0x8000 + 0x440);
  b.setAll(0, 'CISO'.codeUnits);
  b.setAll(0x8000, plainDisc(wii: wii));
  return b;
}

Uint8List gcz(int subType) {
  final b = ByteData(0x40);
  b.setUint32(0, 0xb10bc001, Endian.little);
  b.setUint32(4, subType, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List wiaRvz(String magic, int discType) {
  final b = ByteData(0x80);
  for (var i = 0; i < 3; i++) {
    b.setUint8(i, magic.codeUnitAt(i));
  }
  b.setUint8(3, 1);
  b.setUint32(0x48, discType);
  return b.buffer.asUint8List();
}

void main() {
  group('registry', () {
    test('GameCube and Wii are desktop-only systems', () {
      for (final s in [GameSystem.gamecube, GameSystem.wii]) {
        expect(s.desktopOnly, isTrue);
        expect(s.playableOn(desktop: true), isTrue);
        expect(s.playableOn(desktop: false), isFalse);
      }
      expect(GameSystem.gamecube.id, 'gamecube');
      expect(GameSystem.wii.id, 'wii');
      expect(GameSystem.gamecube.shortName, 'GameCube');
      expect(GameSystem.wii.shortName, 'Wii');
    });

    test('core, aspect, pads and art are wired', () {
      expect(coreLibraries['gamecube'], 'libdolphin_libretro.so');
      expect(coreLibraries['wii'], 'libdolphin_libretro.so');
      expect(systemAspect['gamecube'], 4 / 3);
      expect(systemAspect['wii'], 4 / 3);
      expect(desktopOnlySystems, containsAll(['gamecube', 'wii']));
      expect(systemsWithL2, containsAll(['gamecube', 'wii']));
      expect(analogSystems, containsAll(['gamecube', 'wii']));
      expect(boxArtSystems['gamecube'], 'Nintendo - GameCube');
      expect(boxArtSystems['wii'], 'Nintendo - Wii');
      expect(raConsoleIds['gamecube'], 16);
      expect(raConsoleIds['wii'], 19);
    });

    test('no BIOS is needed', () {
      for (final s in ['gamecube', 'wii']) {
        expect(checkBios(s, '/bios', exists: (_) => false), isA<BiosReady>());
      }
    });

    test('desktop resolution up to 8x and widescreen', () {
      for (final s in ['gamecube', 'wii']) {
        expect(upscaleFactors(s, desktop: true), [2, 3, 4, 6, 8]);
        expect(upscaleFactors(s, desktop: false), isEmpty);
        expect(hasWidescreen(s, desktop: true), isTrue);
        expect(hasWidescreen(s, desktop: false), isFalse);
      }
    });

    test('the Deck presets list both systems', () {
      expect(presetSystems, containsAll(['gamecube', 'wii']));
    });

    test('the file pickers offer every format', () {
      expect(
        importExtensions,
        containsAll([
          '.iso',
          '.gcm',
          '.rvz',
          '.gcz',
          '.wbfs',
          '.ciso',
          '.wia',
          '.dol',
          '.elf',
        ]),
      );
    });

    test('built-in skins carry each pad', () {
      const size = Size(400, 800);
      Set<String> inputs(SkinLayout l) => {
        for (final i in l.items) ...i.inputs,
      };
      Set<String> labels(SkinLayout l) => {for (final i in l.items) i.label};
      final gc = builtinSkin('gamecube', size, 4 / 3);
      final wii = builtinSkin('wii', size, 4 / 3);
      expect(
        inputs(gc),
        containsAll(['a', 'b', 'x', 'y', 'l2', 'r', 'r2', 'start']),
      );
      expect(labels(gc), containsAll(['A', 'B', 'X', 'Y', 'L', 'Z', 'R']));
      expect(
        gc.items.where((i) => i.kind == SkinItemKind.thumbstick),
        hasLength(1),
      );
      expect(inputs(wii), containsAll(['a', 'b', 'x', 'y', 'l', 'r']));
      expect(labels(wii), containsAll(['A', 'B', 'C', 'Z']));
      expect(
        wii.items.where((i) => i.kind == SkinItemKind.thumbstick),
        hasLength(1),
      );
    });
  });

  group('headers', () {
    test('plain discs', () {
      expect(
        nintendoDiscFromHeader(plainDisc(wii: false), 'iso'),
        GameSystem.gamecube,
      );
      expect(
        nintendoDiscFromHeader(plainDisc(wii: true), 'gcm'),
        GameSystem.wii,
      );
      expect(nintendoDiscFromHeader(Uint8List(0x440), 'iso'), isNull);
      expect(nintendoDiscFromHeader(const [], 'iso'), isNull);
    });

    test('compressed formats', () {
      expect(
        nintendoDiscFromHeader(ciso(wii: false), 'ciso'),
        GameSystem.gamecube,
      );
      expect(nintendoDiscFromHeader(ciso(wii: true), 'ciso'), GameSystem.wii);
      expect(nintendoDiscFromHeader(gcz(0), 'gcz'), GameSystem.gamecube);
      expect(nintendoDiscFromHeader(gcz(1), 'gcz'), GameSystem.wii);
      expect(nintendoDiscFromHeader(gcz(7), 'gcz'), isNull);
      expect(
        nintendoDiscFromHeader(wiaRvz('RVZ', 1), 'rvz'),
        GameSystem.gamecube,
      );
      expect(nintendoDiscFromHeader(wiaRvz('RVZ', 2), 'rvz'), GameSystem.wii);
      expect(nintendoDiscFromHeader(wiaRvz('WIA', 2), 'wia'), GameSystem.wii);
      // An RVZ renamed .wia is not a WIA.
      expect(nintendoDiscFromHeader(wiaRvz('RVZ', 2), 'wia'), isNull);
      expect(
        nintendoDiscFromHeader([...'WBFS'.codeUnits, 0, 0], 'wbfs'),
        GameSystem.wii,
      );
      expect(nintendoDiscFromHeader('hello'.codeUnits, 'wbfs'), isNull);
    });
  });

  group('extensions', () {
    test('an .iso is GameCube or Wii by its header, else PSP', () {
      expect(detectSystem('Game.iso'), GameSystem.psp);
      expect(
        detectSystem('Game.iso', disc: GameSystem.gamecube),
        GameSystem.gamecube,
      );
      expect(detectSystem('Game.iso', disc: GameSystem.wii), GameSystem.wii);
      expect(detectSystem('Game.iso', disc: GameSystem.psx), GameSystem.psp);
    });

    test('Dolphin formats', () {
      for (final ext in ['gcm', 'rvz', 'wia', 'gcz', 'ciso', 'dol', 'elf']) {
        expect(detectSystem('Game.$ext'), GameSystem.gamecube, reason: ext);
        expect(
          detectSystem('Game.$ext', disc: GameSystem.wii),
          GameSystem.wii,
          reason: ext,
        );
      }
      expect(detectSystem('Game.WBFS'), GameSystem.wii);
    });

    test('a GameCube folder does not make a chd or cue GameCube', () {
      expect(
        detectSystem('Game.chd', disc: GameSystem.gamecube),
        GameSystem.psx,
      );
      expect(detectSystem('Game.cue', disc: GameSystem.wii), isNull);
    });

    test('folder names', () {
      expect(systemFromFolderName('GameCube'), GameSystem.gamecube);
      expect(systemFromFolderName('Nintendo_GameCube'), GameSystem.gamecube);
      expect(systemFromFolderName('ngc'), GameSystem.gamecube);
      expect(systemFromFolderName('Wii'), GameSystem.wii);
      expect(
        homebrewSystemFromFolders(r'D:\ROMS\Wii\apps\boot.dol'),
        GameSystem.wii,
      );
      expect(homebrewSystemFromFolders('/roms/psx/boot.elf'), isNull);
      expect(homebrewSystemFromFolders('/roms/boot.elf'), isNull);
    });

    test('content check', () {
      final gc = plainDisc(wii: false);
      expect(
        romContentLooksValid(GameSystem.gamecube, 'a.iso', gc, 1 << 30),
        isTrue,
      );
      expect(
        romContentLooksValid(GameSystem.wii, 'a.iso', gc, 1 << 30),
        isFalse,
      );
      expect(
        romContentLooksValid(
          GameSystem.wii,
          'a.rvz',
          wiaRvz('RVZ', 2),
          1 << 28,
        ),
        isTrue,
      );
      final text = 'not a game at all, just text\n' * 20;
      expect(
        romContentLooksValid(GameSystem.gamecube, 'a.dol', text.codeUnits, 580),
        isFalse,
      );
      final dol = Uint8List(0x200)..[3] = 0x01;
      expect(
        romContentLooksValid(GameSystem.gamecube, 'a.dol', dol, 0x200),
        isTrue,
      );
      final elf = Uint8List(0x40)
        ..setAll(0, const [0x7f, 0x45, 0x4c, 0x46, 1, 2])
        ..[0x13] = 20;
      expect(romContentLooksValid(GameSystem.wii, 'a.elf', elf, 0x40), isTrue);
      final armElf = Uint8List.fromList(elf)..[0x13] = 40;
      expect(
        romContentLooksValid(GameSystem.wii, 'a.elf', armElf, 0x40),
        isFalse,
      );
    });
  });

  group('import', () {
    late Directory dir;
    late LibraryDatabase db;
    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      dir = await Directory.systemTemp.createTemp('dena_gc_import');
      db = LibraryDatabase(NativeDatabase.memory());
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    File write(String rel, List<int> bytes) => File(p.join(dir.path, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    test('desktop adds a GameCube .iso and a Wii .rvz', () async {
      final iso = write('Game.iso', plainDisc(wii: false, length: 0x9000));
      final rvz = write('Other.rvz', wiaRvz('RVZ', 2));
      final importer = Importer(db, dir, desktop: true);
      expect(await importer.importInPlace(iso), isA<Imported>());
      expect(await importer.importInPlace(rvz), isA<Imported>());
      final systems = {for (final g in await db.allGames()) g.system};
      expect(systems, {'gamecube', 'wii'});
    });

    test('a Wii folder makes a .dol Wii homebrew', () async {
      final dol = Uint8List(0x400)..[3] = 1;
      final file = write('Wii/apps/boot.dol', dol);
      expect(await sniffDisc(file), GameSystem.wii);
      final importer = Importer(db, dir, desktop: true);
      expect(await importer.importInPlace(file), isA<Imported>());
      expect((await db.allGames()).single.system, 'wii');
    });

    test('elsewhere a Wii game is rejected with a reason', () async {
      final rvz = write('Game.rvz', wiaRvz('RVZ', 2));
      final importer = Importer(db, dir, desktop: false);
      final out = await importer.importInPlace(rvz);
      expect(out, isA<Rejected>());
      expect((out as Rejected).reason, contains('Windows and SteamOS'));
      expect(await db.allGames(), isEmpty);
    });

    test('a PSP .iso still imports as PSP', () async {
      final iso = Uint8List(0x9000);
      iso.setAll(0x8001, 'CD001'.codeUnits);
      final file = write('Psp.iso', iso);
      final importer = Importer(db, dir, desktop: true);
      expect(await importer.importInPlace(file), isA<Imported>());
      expect((await db.allGames()).single.system, 'psp');
    });
  });
}
