// Spec: docs/specs/ps2.md
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/desktop/deck_presets.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/import_rules.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/romtools/dat_store.dart';
import 'package:dena_emu/src/session/bios_check.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:dena_emu/src/skins/builtin_skins.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'dreamcast_saturn_test.dart' show chd;

/// A small ISO9660 image: the volume descriptor at sector 16 with
/// [systemId], the root directory at sector 18 and, with [cnf], a
/// SYSTEM.CNF holding it at sector 19.
Uint8List iso({String systemId = 'PLAYSTATION', String? cnf}) {
  final out = Uint8List(20 * 2048);
  final pvd = 16 * 2048;
  out[pvd] = 1;
  out.setAll(pvd + 1, 'CD001'.codeUnits);
  out.setAll(pvd + 8, systemId.padRight(32).codeUnits);
  void le32(int at, int v) =>
      ByteData.sublistView(out).setUint32(at, v, Endian.little);
  // Root directory record: extent 18, one sector.
  out[pvd + 156] = 34;
  le32(pvd + 156 + 2, 18);
  le32(pvd + 156 + 10, 2048);
  if (cnf != null) {
    final root = 18 * 2048;
    const name = 'SYSTEM.CNF;1';
    out[root] = 33 + name.length + 1;
    le32(root + 2, 19);
    le32(root + 10, cnf.length);
    out[root + 32] = name.length;
    out.setAll(root + 33, name.codeUnits);
    out.setAll(19 * 2048, cnf.codeUnits);
  }
  return out;
}

const ps2Cnf =
    'BOOT2 = cdrom0:\\SLUS_200.62;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n';
const ps1Cnf = 'BOOT = cdrom:\\SLUS_000.01;1\r\nTCB = 4\r\n';

/// [image] as raw 2352-byte sectors of [mode] (1 or 2), each with the sync
/// header and its data after it.
Uint8List rawTrack(Uint8List image, int mode) {
  final sectors = image.length ~/ 2048;
  final offset = mode == 1 ? 16 : 24;
  final out = Uint8List(sectors * 2352);
  for (var s = 0; s < sectors; s++) {
    final at = s * 2352;
    out.setAll(at, const [
      0,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      0,
    ]);
    out[at + 15] = mode;
    out.setAll(at + offset, image.sublist(s * 2048, s * 2048 + 2048));
  }
  return out;
}

/// [image] as a CSO with 2048-byte blocks; the first [compressed] blocks are
/// deflated, the rest stored as they are.
Uint8List cso(Uint8List image, {int compressed = 1 << 30}) {
  const block = 2048;
  final blocks = image.length ~/ block;
  final data = BytesBuilder();
  final index = <int>[];
  final indexEnd = 0x18 + (blocks + 1) * 4;
  for (var n = 0; n < blocks; n++) {
    index.add(indexEnd + data.length | (n < compressed ? 0 : 0x80000000));
    final raw = image.sublist(n * block, n * block + block);
    data.add(n < compressed ? ZLibCodec(raw: true).encode(raw) : raw);
  }
  index.add(indexEnd + data.length);
  final head = ByteData(0x18)
    ..setUint8(0, 0x43)
    ..setUint8(1, 0x49)
    ..setUint8(2, 0x53)
    ..setUint8(3, 0x4f)
    ..setUint32(4, 0x18, Endian.little)
    ..setUint64(8, image.length, Endian.little)
    ..setUint32(16, block, Endian.little)
    ..setUint8(20, 1)
    ..setUint8(21, 0);
  final idx = ByteData(index.length * 4);
  for (var i = 0; i < index.length; i++) {
    idx.setUint32(i * 4, index[i] & 0xffffffff, Endian.little);
  }
  return (BytesBuilder()
        ..add(head.buffer.asUint8List())
        ..add(idx.buffer.asUint8List())
        ..add(data.takeBytes()))
      .takeBytes();
}

DiscSectorReader reader(Uint8List image) => (lba, count) async {
  final start = (lba * 2048).clamp(0, image.length);
  final end = ((lba + count) * 2048).clamp(0, image.length);
  return image.sublist(start, end);
};

