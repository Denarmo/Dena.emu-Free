// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md 2 and 6.2, 6.3 (verification)
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/romtools/dat_store.dart';
import 'package:dena_emu/src/romtools/models.dart';
import 'package:dena_emu/src/romtools/verify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _sha = 'a' * 40;
final _bad = 'b' * 40;
final _headless = sha1.convert([1, 2, 3, 4]).toString();

String _nesDat() =>
    '''clrmamepro ( name "Nintendo - Nintendo Entertainment System" )
game ( name "Hit (USA)" rom ( name "Hit (USA).nes" size 40976 crc 11111111 sha1 $_sha ) )
game ( name "Crc Only (USA)" rom ( name "Crc Only (USA).nes" size 1024 crc 22222222 ) )
game ( name "Bad (USA)" rom ( name "Bad (USA).nes" size 8 crc 33333333 sha1 $_bad flags baddump ) )
game ( name "Headless (USA)" rom ( name "Headless (USA).nes" size 4 crc 44444444 sha1 $_headless ) )
game ( name "Named (USA)" rom ( name "Named (USA).nes" size 8 crc 55555555 sha1 ${'c' * 40} ) )
''';

Game _game(
  String sha1, {
  String system = 'nes',
  String fileName = 'x.nes',
  String? path,
  String crc32 = '00000000',
  int size = 1,
}) => Game(
  id: sha1.hashCode,
  system: system,
  title: fileName,
  searchTitle: fileName.toLowerCase(),
  fileName: fileName,
  path: path ?? '/nowhere/$fileName',
  sha1: sha1,
  size: size,
  crc32: crc32,
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

void main() {
  late Directory dir;
  late DatStore dats;
  late VerifyResults results;
  late GameVerifier verifier;
  var now = DateTime(2026, 3, 1);
  var fetches = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('verify');
    fetches = 0;
    now = DateTime(2026, 3, 1);
    dats = DatStore(
      dir.path,
      fetch: (url) async {
        fetches++;
        return url.path.contains('Entertainment')
            ? utf8.encode(_nesDat())
            : null;
      },
      clock: () => now,
    );
    results = VerifyResults(dir.path);
    verifier = GameVerifier(dats: dats, results: results, clock: () => now);
  });
  tearDown(() => dir.delete(recursive: true));

  test('no DAT, then every status', () async {
    final hit = _game(_sha, fileName: 'Whatever.nes');
    final noDat = await verifier.verify(hit);
    expect(noDat.status, VerifyStatus.noDat);
    expect(fetches, 0);

    expect(
      (await verifier.verify(_game('p' * 40, system: 'pico8'))).status,
      VerifyStatus.unknown,
    );

    final first = await verifier.verify(hit, download: true);
    expect(fetches, 1);
    expect(first.status, VerifyStatus.verified);
    expect(first.name, 'Hit (USA)');
    expect(first.source, 'libretro-database (No-Intro)');
    expect(first.checkedAt, now);

    final crc = await verifier.verify(
      _game('d' * 40, crc32: '22222222', size: 1024),
    );
    expect((crc.status, crc.name), (VerifyStatus.verified, 'Crc Only (USA)'));
    expect(
      (await verifier.verify(_game('d' * 40, crc32: '22222222', size: 5)))
          .status,
      VerifyStatus.unknown,
    );

    final bad = await verifier.verify(_game(_bad));
    expect((bad.status, bad.name), (VerifyStatus.badDump, 'Bad (USA)'));

    final named = await verifier.verify(
      _game('e' * 40, fileName: 'named (usa).zip'),
    );
    expect((named.status, named.name), (VerifyStatus.modified, 'Named (USA)'));

    final unknown = await verifier.verify(_game('f' * 40, fileName: 'Hb.nes'));
    expect(unknown.status, VerifyStatus.unknown);
    expect(unknown.source, 'libretro-database (No-Intro)');

    final chd = await verifier.verify(
      _game('9' * 40, system: 'nes', fileName: 'Disc.chd'),
    );
    expect(chd.status, VerifyStatus.unverifiable);

    expect(verifier.resultFor(hit)?.status, VerifyStatus.verified);
    final reload = VerifyResults(dir.path);
    await reload.load();
    expect(reload[_sha]?.status, VerifyStatus.verified);
    expect(reload.all, hasLength(results.all.length));
  });

  test('NES header is stripped and hashed', () async {
    await dats.download('nes');
    final rom = File(p.join(dir.path, 'Mine.nes'))
      ..writeAsBytesSync([
        0x4e,
        0x45,
        0x53,
        0x1a,
        ...List.filled(12, 0),
        1,
        2,
        3,
        4,
      ]);
    final real = GameVerifier(dats: dats, results: results, clock: () => now);
    final r = await real.verify(
      _game('1' * 40, fileName: 'Mine.nes', path: rom.path),
    );
    expect((r.status, r.name), (VerifyStatus.verified, 'Headless (USA)'));

    // Not headered, and a missing file: no throw, no match.
    rom.writeAsBytesSync(List.filled(20, 0));
    expect(
      (await real.verify(_game('2' * 40, fileName: 'Mine.nes', path: rom.path)))
          .status,
      VerifyStatus.unknown,
    );
    expect(
      (await real.verify(_game('3' * 40, path: '/missing/x.nes'))).status,
      VerifyStatus.unknown,
    );

    // The hook is used for tests, and only for NES.
    final asked = <String>[];
    final hooked = GameVerifier(
      dats: dats,
      results: results,
      readHeadless: (path) async {
        asked.add(path);
        return [1, 2, 3, 4];
      },
    );
    expect(
      (await hooked.verify(_game('4' * 40, path: '/a.nes'))).status,
      VerifyStatus.verified,
    );
    await hooked.verify(_game('5' * 40, system: 'gb', path: '/b.gb'));
    expect(asked, ['/a.nes']);
  });

  test('a compressed file keeps its source result', () async {
    await dats.download('nes');
    final game = _game(_sha, fileName: 'Hit.nes');
    final checked = await verifier.verify(game);
    final converted = _game(_sha, fileName: 'Hit.chd', path: '/roms/Hit.CHD');
    final kept = await verifier.verify(converted);
    expect(kept.status, VerifyStatus.verified);
    expect(kept.checkedAt, checked.checkedAt);

    await results.put(
      '7' * 40,
      VerifyResult(status: VerifyStatus.noDat, checkedAt: now),
    );
    expect(
      (await verifier.verify(_game('7' * 40, fileName: 'x.cso'))).status,
      VerifyStatus.unverifiable,
    );
  });

  test('results are stale after a DAT change; verify all', () async {
    final games = [
      _game(_sha, fileName: 'Hit.nes'),
      _game(_bad, fileName: 'Bad.nes'),
      _game('f' * 40, fileName: 'Hb.nes'),
    ];
    var changes = 0;
    verifier.addListener(() => changes++);
    await verifier.verifyAll(games, download: true);
    expect(fetches, 1);
    expect(verifier.running, isFalse);
    expect((verifier.done, verifier.total), (3, 3));
    expect(changes, greaterThanOrEqualTo(4));
    expect(games.map((g) => verifier.resultFor(g)!.status), [
      VerifyStatus.verified,
      VerifyStatus.badDump,
      VerifyStatus.unknown,
    ]);
    expect(games.any(verifier.isStale), isFalse);

    // Nothing fresh to redo.
    await verifier.verifyAll(games);
    expect(verifier.total, 0);

    now = DateTime(2026, 4, 1);
    await dats.download('nes', latest: true);
    expect(games.every(verifier.isStale), isTrue);
    await verifier.verifyAll(games);
    expect(verifier.total, 3);
    expect(games.any(verifier.isStale), isFalse);

    // Force redoes everything; cancel stops after the current game.
    final run = verifier.verifyAll(games, force: true);
    verifier.cancel();
    await run;
    expect(verifier.total, 3);
    expect(verifier.done, lessThan(3));
  });

  test('a failed download leaves games without a DAT', () async {
    final games = [
      _game('1' * 40, system: 'gb', fileName: 'a.gb'),
      _game('2' * 40, system: 'gb', fileName: 'b.gb'),
    ];
    await verifier.verifyAll(games, download: true);
    expect(fetches, 1);
    expect(verifier.done, 2);
    expect(
      games.map((g) => verifier.resultFor(g)?.status),
      everyElement(VerifyStatus.noDat),
    );
    await expectLater(
      verifier.verify(games.first, download: true),
      throwsStateError,
    );
  });
}
