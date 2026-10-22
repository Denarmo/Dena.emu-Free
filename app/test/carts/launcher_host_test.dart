// The launcher cart's host API over a fake GPIO port: no runtime, no network.
// Spec: docs/specs/pico8-launcher-cart.md (Acceptance tests)
import 'dart:io';
import 'dart:typed_data';

import 'package:dena_emu/src/carts/bbs.dart';
import 'package:dena_emu/src/carts/cart_download.dart';
import 'package:dena_emu/src/carts/launcher_host.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import 'fake_bbs.dart';

/// The cart's side of the mailbox: writes apply at once.
class FakeGpio implements GpioPort {
  final bytes = Uint8List(gpioSize);
  int seq = 0;

  void request(int cmd, String arg, {int chunk = 0, int? seqOverride}) {
    bytes.fillRange(0, gpioSize, 0);
    final a = arg.codeUnits;
    bytes.setRange(8, 8 + a.length, a);
    bytes[1] = cmd;
    bytes[2] = chunk;
    bytes[3] = a.length;
    seq = seqOverride ?? seq % 255 + 1;
    bytes[5] = seq;
    bytes[0] = 1;
  }

  @override
  Uint8List? read() {
    return Uint8List.fromList(bytes);
  }

  @override
  void write(int offset, List<int> data) =>
      bytes.setRange(offset, offset + data.length, data);
}

class _Rig {
  _Rig(this.db, this.dir, {this.client})
    : gpio = FakeGpio(),
      credits = CartCredits(dir.path) {
    host = LauncherHost(
      port: gpio,
      db: db,
      importer: Importer(db, Directory('${dir.path}/games')),
      credits: credits,
      client: client,
      onRun: launched.add,
      hasNetwork: () async => network,
    );
  }

  bool network = true;

  final LibraryDatabase db;
  final Directory dir;
  final FakeBbsClient? client;
  final FakeGpio gpio;
  final CartCredits credits;
  final launched = <Game>[];
  late final LauncherHost host;

  /// Sends one request and collects every chunk of its reply.
  Future<(String, bool)> ask(int cmd, [String arg = '']) async {
    gpio.request(cmd, arg);
    await host.poll();
    final text = StringBuffer();
    for (var chunk = 1; ; chunk++) {
      final g = gpio.bytes;
      expect(g[0], 3, reason: 'reply ready');
      expect(g[5], gpio.seq, reason: 'sequence echoed');
      expect(g[3], lessThanOrEqualTo(payloadMax));
      text.write(String.fromCharCodes(g.sublist(8, 8 + g[3])));
      if (g[4] & 1 == 0) return (text.toString(), g[4] & 2 != 0);
      gpio.request(cmdMore, '', chunk: chunk);
      await host.poll();
    }
  }

  List<List<String>> records(String text) => [
    for (final line in text.split('\n'))
      if (line.isNotEmpty) line.split('\t'),
  ];
}

Future<_Rig> _rig({bool online = false}) async {
  final db = await seededDb([]);
  final dir = await Directory.systemTemp.createTemp('dena_launcher_test');
  addTearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  return _Rig(db, dir, client: online ? FakeBbsClient() : null);
}

Future<int> _addCart(LibraryDatabase db, String title, String sha1) async =>
    (await db.addGame(
      system: 'pico8',
      title: title,
      fileName: '$title.p8',
      path: '/nowhere/$sha1',
      sha1: sha1,
      size: 1,
      crc32: '0',
    ))!;

