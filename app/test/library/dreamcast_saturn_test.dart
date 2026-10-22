// Spec: docs/specs/dreamcast-saturn.md
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart' show getCrc32;
import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/session/bios_check.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/skins/builtin_skins.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A 2048-byte-sector header with [id] at 0, or a raw 2352-byte one with it
/// after the 16-byte sync header.
List<int> discHeader(String id, {bool raw = false}) => [
  if (raw) ...List.filled(0x10, 0),
  ...id.codeUnits,
  ...List.filled(32, 0x20),
];

/// A minimal CHD v5 header whose metadata chain holds [tags] in order.
Uint8List chd(List<String> tags, {int version = 5}) {
  const entry = 16;
  final start = version >= 5 ? 124 : 120;
  final b = ByteData(start + tags.length * entry);
  for (var i = 0; i < 8; i++) {
    b.setUint8(i, 'MComprHD'.codeUnitAt(i));
  }
  b.setUint32(12, version);
  final metaAt = version >= 5 ? 48 : 36;
  b.setUint64(metaAt, tags.isEmpty ? 0 : start);
  for (var i = 0; i < tags.length; i++) {
    final at = start + i * entry;
    for (var c = 0; c < 4; c++) {
      b.setUint8(at + c, tags[i].codeUnitAt(c));
    }
    b.setUint64(at + 8, i == tags.length - 1 ? 0 : at + entry);
  }
  return b.buffer.asUint8List();
}

