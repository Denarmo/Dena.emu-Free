// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Import)
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a ROM header of [length] bytes, optionally carrying the `SEGA`
/// signature at offset 0x100.
List<int> genesisHeader({bool sega = false, int length = 0x104}) {
  final bytes = List<int>.filled(length, 0);
  if (sega) {
    const magic = [0x53, 0x45, 0x47, 0x41]; // 'SEGA'
    for (var i = 0; i < magic.length; i++) {
      bytes[0x100 + i] = magic[i];
    }
  }
  return bytes;
}

void main() {
  group('GameSystem', () {
    test('id equals the enum name', () {
      expect(GameSystem.nes.id, 'nes');
      expect(GameSystem.snes.id, 'snes');
      expect(GameSystem.gb.id, 'gb');
      expect(GameSystem.gbc.id, 'gbc');
      expect(GameSystem.gba.id, 'gba');
      expect(GameSystem.genesis.id, 'genesis');
    });

    test('shortName labels', () {
      expect(GameSystem.nes.shortName, 'NES');
      expect(GameSystem.snes.shortName, 'SNES');
      expect(GameSystem.gb.shortName, 'GB');
      expect(GameSystem.gbc.shortName, 'GBC');
      expect(GameSystem.gba.shortName, 'GBA');
      expect(GameSystem.nds.shortName, 'DS');
      expect(GameSystem.n64.shortName, 'N64');
      expect(GameSystem.psp.shortName, 'PSP');
      expect(GameSystem.pico8.shortName, 'PICO-8');
      expect(GameSystem.genesis.shortName, 'Genesis');
    });
  });

  group('detectSystem', () {
    const byExtension = <String, GameSystem>{
      'nes': GameSystem.nes,
      'sfc': GameSystem.snes,
      'smc': GameSystem.snes,
      'gb': GameSystem.gb,
      'gbc': GameSystem.gbc,
      'gba': GameSystem.gba,
      'nds': GameSystem.nds,
      'chd': GameSystem.psx,
      'pbp': GameSystem.psx,
      'z64': GameSystem.n64,
      'n64': GameSystem.n64,
      'v64': GameSystem.n64,
      'iso': GameSystem.psp,
      'cso': GameSystem.psp,
      'p8': GameSystem.pico8,
      'md': GameSystem.genesis,
      'gen': GameSystem.genesis,
      'smd': GameSystem.genesis,
    };

    byExtension.forEach((extension, system) {
      test('recognises .$extension (lower and upper case)', () {
        expect(detectSystem('game.$extension'), system);
        expect(detectSystem('game.${extension.toUpperCase()}'), system);
        // Whole-file case-insensitivity.
        expect(detectSystem('GAME.${extension.toUpperCase()}'), system);
      });
    });

    test('reads the extension from the base name, not a folder', () {
      expect(detectSystem('roms.nes/game'), isNull);
      expect(detectSystem('roms/game.nes'), GameSystem.nes);
      expect(detectSystem(r'roms\game.gba'), GameSystem.gba);
    });

    group('.bin needs the Genesis header', () {
      test('no header is unknown', () {
        expect(detectSystem('game.bin'), isNull);
      });

      test('SEGA header at 0x100 is Genesis', () {
        expect(
          detectSystem('game.bin', header: genesisHeader(sega: true)),
          GameSystem.genesis,
        );
        expect(
          detectSystem('game.BIN', header: genesisHeader(sega: true)),
          GameSystem.genesis,
        );
      });

      test('header long enough but without SEGA is unknown', () {
        expect(detectSystem('game.bin', header: genesisHeader()), isNull);
      });

      test('too-short header is unknown', () {
        expect(
          detectSystem('game.bin', header: genesisHeader(length: 0x10)),
          isNull,
        );
        expect(
          detectSystem('game.bin', header: genesisHeader(length: 0x0ff)),
          isNull,
        );
        expect(detectSystem('game.bin', header: <int>[]), isNull);
      });
    });

    test('unknown and missing extensions are rejected', () {
      for (final name in <String>[
        'game',
        'game.',
        'game.zip',
        'game.txt',
        'game.rom',
        'game.m3u',
        'game.nesx',
        '',
      ]) {
        expect(detectSystem(name), isNull, reason: name);
      }
    });
  });

  group('cleanTitle', () {
    test('strips parenthesised and bracketed tags', () {
      expect(cleanTitle('Super Game (USA) (Rev 1) [!].sfc'), 'Super Game');
      expect(cleanTitle('Legend [U] (Europe).gb'), 'Legend');
    });

    test('turns underscores and whitespace runs into single spaces', () {
      expect(cleanTitle('my_game__v2.gba'), 'my game v2');
      expect(cleanTitle('Game   Name.nes'), 'Game Name');
      expect(cleanTitle('a_b   c__d.smc'), 'a b c d');
    });

    test('falls back to the bare name when only tags remain', () {
      expect(cleanTitle('(Proto).nes'), '(Proto)');
      expect(cleanTitle('[BIOS].gba'), '[BIOS]');
    });

    test('strips directory parts', () {
      expect(cleanTitle('roms/snes/Super Game (USA).sfc'), 'Super Game');
      expect(cleanTitle(r'C:\roms\nes\Game [U].nes'), 'Game');
      expect(cleanTitle('roms/game.gbc'), 'game');
    });

    test('keeps a name that has no extension unchanged', () {
      expect(cleanTitle('Just a Game'), 'Just a Game');
    });
  });

  group('chooseZipEntry', () {
    test('single recognised entry is picked', () {
      final choice = chooseZipEntry(['game.nes']);
      expect(choice, isA<ZipPick>());
      final pick = choice as ZipPick;
      expect(pick.entryName, 'game.nes');
      expect(pick.system, GameSystem.nes);
    });

    test('PICO-8 PNG carts need the .p8.png double extension', () {
      expect(detectSystem('celeste.p8.png'), GameSystem.pico8);
      expect(detectSystem('dir/Celeste.P8.PNG'), GameSystem.pico8);
      expect(detectSystem('cover.png'), isNull);
    });

    test('recognises nested entry paths', () {
      final choice = chooseZipEntry(['roms/My Game (USA).gbc']);
      expect(choice, isA<ZipPick>());
      expect((choice as ZipPick).system, GameSystem.gbc);
      expect(choice.entryName, 'roms/My Game (USA).gbc');
    });

    test('no recognised entry yields ZipNoGame', () {
      expect(chooseZipEntry(['readme.txt', 'cover.jpg']), isA<ZipNoGame>());
      expect(chooseZipEntry([]), isA<ZipNoGame>());
    });

    test('directory entries are ignored', () {
      final choice = chooseZipEntry(['roms/', 'roms/game.gba', 'roms/']);
      expect(choice, isA<ZipPick>());
      expect((choice as ZipPick).entryName, 'roms/game.gba');
    });

    test('__MACOSX metadata entries are ignored', () {
      final choice = chooseZipEntry([
        '__MACOSX/',
        '__MACOSX/._game.nes',
        'game.nes',
      ]);
      expect(choice, isA<ZipPick>());
      final pick = choice as ZipPick;
      expect(pick.entryName, 'game.nes');
      expect(pick.system, GameSystem.nes);
    });

    test('__MACOSX-only archive has no game', () {
      expect(
        chooseZipEntry(['__MACOSX/', '__MACOSX/._game.nes']),
        isA<ZipNoGame>(),
      );
    });

    test('header-less .bin entries are ignored', () {
      expect(chooseZipEntry(['game.bin']), isA<ZipNoGame>());
    });

    test('several recognised entries yield ZipAmbiguous in archive order', () {
      final choice = chooseZipEntry(['a.nes', 'notes.txt', 'b.sfc', 'c.gba']);
      expect(choice, isA<ZipAmbiguous>());
      expect((choice as ZipAmbiguous).entries, ['a.nes', 'b.sfc', 'c.gba']);
    });
  });
}