void main() {
  test('hello says whether the BBS can be browsed', () async {
    expect(await (await _rig()).ask(cmdHello), ('0', false));
    expect(await (await _rig(online: true)).ask(cmdHello), ('1', false));
  });

  test('local lists PICO-8 carts with credits; fav lists favourites', () async {
    final r = await _rig();
    final a = await _addCart(r.db, 'Zed Run', 'aaa');
    final b = await _addCart(r.db, 'Apple Pie', 'bbb');
    await r.db.addGame(
      system: 'gba',
      title: 'Not A Cart',
      fileName: 'x.gba',
      path: '/nowhere/x',
      sha1: 'ccc',
      size: 1,
      crc32: '0',
    );
    await r.credits.put(
      'aaa',
      const CartCredit(
        postId: '9',
        threadId: 1,
        title: 'Zed Run',
        author: 'Zoë',
        authorId: 3,
      ),
    );
    await r.db.setFavorite(a, true);

    final (all, err) = await r.ask(cmdLocal, 'all');
    expect(err, isFalse);
    expect(r.records(all), [
      ['$b', 'apple pie', '', '0'],
      ['$a', 'zed run', 'zo?', '1'], // lowercase, non-ASCII as ?
    ]);
    final (fav, _) = await r.ask(cmdLocal, 'fav');
    expect(r.records(fav), [
      ['$a', 'zed run', 'zo?', '1'],
    ]);
  });

  test('long replies arrive in 120-byte chunks', () async {
    final r = await _rig();
    for (var i = 0; i < 20; i++) {
      await _addCart(r.db, 'Cart number $i with a long title', 's$i');
    }
    r.gpio.request(cmdLocal, 'all');
    await r.host.poll();
    expect(r.gpio.bytes[3], payloadMax);
    expect(r.gpio.bytes[4] & 1, 1, reason: 'more chunks follow');
    final (text, _) = await r.ask(cmdLocal, 'all');
    expect(r.records(text), hasLength(20));
  });

  test('bbs and get are refused offline', () async {
    final r = await _rig();
    expect(await r.ask(cmdBbs, 'f 1'), ('offline', true));
    expect(await r.ask(cmdGet, '0'), ('offline', true));
  });

  test('bbs and get say so when the device has no network', () async {
    final r = await _rig(online: true)..network = false;
    expect(await r.ask(cmdHello), ('1', false));
    expect(await r.ask(cmdBbs, 'f 1'), (noNetworkMessage, true));
    expect(await r.ask(cmdGet, '0'), (noNetworkMessage, true));
    r.network = true;
    expect((await r.ask(cmdBbs, 'f 1')).$2, isFalse);
  });

  test('a downloaded cart is in the library and credited', () async {
    final r = await _rig(online: true);
    final (list, err) = await r.ask(cmdBbs, 'f 1');
    expect(err, isFalse);
    final rows = r.records(list);
    expect(rows.first, ['more', '0']);
    expect(rows[1], ['0', 'moon hopper', 'ada', '-']);
    expect(rows[2], ['1', 'tom & jerry\'s cave', 'bo"b', '-']);

    final (got, gotErr) = await r.ask(cmdGet, '0');
    expect(gotErr, isFalse);
    expect(got, startsWith('ok '));
    final id = int.parse(got.split(' ')[1]);
    final game = await r.db.gameById(id);
    expect(game?.system, 'pico8');
    final carts = await r.db.watchGames(system: 'pico8').first;
    expect(carts.map((g) => g.id), [id]);
    final credit = (await r.credits.load())[game!.sha1];
    expect(credit?.author, 'ada');
    expect(r.client!.downloads, ['1001']);

    expect(await r.ask(cmdGet, '0'), ('dup $id', false));
    // The list now shows it in the library.
    final (again, _) = await r.ask(cmdBbs, 'f 1');
    expect(r.records(again)[1], ['0', 'moon hopper', 'ada', '$id']);
  });

  test('search and paging requests reach the client', () async {
    final r = await _rig(online: true);
    final (found, _) = await r.ask(cmdBbs, 's 1 moon hop');
    expect(r.records(found).skip(1).map((f) => f[1]), ['moon hopper']);
    await r.ask(cmdBbs, 'n 2');
    expect(r.client!.requests.last, (const NewCarts(), 2));
    expect(await r.ask(cmdBbs, 'x 1'), ('bad request', true));
    expect(await r.ask(cmdGet, '99'), ('bad request', true));
  });

  test('a BBS failure is an error reply', () async {
    final r = await _rig(online: true);
    r.client!.failWith = 'No connection';
    expect(await r.ask(cmdBbs, 'f 1'), ('no connection', true));
  });

  test('fav toggles and run hands the game over', () async {
    final r = await _rig();
    final id = await _addCart(r.db, 'Run Me', 'rrr');
    expect(await r.ask(cmdFav, '$id'), ('1', false));
    expect((await r.db.gameById(id))!.favorite, isTrue);
    expect(await r.ask(cmdFav, '$id'), ('0', false));
    expect(await r.ask(cmdRun, '$id'), ('ok', false));
    expect(r.launched.single.id, id);
    expect(await r.ask(cmdRun, '12345'), ('not in your library', true));
  });

  test('run refuses games of other systems', () async {
    final r = await _rig();
    final id = (await r.db.addGame(
      system: 'nes',
      title: 'Nope',
      fileName: 'n.nes',
      path: '/nowhere/n',
      sha1: 'nnn',
      size: 1,
      crc32: '0',
    ))!;
    expect(await r.ask(cmdRun, '$id'), ('not in your library', true));
    expect(r.launched, isEmpty);
  });

  test('a request is handled once; unknown commands are errors', () async {
    final r = await _rig();
    await _addCart(r.db, 'Once', 'ooo');
    r.gpio.request(cmdHello, '');
    await r.host.poll();
    expect(r.gpio.bytes[0], 3);
    // A stale snapshot of the same request (same sequence) is ignored.
    r.gpio.request(cmdLocal, 'all', seqOverride: r.gpio.seq);
    await r.host.poll();
    expect(r.gpio.bytes[0], 1, reason: 'not answered');
    expect(await r.ask(42), ('unknown command', true));
  });

  test('idle and empty mailboxes are left alone', () async {
    final r = await _rig();
    await r.host.poll();
    expect(r.gpio.bytes.every((b) => b == 0), isTrue);
  });
}