void main() {
  group('registry', () {
    test('Saturn and Dreamcast are desktop-only systems', () {
      for (final s in [GameSystem.saturn, GameSystem.dreamcast]) {
        expect(s.desktopOnly, isTrue);
        expect(s.playableOn(desktop: true), isTrue);
        expect(s.playableOn(desktop: false), isFalse);
      }
      expect(GameSystem.saturn.id, 'saturn');
      expect(GameSystem.dreamcast.id, 'dreamcast');
      expect(GameSystem.saturn.shortName, 'Saturn');
      expect(GameSystem.dreamcast.shortName, 'Dreamcast');
      expect(GameSystem.psx.desktopOnly, isFalse);
      expect(GameSystem.psx.playableOn(desktop: false), isTrue);
      expect(GameSystem.genesis.playableOn(desktop: true), isFalse);
    });

    test('cores, aspect, pads and art are wired', () {
      expect(coreLibraries['saturn'], 'libmednafen_saturn_libretro.so');
      expect(coreLibraries['dreamcast'], 'libflycast_libretro.so');
      expect(systemAspect['saturn'], 4 / 3);
      expect(systemAspect['dreamcast'], 4 / 3);
      expect(desktopOnlySystems, {
        for (final s in GameSystem.values)
          if (s.desktopOnly) s.id,
      });
      expect(systemsWithL2, containsAll(['saturn', 'dreamcast']));
      expect(analogSystems, contains('dreamcast'));
      expect(analogSystems, isNot(contains('saturn')));
      expect(boxArtSystems['saturn'], 'Sega - Saturn');
      expect(boxArtSystems['dreamcast'], 'Sega - Dreamcast');
      expect(raConsoleIds['saturn'], 39);
      expect(raConsoleIds['dreamcast'], 40);
    });

    test('desktop resolution and widescreen', () {
      expect(upscaleFactors('dreamcast', desktop: true), [2, 3, 4, 6, 8]);
      expect(upscaleFactors('saturn', desktop: true), isEmpty);
      expect(upscaleFactors('dreamcast', desktop: false), isEmpty);
      expect(hasWidescreen('dreamcast', desktop: true), isTrue);
      expect(hasWidescreen('saturn', desktop: true), isFalse);
      expect(hasWidescreen('dreamcast', desktop: false), isFalse);
    });

    test('built-in skins carry each pad', () {
      const size = Size(400, 800);
      final saturn = builtinSkin('saturn', size, 4 / 3);
      final dc = builtinSkin('dreamcast', size, 4 / 3);
      Set<String> inputs(SkinLayout l) => {
        for (final i in l.items) ...i.inputs,
      };
      expect(
        inputs(saturn),
        containsAll(['a', 'b', 'x', 'y', 'l', 'r', 'l2', 'r2', 'start']),
      );
      final labels = {for (final i in saturn.items) i.label};
      expect(labels, containsAll(['A', 'B', 'C', 'X', 'Y', 'Z', 'L', 'R']));
      expect(
        dc.items.where((i) => i.kind == SkinItemKind.thumbstick),
        hasLength(1),
      );
      expect(inputs(dc), containsAll(['a', 'b', 'x', 'y', 'l2', 'r2']));
      expect({for (final i in dc.items) i.label}, containsAll(['LT', 'RT']));
    });
  });

  group('extensions', () {
    test('Dreamcast images', () {
      expect(detectSystem('Game.cdi'), GameSystem.dreamcast);
      expect(detectSystem('Game.GDI'), GameSystem.dreamcast);
      expect(
        detectSystem('Game.chd', disc: GameSystem.dreamcast),
        GameSystem.dreamcast,
      );
    });

    test('chd defaults to PlayStation, cue needs a look inside', () {
      expect(detectSystem('Game.chd'), GameSystem.psx);
      expect(
        detectSystem('Game.chd', disc: GameSystem.saturn),
        GameSystem.saturn,
      );
      expect(detectSystem('Game.cue'), isNull);
      expect(
        detectSystem('Game.cue', disc: GameSystem.saturn),
        GameSystem.saturn,
      );
    });

    test('a disc track .bin is not a Genesis ROM', () {
      final track = [...discHeader('SEGA SEGASATURN', raw: true)];
      track.addAll(List.filled(0x104 - track.length, 0));
      expect(detectSystem('Track 01.bin', header: track), isNull);
    });

    test('disc headers', () {
      expect(
        discSystemFromHeader(discHeader('SEGA SEGASATURN')),
        GameSystem.saturn,
      );
      expect(
        discSystemFromHeader(discHeader('SEGA SEGAKATANA', raw: true)),
        GameSystem.dreamcast,
      );
      expect(discSystemFromHeader(discHeader('PLAYSTATION')), isNull);
      expect(discSystemFromHeader(const []), isNull);
    });

    test('folder names', () {
      expect(systemFromFolderName('Sega_Saturn'), GameSystem.saturn);
      expect(systemFromFolderName('DC'), GameSystem.dreamcast);
      expect(systemFromFolderName('PS1'), GameSystem.psx);
      expect(systemFromFolderName('Games'), isNull);
      expect(
        systemFromFolders(r'D:\ROMS\Saturn\Game\Game.chd'),
        GameSystem.saturn,
      );
      expect(systemFromFolders('/roms/dreamcast/a/b/c/Game.chd'), isNull);
      expect(systemFromFolders('/roms/Game.chd'), isNull);
    });

    test('first track of a sheet', () {
      expect(
        firstTrackFile(
          'REM x\nFILE "Game (Track 1).bin" BINARY\n  TRACK 01 MODE1/2352',
          gdi: false,
        ),
        'Game (Track 1).bin',
      );
      expect(firstTrackFile('file game.bin binary', gdi: false), 'game.bin');
      expect(
        firstTrackFile('3\r\n1 0 4 2352 track01.bin 0\r\n', gdi: true),
        'track01.bin',
      );
      expect(
        firstTrackFile('3\n1 0 4 2352 "Track 01.bin" 0\n', gdi: true),
        'Track 01.bin',
      );
      expect(firstTrackFile('nothing', gdi: false), isNull);
    });
  });

  group('looking inside discs', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dena_disc');
    });
    tearDown(() => dir.delete(recursive: true));

    File write(String rel, List<int> bytes) => File(p.join(dir.path, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    test('GD-ROM chd is Dreamcast, CD chd is not', () async {
      final gd = write('a.chd', chd(['CHT2', 'CHGD', 'CHGD']));
      final cd = write('b.chd', chd(['CHT2', 'CHT2']));
      final v4 = write('c.chd', chd(['CHGT'], version: 4));
      final junk = write('d.chd', List.filled(64, 1));
      expect(await isGdRomChd(gd), isTrue);
      expect(await isGdRomChd(cd), isFalse);
      expect(await isGdRomChd(v4), isTrue);
      expect(await isGdRomChd(junk), isFalse);
      expect(await sniffDisc(gd), GameSystem.dreamcast);
      expect(await sniffDisc(cd), isNull);
      final saturn = write('Saturn/e.chd', chd(['CHT2']));
      expect(await sniffDisc(saturn), GameSystem.saturn);
    });

    test('cue sheets read their first track', () async {
      write('s/Track 1.bin', discHeader('SEGA SEGASATURN', raw: true));
      final s = write('s/Game.cue', 'FILE "Track 1.bin" BINARY\n'.codeUnits);
      write('p/t.bin', discHeader('PLAYSTATION', raw: true));
      final ps = write('p/Game.cue', 'FILE t.bin BINARY\n'.codeUnits);
      final lost = write('x/Game.cue', 'FILE gone.bin BINARY\n'.codeUnits);
      expect(await sniffDisc(s), GameSystem.saturn);
      expect(await sniffDisc(ps), GameSystem.psx);
      expect((await sniffDisc(lost)), isNull);
      expect(await firstTrackOf(s), isNotNull);
    });
  });

  group('import', () {
    late Directory dir;
    late LibraryDatabase db;
    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      dir = await Directory.systemTemp.createTemp('dena_dc_import');
      db = LibraryDatabase(NativeDatabase.memory());
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('desktop adds a Saturn cue with the track CRC', () async {
      final track = discHeader('SEGA SEGASATURN', raw: true);
      File(p.join(dir.path, 'Game (Track 1).bin')).writeAsBytesSync(track);
      final cue = File(p.join(dir.path, 'Game.cue'))
        ..writeAsStringSync('FILE "Game (Track 1).bin" BINARY\n');
      final importer = Importer(db, dir, desktop: true);
      final out = await importer.importInPlace(cue);
      expect(out, isA<Imported>());
      final game = (await db.allGames()).single;
      expect(game.system, 'saturn');
      expect(game.crc32, getCrc32(track).toRadixString(16).padLeft(8, '0'));
    });

    test('elsewhere a Dreamcast game is rejected with a reason', () async {
      final cdi = File(p.join(dir.path, 'Game.cdi'))
        ..writeAsBytesSync(List.filled(64, 0));
      final importer = Importer(db, dir, desktop: false);
      final out = await importer.importInPlace(cdi);
      expect(out, isA<Rejected>());
      expect((out as Rejected).reason, contains('Windows and SteamOS'));
      expect(await db.allGames(), isEmpty);
    });
  });

  group('BIOS', () {
    const bios = '/bios';
    bool Function(String) only(Set<String> files) =>
        (path) => files.contains(path);

    test('Saturn needs one region file', () {
      expect(
        checkBios('saturn', bios, exists: only({})),
        isA<BiosMissing>().having(
          (b) => b.message,
          'message',
          allOf(
            contains('mpr-17933.bin'),
            contains('sega_101.bin'),
            contains(bios),
          ),
        ),
      );
      expect(
        checkBios('saturn', bios, exists: only({p.join(bios, 'sega_101.bin')})),
        isA<BiosReady>(),
      );
      expect(
        checkBios(
          'saturn',
          bios,
          exists: only({p.join(bios, 'mpr-17933.bin')}),
        ),
        isA<BiosReady>(),
      );
    });

    test('Dreamcast falls back to the built-in BIOS', () {
      expect(
        checkBios('dreamcast', bios, exists: only({})),
        isA<BiosReplaced>().having(
          (b) => b.message,
          'message',
          contains(p.join(bios, 'dc')),
        ),
      );
      expect(
        checkBios(
          'dreamcast',
          bios,
          exists: only({p.join(bios, 'dc', 'dc_boot.bin')}),
        ),
        isA<BiosReady>(),
      );
    });

    test('other systems need nothing', () {
      expect(checkBios('psx', bios, exists: only({})), isA<BiosReady>());
    });
  });
}
