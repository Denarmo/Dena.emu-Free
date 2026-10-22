// Spec: docs/specs/romm.md (Acceptance tests)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/net/http.dart';
import 'package:dena_emu/src/romm/romm_client.dart';
import 'package:dena_emu/src/romm/romm_controller.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A RomM server in memory: one NES ROM, saves and states by ROM id.
class FakeRomm {
  final roms = <Map<String, Object?>>[
    {
      'id': 7,
      'platform_id': 1,
      'name': 'Hero Quest',
      'fs_name': 'Hero Quest (USA).nes',
      'fs_size_bytes': 7,
      'sha1_hash': 'd280aaa7d4cf8890bd4ad490fce4d452a9131a96',
      'crc_hash': '3c27116a',
    },
  ];
  final content = <int, List<int>>{
    7: [0x4e, 0x45, 0x53, 0x1a, 1, 2, 3],
  };
  final files = <String, List<Map<String, Object?>>>{'saves': [], 'states': []};
  final blobs = <String, List<int>>{};
  int clock = DateTime.utc(2026).millisecondsSinceEpoch;
  final auth = 'Basic ${base64.encode(utf8.encode('me:pw'))}';
  final calls = <String>[];

  HttpReply _json(Object? j, [int status = 200]) =>
      HttpReply(status, Uint8List.fromList(utf8.encode(jsonEncode(j))));

  Future<HttpReply> send(
    String method,
    Uri url,
    Map<String, String> headers, [
    List<int>? body,
  ]) async {
    calls.add('$method ${url.path}');
    if (headers['authorization'] != auth) {
      return _json({'detail': 'Unauthorized'}, 401);
    }
    final path = Uri.decodeFull(url.path);
    if (path == '/api/users/me') return _json({'username': 'me'});
    if (path == '/api/platforms') {
      return _json([
        {'id': 1, 'slug': 'nes', 'name': 'NES', 'rom_count': 1},
      ]);
    }
    if (path == '/api/roms') {
      final offset = int.parse(url.queryParameters['offset'] ?? '0');
      return _json({'items': roms.skip(offset).toList(), 'total': roms.length});
    }
    final content = RegExp(r'^/api/roms/(\d+)/content/').firstMatch(path);
    if (content != null) {
      return HttpReply(
        200,
        Uint8List.fromList(this.content[int.parse(content.group(1)!)]!),
      );
    }
    final kind = RegExp(r'^/api/(saves|states)$').firstMatch(path)?.group(1);
    if (kind != null && method == 'GET') {
      final rom = int.parse(url.queryParameters['rom_id']!);
      return _json(files[kind]!.where((f) => f['rom_id'] == rom).toList());
    }
    if (kind != null && method == 'POST') {
      final rom = int.parse(url.queryParameters['rom_id']!);
      final (name, bytes) = _firstPart(headers['content-type']!, body!);
      clock += 1000;
      files[kind]!.removeWhere(
        (f) => f['rom_id'] == rom && f['file_name'] == name,
      );
      final f = {
        'id': clock,
        'rom_id': rom,
        'file_name': name,
        'updated_at': DateTime.fromMillisecondsSinceEpoch(
          clock,
          isUtc: true,
        ).toIso8601String(),
        'download_path': '/api/raw/$kind/$rom/$name',
      };
      files[kind]!.add(f);
      blobs['/api/raw/$kind/$rom/$name'] = bytes;
      return _json(f);
    }
    if (blobs.containsKey(path)) {
      return HttpReply(200, Uint8List.fromList(blobs[path]!));
    }
    return _json({'detail': 'Not found'}, 404);
  }

  /// Puts a file on the server as another device would.
  void put(String kind, int rom, String name, List<int> bytes) {
    clock += 1000;
    files[kind]!.removeWhere((f) => f['file_name'] == name);
    files[kind]!.add({
      'id': clock,
      'rom_id': rom,
      'file_name': name,
      'updated_at': DateTime.fromMillisecondsSinceEpoch(
        clock,
        isUtc: true,
      ).toIso8601String(),
      'download_path': '/api/raw/$kind/$rom/$name',
    });
    blobs['/api/raw/$kind/$rom/$name'] = bytes;
  }

