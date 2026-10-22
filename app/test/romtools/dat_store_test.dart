// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md 1 and 6.1, 6.3 (DAT store)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/romtools/dat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _dat(String name, int games) {
  final buf = StringBuffer('clrmamepro ( name "$name" version 1 )\n');
  for (var i = 0; i < games; i++) {
    buf.write(
      'game ( name "G$i" rom ( name "g$i.bin" size 1 crc 0000000$i ) )\n',
    );
  }
  return buf.toString();
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('datstore'));
  tearDown(() => dir.delete(recursive: true));

  test('header names map to systems, longest name wins', () {
    expect(systemForDatName('Nintendo - Game Boy'), 'gb');
    expect(systemForDatName('Nintendo - Game Boy (20240101-000000)'), 'gb');
    expect(systemForDatName('Nintendo - Game Boy (Parent-Clone)'), 'gb');
    expect(systemForDatName('Nintendo - Game Boy Color (Parent-Clone)'), 'gbc');
    expect(systemForDatName('Nintendo - Game Boy Advance'), 'gba');
    expect(
      systemForDatName(
        'Sony - PlayStation - Datfile (10885) (2024-01-01 00-00-00)',
      ),
      'psx',
    );
    expect(
      systemForDatName('Sony - PlayStation Portable - Datfile (1)'),
      'psp',
    );
    expect(
      systemForDatName('Sega - Mega Drive - Genesis (Parent-Clone)'),
      'genesis',
    );
    expect(systemForDatName('Sega - Dreamcast'), 'dreamcast');
    expect(systemForDatName('Atari - 2600'), isNull);
    expect(systemForDatName(''), isNull);
  });

  test('URLs are pinned, or master with latest', () {
    final store = DatStore(dir.path);
    expect(
      store.urlFor('gb').toString(),
      'https://raw.githubusercontent.com/libretro/libretro-database/'
      '$datCommit/metadat/no-intro/Nintendo%20-%20Game%20Boy.dat',
    );
    expect(
      store.urlFor('psx', latest: true).toString(),
      'https://raw.githubusercontent.com/libretro/libretro-database/'
      'master/metadat/redump/Sony%20-%20PlayStation.dat',
    );
  });

  test('download installs, update fetches master, index is cached', () async {
    final asked = <Uri>[];
    var games = 2;
    var t = DateTime(2026, 1, 1);
    final store = DatStore(
      dir.path,
      fetch: (url) async {
        asked.add(url);
        return utf8.encode(_dat('Nintendo - Game Boy', games));
      },
      clock: () => t,
    );
    var notified = 0;
    store.addListener(() => notified++);
    await store.load();
    expect(store.installed, isEmpty);
    expect(await store.indexFor('gb'), isNull);

    final future = store.download('gb');
    expect(store.busy('gb'), isTrue);
    final info = await future;
    expect(store.busy('gb'), isFalse);
    expect(notified, greaterThan(1));
    expect(asked.single, store.urlFor('gb'));
    expect(info.source, 'libretro-database (No-Intro)');
    expect(info.url, store.urlFor('gb').toString());
    expect(info.games, 2);
    expect(info.version, '1');
    final datDir = p.join(dir.path, 'romtools', 'dats');
    expect(File(p.join(datDir, 'gb.dat')).existsSync(), isTrue);
    expect(File(p.join(datDir, 'gb.json')).existsSync(), isTrue);

    final index = await store.indexFor('gb');
    expect(index!.dat.games, hasLength(2));
    expect(identical(await store.indexFor('gb'), index), isTrue);

    games = 3;
    t = DateTime(2026, 2, 1);
    final updated = await store.download('gb', latest: true);
    expect(asked.last, store.urlFor('gb', latest: true));
    expect(updated.games, 3);
    expect(updated.installedAt, t);
    expect((await store.indexFor('gb'))!.dat.games, hasLength(3));

    final again = DatStore(dir.path);
    await again.load();
    expect(again.info('gb')?.games, 3);
    expect(again.info('gb')?.installedAt, t);
    expect(again.installed.map((i) => i.system), ['gb']);

    await store.remove('gb');
    expect(store.info('gb'), isNull);
    expect(await store.indexFor('gb'), isNull);
    expect(File(p.join(datDir, 'gb.dat')).existsSync(), isFalse);
  });

  test('404 and fetch errors', () async {
    final missing = DatStore(dir.path, fetch: (_) async => null);
    await expectLater(
      missing.download('saturn'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'No DAT for Sega - Saturn on the server',
        ),
      ),
    );
    expect(missing.busy('saturn'), isFalse);
    expect(missing.info('saturn'), isNull);

    final broken = DatStore(
      dir.path,
      fetch: (url) async => throw const SocketException('offline'),
    );
    await expectLater(broken.download('nes'), throwsA(isA<SocketException>()));
    expect(broken.info('nes'), isNull);
  });

  test('import replaces the downloaded DAT; unknown is refused', () async {
    final store = DatStore(
      dir.path,
      fetch: (_) async => utf8.encode(_dat('Nintendo - Game Boy Color', 1)),
    );
    await store.download('gbc');
    final file = File(p.join(dir.path, 'my.xml'))
      ..writeAsStringSync('''<?xml version="1.0"?>
<datafile><header><name>Nintendo - Game Boy Color (Parent-Clone)</name>
<version>20250101</version></header>
<game name="A"><rom name="a.gbc" size="1" crc="00000001"/></game>
<game name="B"><rom name="b.gbc" size="1" crc="00000002"/></game>
</datafile>''');
    final info = await store.importFile(file);
    expect(info.system, 'gbc');
    expect(info.source, 'imported my.xml');
    expect(info.url, isNull);
    expect(info.games, 2);
    expect(store.info('gbc')?.source, 'imported my.xml');
    expect((await store.indexFor('gbc'))!.dat.games.map((g) => g.name), [
      'A',
      'B',
    ]);

    final other = File(p.join(dir.path, 'atari.dat'))
      ..writeAsStringSync(_dat('Atari - 2600', 1));
    await expectLater(
      store.importFile(other),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          "This DAT is for 'Atari - 2600', which Dena.emu doesn't play",
        ),
      ),
    );
    final junk = File(p.join(dir.path, 'junk.dat'))..writeAsStringSync('hi');
    await expectLater(store.importFile(junk), throwsFormatException);
  });
}