void main() {
  group('registry', () {
    test('PS2 is a desktop-only system', () {
      expect(GameSystem.ps2.id, 'ps2');
      expect(GameSystem.ps2.shortName, 'PS2');
      expect(GameSystem.ps2.desktopOnly, isTrue);
      expect(GameSystem.ps2.playableOn(desktop: true), isTrue);
      expect(GameSystem.ps2.playableOn(desktop: false), isFalse);
      expect(desktopOnlySystems, contains('ps2'));
    });

    test('core, pad, art and tools are wired', () {
      expect(coreLibraries['ps2'], 'libpcsx2_libretro.so');
      expect(systemAspect['ps2'], 4 / 3);
      expect(systemsWithL2, contains('ps2'));
      expect(analogSystems, contains('ps2'));
      expect(boxArtSystems['ps2'], 'Sony - PlayStation 2');
      expect(raConsoleIds['ps2'], 21);
      expect(datSystems['ps2']?.name, 'Sony - PlayStation 2');
    });

    test('desktop resolution, widescreen and Deck presets', () {
      expect(upscaleFactors('ps2', desktop: true), [2, 4, 8]);
      expect(upscaleFactors('ps2', desktop: false), isEmpty);
      expect(hasWidescreen('ps2', desktop: true), isTrue);
      expect(hasWidescreen('ps2', desktop: false), isFalse);
      expect(presetSystems, contains('ps2'));
      // The Deck's 800 lines: Balanced keeps Auto (2x), Performance 2x.
      final balanced = planPreset(
        'ps2',
        DeckPreset.balanced,
        model: DeckModel.oled,
        screenHeight: 800,
      )!;
      expect(balanced.upscale, 0);
      expect(balanced.tdpWatts, 12);
      final perf = planPreset(
        'ps2',
        DeckPreset.performance,
        model: DeckModel.oled,
        screenHeight: 2160,
      )!;
      expect(perf.upscale, 8);
      expect(perf.runAhead, isNull);
    });

    test('the built-in skin is a DualShock 2', () {
      final skin = builtinSkin('ps2', const Size(400, 800), 4 / 3);
      expect({
        for (final i in skin.items) ...i.inputs,
      }, containsAll(['a', 'b', 'x', 'y', 'l', 'r', 'l2', 'r2', 'leftstick']));
      expect({
        for (final i in skin.items) i.label,
      }, containsAll(['✕', '○', '□', '△', 'L2', 'R2']));
      expect(
        skin.items.where((i) => i.kind == SkinItemKind.thumbstick),
        hasLength(1),
      );
    });
  });

  group('extensions and folders', () {
    test('an iso or cso is PSP unless its disc says PS2', () {
      expect(detectSystem('Game.iso'), GameSystem.psp);
      expect(detectSystem('Game.cso'), GameSystem.psp);
      expect(detectSystem('Game.iso', disc: GameSystem.ps2), GameSystem.ps2);
      expect(detectSystem('Game.CSO', disc: GameSystem.ps2), GameSystem.ps2);
      expect(detectSystem('Game.chd', disc: GameSystem.ps2), GameSystem.ps2);
      expect(detectSystem('Game.cue', disc: GameSystem.ps2), GameSystem.ps2);
    });

    test('folder names', () {
      for (final name in [
        'PS2',
        'ps2',
        'PlayStation 2',
        'Sony_PlayStation_2',
      ]) {
        expect(systemFromFolderName(name), GameSystem.ps2, reason: name);
      }
      expect(systemFromFolderName('PlayStation'), GameSystem.psx);
      expect(systemFromFolders('/roms/PS2/Game.chd'), GameSystem.ps2);
    });

    test('SYSTEM.CNF tells PS2 from PS1 and PSP', () async {
      expect(await discSystemFromIso(reader(iso(cnf: ps2Cnf))), GameSystem.ps2);
      expect(await discSystemFromIso(reader(iso(cnf: ps1Cnf))), GameSystem.psx);
      expect(
        await discSystemFromIso(reader(iso(systemId: 'PSP GAME'))),
        GameSystem.psp,
      );
      expect(await discSystemFromIso(reader(iso())), isNull);
      expect(await discSystemFromIso(reader(Uint8List(40 * 1024))), isNull);
    });

    test('raw sectors', () {
      expect(rawSectorDataOffset(rawTrack(iso(), 1)), 16);
      expect(rawSectorDataOffset(rawTrack(iso(), 2)), 24);
      expect(rawSectorDataOffset(iso()), isNull);
    });
  });

  group('looking inside discs', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dena_ps2');
    });
    tearDown(() => dir.delete(recursive: true));

    File write(String rel, List<int> bytes) => File(p.join(dir.path, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    test('iso', () async {
      expect(await sniffDisc(write('a.iso', iso(cnf: ps2Cnf))), GameSystem.ps2);
      expect(
        await sniffDisc(write('b.iso', iso(systemId: 'PSP GAME'))),
        isNull,
      );
      expect(await sniffDisc(write('c.iso', [1, 2, 3])), isNull);
    });

    test('cso, compressed and stored blocks', () async {
      final image = iso(cnf: ps2Cnf);
      expect(await sniffDisc(write('a.cso', cso(image))), GameSystem.ps2);
      expect(
        await sniffDisc(write('b.cso', cso(image, compressed: 17))),
        GameSystem.ps2,
      );
      expect(
        await sniffDisc(write('c.cso', cso(iso(systemId: 'PSP GAME')))),
        isNull,
      );
      expect(await sniffDisc(write('d.cso', 'CISO'.codeUnits)), isNull);
    });

    test('a DVD chd is PS2 unless it lies in a PSP folder', () async {
      expect(await isDvdChd(write('a.chd', chd(['DVD ']))), isTrue);
      expect(await isDvdChd(write('b.chd', chd(['CHT2']))), isFalse);
      expect(await sniffDisc(write('c.chd', chd(['DVD ']))), GameSystem.ps2);
      expect(
        await sniffDisc(write('PSP/d.chd', chd(['DVD ']))),
        GameSystem.psp,
      );
      // A PS2 CD in a chd is only known by its folder.
      expect(await sniffDisc(write('e.chd', chd(['CHT2']))), isNull);
      expect(
        await sniffDisc(write('PS2/f.chd', chd(['CHT2']))),
        GameSystem.ps2,
      );
    });

    test('a cue sheet reads its raw track', () async {
      write('p2/t.bin', rawTrack(iso(cnf: ps2Cnf), 2));
      final ps2 = write('p2/Game.cue', 'FILE "t.bin" BINARY\n'.codeUnits);
      write('m1/t.bin', rawTrack(iso(cnf: ps2Cnf), 1));
      final mode1 = write('m1/Game.cue', 'FILE t.bin BINARY\n'.codeUnits);
      write('p1/t.bin', rawTrack(iso(cnf: ps1Cnf), 2));
      final ps1 = write('p1/Game.cue', 'FILE t.bin BINARY\n'.codeUnits);
      expect(await sniffDisc(ps2), GameSystem.ps2);
      expect(await sniffDisc(mode1), GameSystem.ps2);
      expect(await sniffDisc(ps1), GameSystem.psx);
    });

    test('content check', () {
      final image = iso(cnf: ps2Cnf);
      expect(
        romContentLooksValid(GameSystem.ps2, 'a.iso', image, image.length),
        isTrue,
      );
      expect(
        romContentLooksValid(
          GameSystem.ps2,
          'a.iso',
          Uint8List(0x9000),
          0x9000,
        ),
        isFalse,
      );
      expect(
        romContentLooksValid(GameSystem.ps2, 'a.cso', 'CISO'.codeUnits, 4),
        isTrue,
      );
      expect(
        romContentLooksValid(GameSystem.ps2, 'a.chd', 'hello'.codeUnits, 5),
        isFalse,
      );
    });
  });

  group('import', () {
    late Directory dir;
    late LibraryDatabase db;
    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      dir = await Directory.systemTemp.createTemp('dena_ps2_import');
      db = LibraryDatabase(NativeDatabase.memory());
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('desktop adds a PS2 iso in place', () async {
      final f = File(p.join(dir.path, 'Game.iso'))
        ..writeAsBytesSync(iso(cnf: ps2Cnf));
      final out = await Importer(db, dir, desktop: true).importInPlace(f);
      expect(out, isA<Imported>());
      expect((await db.allGames()).single.system, 'ps2');
    });

    test('a PSP iso still imports as PSP', () async {
      final f = File(p.join(dir.path, 'Game.iso'))
        ..writeAsBytesSync(iso(systemId: 'PSP GAME'));
      final out = await Importer(db, dir, desktop: false).importInPlace(f);
      expect(out, isA<Imported>());
      expect((await db.allGames()).single.system, 'psp');
    });

    test('elsewhere a PS2 game is rejected with a reason', () async {
      final f = File(p.join(dir.path, 'Game.iso'))
        ..writeAsBytesSync(iso(cnf: ps2Cnf));
      final out = await Importer(db, dir, desktop: false).importInPlace(f);
      expect(out, isA<Rejected>());
      expect(
        (out as Rejected).reason,
        'PS2 games play on the Windows and SteamOS versions',
      );
      expect(await db.allGames(), isEmpty);
    });
  });

  group('BIOS', () {
    const bios = '/bios';
    final folder = p.join(bios, 'pcsx2', 'bios');

    test('PS2 needs a BIOS file of 4 to 8 MB in pcsx2/bios', () {
      Iterable<int> Function(String) sizes(List<int> s) =>
          (dir) => dir == folder ? s : const [];
      expect(
        checkBios('ps2', bios, fileSizes: sizes([])),
        isA<BiosMissing>().having(
          (b) => b.message,
          'message',
          allOf(
            contains('SCPH-70012.bin'),
            contains('SCPH-70004.bin'),
            contains('SCPH-70000.bin'),
            contains(folder),
          ),
        ),
      );
      expect(
        checkBios('ps2', bios, fileSizes: sizes([1024, 2 * 1024 * 1024])),
        isA<BiosMissing>(),
      );
      expect(
        checkBios('ps2', bios, fileSizes: sizes([4 * 1024 * 1024])),
        isA<BiosReady>(),
      );
    });

    test('a real folder is read', () async {
      final dir = await Directory.systemTemp.createTemp('dena_ps2_bios');
      addTearDown(() => dir.delete(recursive: true));
      expect(checkBios('ps2', dir.path), isA<BiosMissing>());
      File(p.join(dir.path, 'pcsx2', 'bios', 'scph39001.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(4 * 1024 * 1024));
      expect(checkBios('ps2', dir.path), isA<BiosReady>());
    });
  });
}