  static (String, List<int>) _firstPart(String type, List<int> body) {
    final boundary = type.split('boundary=').last;
    final text = latin1.decode(body);
    final part = text.split('--$boundary')[1];
    final name = RegExp(r'filename="([^"]*)"').firstMatch(part)!.group(1)!;
    final data = part.substring(part.indexOf('\r\n\r\n') + 4, part.length - 2);
    return (name, latin1.encode(data));
  }
}

void main() {
  late Directory dir;
  late LibraryDatabase db;
  late FakeRomm server;
  late RommController c;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    dir = Directory.systemTemp.createTempSync('dena_romm');
    db = LibraryDatabase(NativeDatabase.memory());
    server = FakeRomm();
    c = RommController(
      dataDir: dir,
      db: db,
      importer: Importer(db, Directory(p.join(dir.path, 'games'))),
      send: streamOver(server.send),
    );
    await c.load();
    await c.setAutoSync(false);
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  const sha = 'd280aaa7d4cf8890bd4ad490fce4d452a9131a96';
  File local(String rel) => File(p.join(dir.path, rel));

  test('normalizes server addresses', () {
    expect(
      RommClient.normalizeServer('nas:8080/').toString(),
      'http://nas:8080',
    );
    expect(
      RommClient.normalizeServer('https://romm.example/api').toString(),
      'https://romm.example',
    );
    expect(() => RommClient.normalizeServer('  '), throwsFormatException);
  });

  test('a wrong password is refused and nothing is kept', () async {
    expect(await c.connect('nas', 'me', 'nope'), 'Wrong username or password');
    expect(c.connected, isFalse);
  });

  test('connect keeps the login across restarts', () async {
    expect(await c.connect('nas:8080', 'me', 'pw'), isNull);
    final again = RommController(dataDir: dir, send: streamOver(server.send));
    await again.load();
    expect(again.connected, isTrue);
    expect(again.server, 'http://nas:8080');
    expect((await again.client.platforms()).single.name, 'NES');
  });

  test('download imports the game and links it', () async {
    await c.connect('nas', 'me', 'pw');
    final rom = (await c.client.roms(platformId: 1)).single;
    final out = await c.download(rom);
    expect(out, isA<Imported>());
    expect((await db.allGames()).single.sha1, sha);
    expect(c.links[sha]?.romId, 7);
    expect(c.has(rom, {}), isTrue);
    expect(
      Directory(p.join(dir.path, 'romm', 'downloads')).listSync(),
      isEmpty,
    );
  });

  test('saves and states go up, then come down on another device', () async {
    await c.connect('nas', 'me', 'pw');
    await c.download((await c.client.roms()).single);
    local('saves/$sha.srm')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9, 9]);
    local('states/$sha/slot1.state')
      ..createSync(recursive: true)
      ..writeAsBytesSync([5]);
    var rep = await c.syncNow();
    expect(rep.uploaded, 2);
    expect(server.files['saves']!.single['file_name'], 'Hero Quest (USA).srm');
    expect(
      server.files['states']!.single['file_name'],
      'Hero Quest (USA).slot1.state',
    );

    // Nothing changed: nothing moves.
    rep = await c.syncNow();
    expect(rep.changedNothing, isTrue);

    // Another device saves; this one receives it.
    server.put('saves', 7, 'Hero Quest (USA).srm', [1, 1, 1]);
    rep = await c.syncNow();
    expect(rep.failures, isEmpty);
    expect(rep.downloaded, 1);
    expect(local('saves/$sha.srm').readAsBytesSync(), [1, 1, 1]);
  });

  test('a game imported another way is matched by hash', () async {
    await c.connect('nas', 'me', 'pw');
    final src = File(p.join(dir.path, 'in', 'hq.nes'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0x4e, 0x45, 0x53, 0x1a, 1, 2, 3]);
    await Importer(db, Directory(p.join(dir.path, 'games'))).importOne(src);
    server.put('saves', 7, 'Hero Quest (USA).srm', [4]);
    final rep = await c.syncNow();
    expect(c.links[sha]?.romId, 7);
    expect(rep.failures, isEmpty);
    expect(rep.downloaded, 1);
    expect(local('saves/$sha.srm').readAsBytesSync(), [4]);
  });

  test('no sync while a game runs', () async {
    await c.connect('nas', 'me', 'pw');
    await c.sessionStarted();
    server.calls.clear();
    await c.syncNow();
    expect(server.calls, isEmpty);
    c.sessionEnded();
  });
}
